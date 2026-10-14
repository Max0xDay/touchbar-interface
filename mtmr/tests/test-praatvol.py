#!/usr/bin/env python3
"""Focused praatvol checks. Only a temporary fake control socket is used."""

import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

repositoryRoot = Path(__file__).resolve().parents[2]


class PraatvolPanelTests(unittest.TestCase):
    def testProtocolDisplayAndReconnect(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-praatvol-", dir="/tmp") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "praatvol-tests")
            sources = [repositoryRoot / "mtmr/overlay/PraatvolClient.swift",
                       repositoryRoot / "mtmr/tests/PraatvolPanelTests.swift"]
            compilation = subprocess.run(
                ["swiftc", "-target", "arm64-apple-macosx11.0", "-swift-version", "5",
                 *map(str, sources), "-o", executablePath],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            socketPath = str(Path(temporaryDirectory) / "control.sock")
            serverErrors = []
            requests = []
            reconnectTimes = []
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(socketPath)
                listener.listen(4)
                listener.settimeout(10)
                server = threading.Thread(target=self.serveFake, args=(listener, requests, reconnectTimes, serverErrors))
                server.start()
                execution = subprocess.run([executablePath, socketPath], capture_output=True, text=True, timeout=15)
                server.join(timeout=11)
            self.assertFalse(server.is_alive(), "Fake server did not finish")
            self.assertEqual(serverErrors, [])
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("praatvol protocol, display and socket checks passed", execution.stdout)
            self.assertEqual(requests, ["subscribe", "subscribe", "stop", "transcribe", "keep"])
            self.assertGreaterEqual(reconnectTimes[1] - reconnectTimes[0], 1.9)
            missingExecution = subprocess.run(
                [executablePath, "--offline", str(Path(temporaryDirectory) / "missing.sock")],
                capture_output=True, text=True, timeout=10)
            self.assertEqual(missingExecution.returncode, 0, missingExecution.stderr)
            self.assertEqual(missingExecution.stderr.count("MTMR praatvol offline"), 1, "Offline retries must not spam logs")

    @staticmethod
    def serveFake(listener, requests, reconnectTimes, serverErrors):
        status = {"v": 1, "step": "idle", "kind": None, "startedAt": None,
                  "elapsedSeconds": 0, "microphone": None, "system": None,
                  "uploadFraction": None, "needsAttention": False, "message": None}
        try:
            for index in range(2):
                subscription, _ = listener.accept()
                reconnectTimes.append(time.monotonic())
                with subscription:
                    subscription.settimeout(5)
                    requests.append(json.loads(subscription.makefile("rb").readline())["cmd"])
                    if index == 1:
                        status.update(step="recording", kind="room", startedAt=time.time())
                    reply = status if index == 1 else {"ok": True, "status": status}
                    line = json.dumps(reply).encode() + b"\n"
                    subscription.sendall(line[:13])
                    time.sleep(0.05)
                    subscription.sendall(line[13:])
                    if index == 0:
                        time.sleep(0.1)
                    else:
                        command, _ = listener.accept()
                        with command:
                            command.settimeout(5)
                            requests.append(json.loads(command.makefile("rb").readline())["cmd"])
                            command.sendall(b'{"ok":false,"error":"busy","message":"Busy"}\n')
                        status.update(step="review", durationSeconds=723, uploadBytes=4100000, warnings=[])
                        subscription.sendall(json.dumps(status).encode() + b"\n")
                        for expected in ["transcribe", "keep"]:
                            decision, _ = listener.accept()
                            with decision:
                                decision.settimeout(5)
                                request = json.loads(decision.makefile("rb").readline())["cmd"]
                                requests.append(request)
                                if request != expected:
                                    raise ValueError(f"Expected {expected}, got {request}")
                                decision.sendall(b'{"ok":false,"error":"notReviewing"}\n')
                        if subscription.recv(1) != b"":
                            raise ValueError("Client must close its subscription on stop")
        except Exception as error:
            serverErrors.append(str(error))


if __name__ == "__main__":
    unittest.main(verbosity=2)
