#!/usr/bin/env python3
"""Cover CLI behaviours not already checked by test-notifications.py, using temporary files and sockets."""
from contextlib import redirect_stderr, redirect_stdout
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch

repositoryRoot = Path(__file__).resolve().parents[2]


def loadCli():
    loader = importlib.machinery.SourceFileLoader("tbctl", str(repositoryRoot / "bin/tbctl"))
    specification = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(specification)
    loader.exec_module(module)
    return module


class TbctlTests(unittest.TestCase):
    def setUp(self):
        self.cli = loadCli()
        self.temporaryDirectory = tempfile.TemporaryDirectory(prefix="tbctl-core-", dir="/tmp")
        self.addCleanup(self.temporaryDirectory.cleanup)
        self.directory = Path(self.temporaryDirectory.name)
        self.cli.LAYOUT_DIRECTORY = self.directory / "layouts"
        self.cli.LAYOUT_DIRECTORY.mkdir()
        self.cli.LIVE_LAYOUT_PATH = self.directory / "items.json"
        self.cli.LAYOUT_BACKUP_DIRECTORY = self.directory / "backups"
        self.cli.REPOSITORY_ROOT = self.directory
        self.layoutText = '[{"type":"staticButton","title":"${REPO}"}]'
        (self.cli.LAYOUT_DIRECTORY / "fixture.json").write_text(self.layoutText)

    def invoke(self, *arguments):
        standardOutput, standardError = io.StringIO(), io.StringIO()
        with patch.object(self.cli.sys, "argv", ["tbctl", *arguments]):
            with redirect_stdout(standardOutput), redirect_stderr(standardError):
                try:
                    exitCode = self.cli.main()
                except SystemExit as error:
                    exitCode = error.code
        return exitCode, standardOutput.getvalue(), standardError.getvalue()

    def roundTrip(self, arguments, replyBytes):
        socketPath = str(self.directory / "fake.sock")
        commands, failures = [], []
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
            listener.bind(socketPath)
            listener.listen(1)
            listener.settimeout(2)

            def serve():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        connection.settimeout(2)
                        commands.append(json.loads(connection.makefile("rb").readline()))
                        connection.sendall(replyBytes)
                except (OSError, ValueError) as error:
                    failures.append(str(error))

            worker = threading.Thread(target=serve)
            worker.start()
            try:
                execution = self.invoke(*arguments, "--socket", socketPath)
            finally:
                worker.join(timeout=3)
        Path(socketPath).unlink()
        self.assertFalse(worker.is_alive(), "Fake socket worker must finish")
        self.assertEqual(failures, [], "Fake socket must deliver its response")
        self.assertEqual(len(commands), 1, "Each command opens one connection")
        return execution, commands[0]

    def testRemainingSocketCommandsAndDryRuns(self):
        cases = [
            (["notify", "Text", "--title", "Heading", "--app", "fixture.app"],
             {"cmd": "notify", "text": "Text", "title": "Heading", "app": "fixture.app"}),
            (["app"], {"cmd": "apps"}), (["app", "stats"], {"cmd": "app", "id": "stats"}),
            (["fan"], {"cmd": "fan"}),
            (["fan", "custom", "--percent", "42"], {"cmd": "fan", "mode": "custom", "percent": 42}),
            (["particles", "--count", "20", "--seconds", "3", "--color", "#123ABC", "--style", "sparks"],
             {"cmd": "particles", "count": 20, "seconds": 3, "color": "#123ABC", "style": "sparks"}),
            (["particles", "--usb"], {"cmd": "particles", "preset": "usb"})]
        cases.extend((["particles", "--trickle", value], {"cmd": "particles", "trickle": value == "on"})
                     for value in ("on", "off"))
        for arguments, expectedCommand in cases:
            with self.subTest(arguments=arguments):
                execution, command = self.roundTrip(arguments, b'{"ok":true,"fixture":1}\n')
                self.assertEqual(execution[0], 0, execution[2])
                self.assertEqual(command, expectedCommand)
                dryExecution = self.invoke(*arguments, "--dry-run")
                self.assertEqual(dryExecution[0], 0, dryExecution[2])
                self.assertEqual(json.loads(dryExecution[1]), expectedCommand, "Dry run preserves the wire command")
                if arguments[0] == "fan" or arguments == ["app"]:
                    self.assertEqual(json.loads(execution[1]), {"ok": True, "fixture": 1})
                else:
                    self.assertEqual(execution[1], "", "Mutation commands do not print replies")

    def testUsageErrors(self):
        cases = [["particles", "--count", "0"], ["fan", "--percent", "101"]]
        for arguments in cases:
            with self.subTest(arguments=arguments[:3]):
                execution = self.invoke(*arguments, "--dry-run")
                self.assertEqual(execution[0], 2, "Invalid usage must exit with code 2")
                self.assertIn("error:", execution[2])

    def testLayoutListingDryRunAndInstallInTemporaryDirectory(self):
        self.assertIn("active: none", self.invoke("layout")[1])
        dryExecution = self.invoke("layout", "fixture", "--dry-run")
        rendered = self.layoutText.replace("${REPO}", str(self.directory))
        self.assertEqual(dryExecution, (0, rendered, ""))
        self.assertFalse(self.cli.LIVE_LAYOUT_PATH.exists(), "Dry run must not create a live layout")
        self.assertEqual(self.invoke("layout", "fixture")[0], 0)
        self.assertEqual(self.cli.LIVE_LAYOUT_PATH.read_text(), rendered)
        self.assertIn("active: fixture", self.invoke("layout")[1])
        self.cli.LIVE_LAYOUT_PATH.write_text("custom content")
        self.assertEqual(self.invoke("layout", "fixture")[0], 0)
        backups = list(self.cli.LAYOUT_BACKUP_DIRECTORY.glob("*.json"))
        self.assertEqual([path.read_text() for path in backups], ["custom content"])
        (self.cli.LAYOUT_DIRECTORY / "broken.json").write_text("not json")
        self.assertEqual(self.invoke("layout", "broken")[0], 1, "Malformed layouts cannot be installed")
        self.assertEqual(self.cli.LIVE_LAYOUT_PATH.read_text(), rendered, "Failed installs preserve the live layout")

    def testLayoutBackupRetention(self):
        self.cli.LIVE_LAYOUT_PATH.write_text("original")
        self.cli.LAYOUT_BACKUP_DIRECTORY.mkdir()
        for index in range(25):
            (self.cli.LAYOUT_BACKUP_DIRECTORY / f"items-20000101-{index:06}.json").write_text(str(index))
        backupPath = self.cli.backUpLiveLayout()
        backups = sorted(self.cli.LAYOUT_BACKUP_DIRECTORY.glob("*.json"))
        self.assertEqual(len(backups), 20, "Backup retention must preserve only the newest twenty")
        self.assertEqual(backups[0].read_text(), "6", "Retention must remove the oldest backups")
        self.assertEqual(backupPath.read_text(), "original", "The newest backup keeps the replaced layout")

    def testPanelRejectionAndTransportTimeout(self):
        execution, _ = self.roundTrip(["app", "missing"], b'{"ok":false,"error":"unknown panel"}\n')
        self.assertEqual(execution[0], 1)
        self.assertIn("unknown panel", execution[2])
        with patch.object(self.cli.socket, "socket", side_effect=TimeoutError("timeout")):
            execution = self.invoke("clear")
        self.assertEqual(execution[0], 1, "Socket timeouts must fail explicitly")
        self.assertIn("timeout", execution[2])

    def testReplyFramingAndSizeLimit(self):
        cases = [([b'{"ok":', b'true}\n'], {"ok": True}),
                 ([b" " * 1048577], None)]
        for chunks, expectedReply in cases:
            with self.subTest(size=sum(map(len, chunks))):
                class ReplyConnection:
                    def recv(self, count):
                        return chunks.pop(0)
                if expectedReply is None:
                    with self.assertRaisesRegex(ValueError, "exceeds 1 MiB"):
                        self.cli.receiveReply(ReplyConnection())
                else:
                    self.assertEqual(self.cli.receiveReply(ReplyConnection()), expectedReply)


if __name__ == "__main__":
    unittest.main(verbosity=2)
