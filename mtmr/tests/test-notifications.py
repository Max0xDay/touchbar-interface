#!/usr/bin/env python3
"""Run: python3 mtmr/tests/test-notifications.py (arm64 macOS with CLT).
Uses temporary sockets only; does not launch MTMR.app or change its settings.
"""

import base64
import json
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import tempfile
import threading
import time
import unittest
import zlib

repositoryRoot = Path(__file__).resolve().parents[2]
cliPath = repositoryRoot / "bin/tbctl"


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

    def testLayout(self):
        items = json.loads((repositoryRoot / "layouts/main.json").read_text())
        self.assertEqual([item["align"] for item in items], ["left"] * 5 + ["center"] + ["right"] * 2)
        self.assertEqual(items[0]["type"], "exitTouchbar")
        self.assertEqual(items[0]["width"], 30)
        self.assertEqual(items[1]["width"], 1)
        self.assertFalse(items[1]["bordered"])
        self.assertEqual(items[1]["title"], "")
        parsingSource = (repositoryRoot / "build/work/src/ItemsParsing.swift").read_text()
        controllerSource = (repositoryRoot / "build/work/src/TouchBarController.swift").read_text()
        self.assertIn('typename: "exitTouchbar"', controllerSource)
        for item in items:
            if item["type"] != "exitTouchbar":
                self.assertIn("case " + item["type"], parsingSource)
            self.assertIn(item["type"], ("exitTouchbar", "staticButton", "notification"))
            self.assertNotIn("actions", item)
            self.assertNotIn("matchAppId", item)
        for item in items[2:5]:
            self.assertEqual(item["width"], 75)
            self.assertEqual(item["title"], "")
            image = base64.b64decode(item["image"]["base64"], validate=True)
            self.assertEqual(image[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack("!II", image[16:24]), (24, 24))
            offset = 8
            while offset < len(image):
                chunkLength = struct.unpack("!I", image[offset:offset + 4])[0]
                chunk = image[offset + 4:offset + 8 + chunkLength]
                checksum = struct.unpack("!I", image[offset + 8 + chunkLength:offset + 12 + chunkLength])[0]
                self.assertEqual(zlib.crc32(chunk), checksum)
                offset += 12 + chunkLength
        self.assertEqual([item["width"] for item in items[-2:]], [100, 100])

    def compileHarness(self, temporaryDirectory):
        executablePath = str(Path(temporaryDirectory) / "notification-harness")
        sources = [repositoryRoot / "mtmr/overlay/NotificationLayoutSolver.swift",
                   repositoryRoot / "mtmr/overlay/NotificationTouchBarItem.swift",
                   repositoryRoot / "mtmr/overlay/NotificationSocketServer.swift",
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
            execution = subprocess.run([executablePath, str(repositoryRoot / "layouts/main.json")],
                                       capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("N=477 margins=304/304", execution.stdout)
            self.assertIn("N=241 margins=422/422", execution.stdout)
            self.assertIn("Layout solver checks passed", execution.stdout)
            print(execution.stdout, end="")


class LayoutViewTests(unittest.TestCase):
    def testContainerAndUnchangedStack(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-layout-view-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "layout-view-tests")
            sourceDirectory = repositoryRoot / "build/work/src"
            sources = sorted(sourcePath for sourcePath in sourceDirectory.rglob("*.swift") if sourcePath.name != "main.swift")
            sources.append(repositoryRoot / "mtmr/tests/LayoutViewTests.swift")
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
            execution = subprocess.run([executablePath, str(repositoryRoot / "layouts/main.json")],
                                       capture_output=True, text=True, timeout=20)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("Layout view checks passed (no Touch Bar created)", execution.stdout)
            self.assertEqual(execution.stderr.count("MTMR layout warning:"), 1, "Warn on the narrow solve, not on text changes")
            self.assertEqual(execution.stderr.count("MTMR item minWidth rejected:"), 2)
            print(execution.stdout, end="")


if __name__ == "__main__":
    unittest.main(verbosity=2)
