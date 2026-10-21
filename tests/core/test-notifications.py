#!/usr/bin/env python3
"""Run: python3 tests/core/test-notifications.py (arm64 macOS with CLT).
Uses temporary sockets only; does not launch MTMR.app or change its settings.
"""

import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import tempfile
import threading
import time
import unittest

repositoryRoot = Path(__file__).resolve().parents[2]
cliPath = repositoryRoot / "bin/tbctl"


import sys
sys.path.insert(0, str(repositoryRoot / "tests/support"))
from harness import compileSwiftHarness

class NotificationTests(unittest.TestCase):
    def runCli(self, *arguments):
        command = [str(cliPath)]
        if os.environ.get("MTMR_PYTHON_COVERAGE"):
            command = [sys.executable, "-m", "coverage", "run", "--parallel-mode", str(cliPath)]
        return subprocess.run([*command, *arguments], capture_output=True, text=True, timeout=8)

    def fakeRoundTrip(self, arguments, expectedCommand, reply):
        with tempfile.TemporaryDirectory(prefix="tbctl-") as temporaryDirectory:
            socketPath = str(Path(temporaryDirectory) / "fake.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(socketPath)
                server.listen(1)
                server.settimeout(5)
                commands = []
                errors = []

                def serve():
                    try:
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(5)
                            requestBytes = bytearray()
                            while b"\n" not in requestBytes:
                                requestBytes.extend(connection.recv(1024))
                            commands.append(json.loads(requestBytes.split(b"\n")[0]))
                            connection.sendall(json.dumps(reply).encode() + b"\n")
                    except Exception as error:
                        errors.append(error)

                worker = threading.Thread(target=serve)
                worker.start()
                cliExecution = self.runCli(*arguments, "--socket", socketPath)
                worker.join(timeout=6)
                self.assertFalse(worker.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual(commands, [expectedCommand])
                return cliExecution

    def testDryRunAndUsage(self):
        execution = self.runCli("notify", "build ok", "--seconds", "7", "--dry-run")
        self.assertEqual(execution.returncode, 0)
        self.assertEqual(json.loads(execution.stdout), {"cmd": "notify", "text": "build ok", "seconds": 7})
        execution = self.runCli("--dry-run", "clear")
        self.assertEqual(execution.returncode, 0)
        self.assertEqual(json.loads(execution.stdout), {"cmd": "clear"})
        for seconds in ("0", "-1", "nan", "inf", "86401", "invalid"):
            self.assertEqual(self.runCli("notify", "text", "--seconds", seconds).returncode, 2)
        self.assertEqual(self.runCli("notify").returncode, 2)
        self.assertEqual(self.runCli("notify", "x" * 4096, "--dry-run").returncode, 2)

    def testMissingAndRefused(self):
        with tempfile.TemporaryDirectory(prefix="tbctl-") as temporaryDirectory:
            socketPath = str(Path(temporaryDirectory) / "missing.sock")
            self.assertEqual(self.runCli("clear", "--socket", socketPath).returncode, 3)
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
                stale.bind(socketPath)
            self.assertEqual(self.runCli("clear", "--socket", socketPath).returncode, 3)

    def testFakeServer(self):
        command = {"cmd": "notify", "text": "build ✓", "seconds": 2.5}
        execution = self.fakeRoundTrip(["notify", "build ✓", "--seconds", "2.5"], command, {"ok": True})
        self.assertEqual(execution.returncode, 0, execution.stderr)
        execution = self.fakeRoundTrip(["clear"], {"cmd": "clear"}, {"ok": True})
        self.assertEqual(execution.returncode, 0, execution.stderr)
        execution = self.fakeRoundTrip(["clear"], {"cmd": "clear"}, {"ok": False, "error": "deliberate rejection"})
        self.assertEqual(execution.returncode, 1)
        self.assertIn("deliberate rejection", execution.stderr)
        execution = self.fakeRoundTrip(["clear"], {"cmd": "clear"}, {"ok": "not a boolean"})
        self.assertEqual(execution.returncode, 1)

    def testButtonCli(self):
        command = {"cmd": "button", "id": "teams-mic", "icon": "mic.fill", "tint": "#34c759", "background": None, "visible": False}
        arguments = ["button", "teams-mic", "--icon", "mic.fill", "--tint", "#34c759", "--background", "none", "--hide"]
        execution = self.fakeRoundTrip(arguments, command, {"ok": True})
        self.assertEqual(execution.returncode, 0, execution.stderr)
        self.assertEqual(json.loads(self.runCli(*arguments, "--dry-run").stdout), command)
        listing = {"ok": True, "buttons": [{"id": "teams-mic", "visible": True}]}
        execution = self.fakeRoundTrip(["buttons"], {"cmd": "buttons"}, listing)
        self.assertEqual(json.loads(execution.stdout), listing)
        self.assertEqual(json.loads(self.runCli("buttons", "--dry-run").stdout), {"cmd": "buttons"})
        execution = self.runCli("button", "teams-mic", "--icon-path", "/tmp/mic.png", "--tint", "none", "--show", "--dry-run")
        self.assertEqual(json.loads(execution.stdout), {"cmd": "button", "id": "teams-mic", "iconPath": "/tmp/mic.png", "tint": None, "visible": True})
        for arguments in (["button", "BAD"], ["button", "mic", "--tint", "bad"], ["button", "mic", "--hide", "--show"], ["button", "mic", "--icon", "mic.fill", "--icon-path", "/tmp/mic.png"]):
            self.assertEqual(self.runCli(*arguments, "--dry-run").returncode, 2)
        with tempfile.TemporaryDirectory() as temporaryDirectory:
            for arguments in (["button", "mic"], ["buttons"], ["clear"], ["notify", "test"]):
                execution = self.runCli(*arguments, "--socket", str(Path(temporaryDirectory) / "missing.sock"))
                self.assertEqual(execution.returncode, 3)
                self.assertIn("MTMR is not running (no socket)", execution.stderr)

    def compileHarness(self, temporaryDirectory):
        executablePath = str(Path(temporaryDirectory) / "notification-harness")
        sources = [repositoryRoot / "mtmr/overlay/DebugLog.swift",
                   repositoryRoot / "mtmr/overlay/NotificationLayoutSolver.swift",
                   repositoryRoot / "mtmr/overlay/NotificationAreaView.swift",
                   repositoryRoot / "mtmr/overlay/NotificationStore.swift",
                   repositoryRoot / "mtmr/overlay/NotificationSocketServer.swift",
                   repositoryRoot / "mtmr/overlay/LiveButtonStore.swift",
                   repositoryRoot / "mtmr/overlay/TouchBarIcon.swift",
                   repositoryRoot / "tests/core/main.swift"]
        compilation = compileSwiftHarness(executablePath, sources)
        self.assertEqual(compilation.returncode, 0, compilation.stderr)
        return executablePath

    def exchange(self, connection, request):
        connection.sendall(request + b"\n")
        replyBytes = bytearray()
        while b"\n" not in replyBytes:
            received = connection.recv(1024)
            self.assertTrue(received, "Server closed without reply")
            replyBytes.extend(received)
        return json.loads(replyBytes.split(b"\n")[0])

    def checkServerCommands(self, socketPath):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(socketPath)
            for request in (b"no json", b"[]", b"null", b'{}', b'{"cmd":"unknown"}', b'\xff', b'{"cmd":"notify","text":5}', b'{"cmd":"notify","text":"bad","seconds":true}', b'{"cmd":"notify","text":"bad","seconds":0}', b'{"cmd":"notify","text":"bad","seconds":1e999}'):
                self.assertIs(self.exchange(connection, request)["ok"], False)
            self.assertEqual(self.exchange(connection, b'{"cmd":"notify","text":"valid"}'), {"ok": True})
            self.assertEqual(self.exchange(connection, b'{"cmd":"clear"}'), {"ok": True})
            self.assertEqual(self.exchange(connection, b'{"cmd":"clear"}' + b' ' * (4096 - 15)), {"ok": True})
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as oversized:
            oversized.settimeout(5)
            oversized.connect(socketPath)
            rejection = self.exchange(oversized, b"x" * 4097)
            self.assertIs(rejection["ok"], False)
            self.assertIn("4096", rejection["error"])
        self.assertEqual(self.runCli("notify", "actual Swift server", "--socket", socketPath).returncode, 0)
        self.assertEqual(self.runCli("clear", "--socket", socketPath).returncode, 0)

    def checkLiveServerCommands(self, socketPath):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(socketPath)
            def exchange(command):
                return self.exchange(connection, json.dumps(command).encode())
            initial = exchange({"cmd": "buttons"})
            self.assertTrue(initial["ok"])
            self.assertEqual(initial["buttons"][0]["id"], "fixture-mic")
            command = {"cmd": "button", "id": "fixture-mic", "icon": "mic.slash.fill", "iconPath": None, "tint": "#ff3b30", "background": "#123456", "visible": False}
            self.assertEqual(exchange(command), {"ok": True})
            changed = exchange({"cmd": "buttons"})
            self.assertEqual(changed["buttons"][0]["icon"], "mic.slash.fill")
            self.assertEqual(changed["buttons"][0]["tint"], "#ff3b30")
            self.assertEqual(changed["buttons"][0]["background"], "#123456")
            self.assertFalse(changed["buttons"][0]["visible"])
            for fields, expectedError in (({"id": "unknown"}, "unknown button"), ({"icon": "invalid-symbol"}, "unknown icon"), ({"tint": "#bad", "visible": True}, "tint must"), ({"visible": 1}, "visible must"), ({"background": []}, "background must"), ({"icon": False}, "icon must"), ({"iconPath": "relative.png"}, "iconPath must")):
                rejected = exchange(dict({"cmd": "button", "id": "fixture-mic"}, **fields))
                self.assertFalse(rejected["ok"])
                self.assertIn(expectedError, rejected["error"])
                self.assertEqual(exchange({"cmd": "buttons"}), changed)
            self.assertEqual(exchange({"cmd": "button", "id": "fixture-mic", "icon": None, "tint": None, "background": None, "visible": None}), {"ok": True})
            self.assertEqual(exchange({"cmd": "buttons"}), initial)
            self.assertEqual(exchange({"cmd": "button", "id": "fixture-mic", "tint": "#34c759"}), {"ok": True})
            self.assertEqual(exchange({"cmd": "buttons"})["buttons"][0]["icon"], "mic.fill")

    def checkExtensionCommands(self, socketPath):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(socketPath)
            for commandName in ("app", "apps", "fan", "teams"):
                command = {"cmd": commandName, "id": "fixture", "extra": {"value": 7}}
                reply = self.exchange(connection, json.dumps(command).encode())
                self.assertEqual(reply, {"ok": True, "forwarded": command}, "Handlers receive the entire command")
                rejection = self.exchange(connection, json.dumps(dict(command, reject=True)).encode())
                self.assertEqual(rejection, {"ok": False, "error": "Fixture rejection"})

    def checkParticleCommands(self, socketPath):
        commands = [{"cmd": "particles"}, {"cmd": "particles", "preset": "usb"},
                    {"cmd": "particles", "trickle": True}, {"cmd": "particles", "trickle": False},
                    {"cmd": "particles", "count": 200, "seconds": 10, "style": "sparks", "color": "#123aBC"}]
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(socketPath)
            for command in commands:
                self.assertEqual(self.exchange(connection, json.dumps(command).encode()), {"ok": True})
            self.assertFalse(self.exchange(connection, b'{"cmd":"particles","count":0}')["ok"])

    def checkQueueLimit(self, socketPath):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(socketPath)
            self.assertEqual(self.exchange(connection, b'{"cmd":"clear"}'), {"ok": True})
            for index in range(256):
                command = {"cmd": "notify", "text": str(index), "title": "Heading", "seconds": 60}
                self.assertEqual(self.exchange(connection, json.dumps(command).encode()), {"ok": True})
            inspection = self.exchange(connection, b'{"cmd":"inspect-store"}')
            self.assertEqual(inspection, {"ok": True, "count": 256, "text": "255", "title": "Heading"})
            rejected = self.exchange(connection, b'{"cmd":"notify","text":"overflow"}')
            self.assertFalse(rejected["ok"], "Full queues reject new notifications")
            self.assertIn("256", rejected["error"])
            self.assertEqual(self.exchange(connection, b'{"cmd":"clear"}'), {"ok": True})

    def checkMultipleClients(self, socketPath):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as first:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as second:
                for connection in (first, second):
                    connection.settimeout(5)
                    connection.connect(socketPath)
                first.sendall(b'{"cmd":')
                self.assertEqual(self.exchange(second, b'{"cmd":"clear"}'), {"ok": True},
                                 "An incomplete client must not block another client")
                first.sendall(b'"clear"}\n{"cmd":"buttons"}\n')
                with first.makefile("rb") as replies:
                    self.assertEqual(json.loads(replies.readline()), {"ok": True})
                    self.assertEqual(json.loads(replies.readline())["buttons"][0]["id"], "fixture-mic",
                                     "Batched lines receive separate ordered replies")

    def waitForServer(self, harness, socketPath):
        deadline = time.monotonic() + 15
        readinessError = None
        while time.monotonic() < deadline:
            if harness.poll() is not None:
                self.fail("Swift harness exited early: " + harness.communicate()[1])
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                    probe.settimeout(0.2)
                    probe.connect(socketPath)
                self.assertEqual(stat.S_IMODE(os.stat(socketPath).st_mode), 0o600)
                return
            except OSError as error:
                readinessError = error
                time.sleep(0.02)
        self.fail(f"Swift socket was not ready: {readinessError}")

    def testSwiftStoreAndServer(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-test-", dir="/tmp") as temporaryDirectory:
            executablePath = self.compileHarness(temporaryDirectory)
            socketPath = str(Path(temporaryDirectory) / "mtmr.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stale:
                stale.bind(socketPath)
            environment = dict(os.environ, MTMR_TEST_DIRECTORY=temporaryDirectory)
            harness = subprocess.Popen([executablePath], env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.waitForServer(harness, socketPath)
                self.checkServerCommands(socketPath)
                self.checkLiveServerCommands(socketPath)
                self.checkExtensionCommands(socketPath)
                self.checkParticleCommands(socketPath)
                self.checkQueueLimit(socketPath)
                self.checkMultipleClients(socketPath)
            finally:
                Path(temporaryDirectory, "stop").touch()
                stdout, stderr = harness.communicate(timeout=8)
            self.assertEqual(harness.returncode, 0, stderr)
            self.assertIn("Notification store checks passed", stdout)
            self.assertIn("Socket cleanup check passed", stdout)
            self.assertFalse(Path(socketPath).exists())


class LayoutSolverTests(unittest.TestCase):
    def testPureSolver(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-layout-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "layout-solver-tests")
            sources = [repositoryRoot / "mtmr/overlay/NotificationLayoutSolver.swift",
                       repositoryRoot / "tests/core/LayoutSolverTests.swift"]
            compilation = compileSwiftHarness(executablePath, sources)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executablePath, str(repositoryRoot / "layouts/template.json")],
                                       capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("N=477 margins=304/304", execution.stdout)
            self.assertIn("N=395 margins=345/345", execution.stdout)
            self.assertIn("N=339 margins=373/373", execution.stdout)
            self.assertIn("Layout solver checks passed", execution.stdout)
            print(execution.stdout, end="")




if __name__ == "__main__":
    unittest.main(verbosity=2)
