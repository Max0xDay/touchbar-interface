#!/usr/bin/env python3
"""Watcher tests: fake status executable and temporary AF_UNIX sockets only."""

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

repositoryRoot = Path(__file__).resolve().parents[2]
watcherPath = repositoryRoot / "teams/teams-watch"


class FakeButtonServer:
    def __init__(self, socketPath):
        self.socketPath = socketPath
        self.commands = []
        self.errors = []
        self.stopped = threading.Event()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(socketPath))
        self.server.listen(8)
        self.server.settimeout(0.1)
        self.worker = threading.Thread(target=self.serve)
        self.worker.start()

    def serve(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError as error:
                self.errors.append(error)
                return
            try:
                with connection:
                    connection.settimeout(2)
                    requestBytes = bytearray()
                    while b"\n" not in requestBytes:
                        received = connection.recv(1024)
                        if not received:
                            raise ValueError("client closed before sending command")
                        requestBytes.extend(received)
                    self.commands.append(json.loads(requestBytes.split(b"\n", 1)[0]))
                    connection.sendall(b'{"ok":true}\n')
            except (OSError, ValueError) as error:
                self.errors.append(error)

    def close(self):
        self.stopped.set()
        self.worker.join(timeout=3)
        self.server.close()
        self.socketPath.unlink()


class TeamsWatcherTests(unittest.TestCase):
    def setUp(self):
        self.temporaryDirectory = tempfile.TemporaryDirectory(prefix="teams-watch-test-", dir="/tmp")
        self.directory = Path(self.temporaryDirectory.name)
        self.statusPath = self.directory / "state.json"
        self.socketPath = self.directory / "fake.sock"
        self.statusCommand = self.directory / "fake-status"
        self.statusCommand.write_text("#!/usr/bin/env python3\nimport json, pathlib, sys\n"
                                      "assert sys.argv[1:] == ['status']\n"
                                      f"state = json.loads(pathlib.Path({str(self.statusPath)!r}).read_text())\n"
                                      "print(state['status'])\nsys.exit(state['exit'])\n")
        self.statusCommand.chmod(0o700)
        self.setState(0, "unmuted")

    def tearDown(self):
        self.temporaryDirectory.cleanup()

    def setState(self, exitCode, status):
        nextStatePath = self.directory / "next-state.json"
        nextStatePath.write_text(json.dumps({"exit": exitCode, "status": status}))
        os.replace(nextStatePath, self.statusPath)

    def arguments(self, *options):
        return [str(watcherPath), "--status-command", str(self.statusCommand), "--socket", str(self.socketPath), *options]

    def expectedState(self, icon="mic.fill", tint="#34c759", visible=True):
        return {"cmd": "button", "id": "teams-mic", "icon": icon, "tint": tint, "background": None, "visible": visible}

    def waitForCommands(self, server, count):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            if len(server.commands) >= count:
                return
            time.sleep(0.02)
        self.fail(f"Expected {count} commands; received {server.commands}; errors {server.errors}")

    def testOnceMappingAndDryRun(self):
        server = FakeButtonServer(self.socketPath)
        cases = [(0, "unmuted", self.expectedState()),
                 (0, "muted", self.expectedState(icon="mic.slash.fill", tint="#ff3b30")),
                 (4, "no-call", self.expectedState(tint="#ffcc00", visible=False)),
                 (3, "", self.expectedState(tint="#ffcc00")),
                 (1, "error", self.expectedState(tint="#ffcc00")),
                 (0, "unreadable", self.expectedState(tint="#ffcc00"))]
        try:
            for index, (exitCode, status, expected) in enumerate(cases):
                self.setState(exitCode, status)
                execution = subprocess.run(self.arguments("--once"), capture_output=True, text=True, timeout=8)
                self.assertEqual(execution.returncode, 0, execution.stderr)
                self.assertEqual(json.loads(execution.stdout), expected)
                self.waitForCommands(server, index + 1)
                self.assertEqual(server.commands[-1], expected)
            execution = subprocess.run(self.arguments("--once", "--dry-run"), capture_output=True, text=True, timeout=8)
            self.assertEqual(execution.returncode, 0)
            self.assertEqual(json.loads(execution.stdout), cases[-1][2])
            self.assertEqual(len(server.commands), len(cases))
            self.assertEqual(server.errors, [])
        finally:
            server.close()

    def testChangesAndRestartResync(self):
        watcher = subprocess.Popen(self.arguments("--interval", "0.05"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        server = None
        try:
            time.sleep(0.2)
            server = FakeButtonServer(self.socketPath)
            self.waitForCommands(server, 1)
            self.assertEqual(server.commands, [self.expectedState()])
            time.sleep(0.3)
            self.assertEqual(len(server.commands), 1, "Unchanged state must not be sent")
            self.setState(0, "muted")
            self.waitForCommands(server, 2)
            self.assertEqual(server.commands[-1], self.expectedState(icon="mic.slash.fill", tint="#ff3b30"))
            self.setState(4, "no-call")
            self.waitForCommands(server, 3)
            self.assertFalse(server.commands[-1]["visible"])
            self.setState(0, "unmuted")
            self.waitForCommands(server, 4)
            self.assertEqual(server.commands[-1], self.expectedState())
            self.assertEqual(server.errors, [])
            server.close()
            server = FakeButtonServer(self.socketPath)
            self.waitForCommands(server, 1)
            self.assertEqual(server.commands, [self.expectedState()], "Socket restart must re-send full unchanged state")
            time.sleep(0.3)
            self.assertEqual(len(server.commands), 1)
        finally:
            watcher.terminate()
            stdout, stderr = watcher.communicate(timeout=8)
            if server is not None:
                server.close()
        self.assertEqual(watcher.returncode, 0, stderr)
        self.assertEqual(stdout, "")
        self.assertEqual(stderr, "", "Missing socket retries should be quiet")

    def testInvalidIntervalAndMissingSocket(self):
        for interval in ("0", "-1", "nan", "inf"):
            execution = subprocess.run(self.arguments("--interval", interval), capture_output=True, text=True, timeout=8)
            self.assertEqual(execution.returncode, 2)
        execution = subprocess.run(self.arguments("--once"), capture_output=True, text=True, timeout=8)
        self.assertEqual(execution.returncode, 3)
        self.assertEqual(json.loads(execution.stdout), self.expectedState())
        self.assertEqual(execution.stderr, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
