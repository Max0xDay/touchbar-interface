#!/usr/bin/env python3
"""Run: python3 mtmr/tests/test-notifications.py (arm64 macOS with CLT).
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


def renderedActualLayout(directory):
    """layouts/actual.json with ${REPO} substituted, exactly as `tbctl layout actual` would install it."""
    rendered = subprocess.run([str(repositoryRoot / "bin/tbctl"), "layout", "actual", "--dry-run"],
                              capture_output=True, text=True, check=True, timeout=10).stdout
    layoutPath = Path(directory) / "actual.json"
    layoutPath.write_text(rendered)
    return layoutPath


def compileSwiftHarness(executablePath, sources, compilationArguments=()):
    return subprocess.run(["swiftc", "-target", "arm64-apple-macosx11.0", "-swift-version", "5",
                           *map(str, sources), *compilationArguments, "-o", executablePath],
                          capture_output=True, text=True, timeout=180)


class NotificationTests(unittest.TestCase):
    def runCli(self, *arguments):
        return subprocess.run([str(cliPath), *arguments], capture_output=True, text=True, timeout=8)

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

    def testLayout(self):
        with tempfile.TemporaryDirectory() as temporaryDirectory:
            items = json.loads(renderedActualLayout(temporaryDirectory).read_text())
        self.assertIsInstance(items, list)
        identifiers = [item["id"] for item in items if "id" in item]
        self.assertEqual(len(identifiers), len(set(identifiers)))
        microphone = next(item for item in items if item.get("id") == "teams-mic")
        self.assertEqual(microphone["type"], "staticButton")
        self.assertEqual(microphone["icon"], "mic.fill")
        self.assertEqual(microphone["tint"], "#8e8e93")
        self.assertEqual(microphone["title"], "")
        self.assertFalse(microphone.get("keepSlotWhenHidden", False))
        self.assertTrue(microphone["startHidden"])
        self.assertEqual(microphone["watcher"], [str(repositoryRoot / "teams/teams-watch")])
        self.assertEqual(microphone["actions"], [{"trigger": "singleTap", "action": "shellScript",
                                               "executablePath": str(repositoryRoot / "teams/teams-mic-tap"),
                                               "shellArguments": []}])
        appControls = [item for item in items if item["type"] == "appControls"]
        self.assertEqual(len(appControls), 1)
        self.assertEqual(appControls[0]["align"], "right")

    def compileHarness(self, temporaryDirectory):
        executablePath = str(Path(temporaryDirectory) / "notification-harness")
        sources = [repositoryRoot / "mtmr/overlay/NotificationLayoutSolver.swift",
                   repositoryRoot / "mtmr/overlay/NotificationAreaView.swift",
                   repositoryRoot / "mtmr/overlay/NotificationTouchBarItem.swift",
                   repositoryRoot / "mtmr/overlay/NotificationSocketServer.swift",
                   repositoryRoot / "mtmr/overlay/LiveButtonStore.swift",
                   repositoryRoot / "mtmr/overlay/TouchBarIcon.swift",
                   repositoryRoot / "mtmr/tests/main.swift"]
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

    def waitForServer(self, harness, socketPath):
        deadline = time.monotonic() + 5
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
                       repositoryRoot / "mtmr/tests/LayoutSolverTests.swift"]
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


class LayoutViewTests(unittest.TestCase):
    def testContainerAndUnchangedStack(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-layout-view-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "layout-view-tests")
            sourceDirectory = repositoryRoot / "build/work/src"
            sources = sorted(sourcePath for sourcePath in sourceDirectory.rglob("*.swift") if sourcePath.name != "main.swift")
            sources.append(repositoryRoot / "mtmr/tests/LayoutViewTests.swift")
            sources.append(repositoryRoot / "mtmr/tests/LiveButtonTests.swift")
            bridgeObjects = sorted((repositoryRoot / "build/work/objects").glob("*.o"))
            self.assertTrue(bridgeObjects, "Run mtmr/build.sh before the view tests")
            sdkExecution = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True, timeout=10)
            self.assertEqual(sdkExecution.returncode, 0, sdkExecution.stderr)
            sdkPath = sdkExecution.stdout.strip()
            compilationArguments = ["-sdk", sdkPath,
                                    "-import-objc-header", str(sourceDirectory / "CBridge/TouchBarPrivateApi-Bridging.h"),
                                    "-I", str(sourceDirectory / "CBridge"),
                                    "-F", str(Path(sdkPath) / "System/Library/PrivateFrameworks"),
                                    "-module-cache-path", str(Path(temporaryDirectory) / "modulecache"),
                                    *map(str, bridgeObjects)]
            for framework in ("Cocoa", "CoreLocation", "CoreAudio", "AVFoundation", "IOKit", "EventKit",
                              "ScriptingBridge", "ServiceManagement", "DFRFoundation", "MultitouchSupport",
                              "CoreBrightness", "CoreDisplay"):
                compilationArguments.extend(["-framework", framework])
            compilation = compileSwiftHarness(executablePath, sources, compilationArguments)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executablePath, str(renderedActualLayout(temporaryDirectory))],
                                       capture_output=True, text=True, timeout=20)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("Layout view checks passed (no Touch Bar created)", execution.stdout)
            self.assertEqual(execution.stderr.count("MTMR layout warning:"), 2, "Warn on narrow solves, not on text changes")
            self.assertEqual(execution.stderr.count("MTMR item minWidth rejected:"), 2)
            print(execution.stdout, end="")


class NotificationAreaTests(unittest.TestCase):
    def testTextSwipeAndTransitions(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-area-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "notification-area-tests")
            sources = [repositoryRoot / "mtmr/overlay/NotificationLayoutSolver.swift",
                       repositoryRoot / "mtmr/overlay/NotificationAreaView.swift",
                       repositoryRoot / "mtmr/overlay/NotificationTouchBarItem.swift",
                       repositoryRoot / "mtmr/tests/NotificationAreaTests.swift"]
            compilation = compileSwiftHarness(executablePath, sources)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executablePath], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("Notification area checks passed", execution.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
