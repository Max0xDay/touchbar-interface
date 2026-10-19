#!/usr/bin/env python3
"""Teams watcher mapping and event routing; no live Teams control."""
import argparse
import json
from pathlib import Path
import runpy
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch

repositoryRoot = Path(__file__).resolve().parents[2]
watcher = runpy.run_path(str(repositoryRoot / "teams/teams-watch"))


class TeamsWatcherTests(unittest.TestCase):
    def testMappingAndJoinClock(self):
        mapped = watcher["mappedState"]({"inCall": True, "mic": "unmuted", "camera": "off", "focused": True}, "Planning", 100)
        self.assertEqual(mapped, {"cmd": "teams", "online": True, "inCall": True, "title": "Planning", "mic": "on", "camera": "off", "focused": True, "joinedAt": 100, "durationText": None})
        unknown = watcher["mappedState"]({"inCall": True, "mic": "future", "camera": "future"}, "Planning", 100)
        self.assertEqual((unknown["mic"], unknown["camera"]), ("unknown", "unknown"))
        self.assertFalse(watcher["mappedState"]({}, "", None)["inCall"])

    def testDiscoveryBindingAndCallEnd(self):
        published = []
        eventWatcher = watcher["TeamsWatcher"](None, published.append)
        requests = []
        eventWatcher.send = lambda method, parameters=None, session=None, callback=None: requests.append((method, parameters, session, callback))
        eventWatcher.processMessage({"method": "Target.targetCreated", "params": {"targetInfo": {"targetId": "ABC", "type": "page", "url": "https://teams.microsoft.com/", "title": "Planning | Microsoft Teams"}}})
        self.assertEqual(requests[0][0], "Target.attachToTarget")
        requests[0][3]({"sessionId": "session"})
        self.assertIn("Runtime.addBinding", [request[0] for request in requests])
        binding = {"method": "Runtime.bindingCalled", "sessionId": "session", "params": {"name": "mtmrTeamsState", "payload": json.dumps({"inCall": True, "mic": "muted", "camera": "on", "focused": True, "durationText": "12:03"})}}
        eventWatcher.processMessage(binding)
        callState = published[-1]
        self.assertEqual((callState["mic"], callState["camera"], callState["durationText"]), ("muted", "on", "12:03"))
        self.assertEqual(published[-2]["title"], "Meeting joined")
        commandCount = len(published)
        eventWatcher.processMessage(binding)
        self.assertEqual(len(published), commandCount, "Unchanged snapshots must not be pushed")
        binding["params"]["payload"] = json.dumps({"inCall": True, "mic": "unmuted", "camera": "off", "focused": False})
        eventWatcher.processMessage(binding)
        self.assertEqual((published[-1]["mic"], published[-1]["camera"], published[-1]["focused"]), ("on", "off", False))
        self.assertEqual(published[-1]["joinedAt"], callState["joinedAt"])
        eventWatcher.processMessage({"method": "Target.targetDestroyed", "params": {"targetId": "ABC"}})
        self.assertFalse(published[-1]["inCall"])

    def testNavigationReinjectsAndIgnoresOtherBindings(self):
        eventWatcher = watcher["TeamsWatcher"](None, lambda command: None)
        eventWatcher.sessions["session"] = {"targetId": "ABC", "title": "Planning"}
        requests = []
        eventWatcher.send = lambda method, parameters=None, session=None, callback=None: requests.append(method)
        eventWatcher.processMessage({"method": "Runtime.executionContextCreated", "sessionId": "session", "params": {"context": {"id": 7, "auxData": {"isDefault": True}}}})
        self.assertIn("Runtime.evaluate", requests)
        eventWatcher.processMessage({"method": "Runtime.bindingCalled", "sessionId": "session", "params": {"name": "other", "payload": "{}"}})
        self.assertEqual(eventWatcher.states, {})

    def testReconnectWaitsForSnapshotsAndKeepsJoinClock(self):
        published = []
        eventWatcher = watcher["TeamsWatcher"](None, published.append, {"ABC": 100})
        eventWatcher.discoveryFinished = False
        eventWatcher.targets["ABC"] = {"title": "Planning | Microsoft Teams"}
        eventWatcher.discovered({})
        self.assertEqual(published, [], "Discovery acknowledgement is not a confirmed call end")
        eventWatcher.receiveSnapshot("ABC", {"inCall": True, "mic": "muted"})
        self.assertEqual(len(published), 1, "Reconnect must not duplicate a join notification")
        self.assertEqual(published[0]["joinedAt"], 100)
        eventWatcher.receiveSnapshot("ABC", {"inCall": False})
        self.assertFalse(published[-1]["inCall"])

    def testIdleBlocksWithoutRepeatedRequests(self):
        requests = []

        class FakeConnection:
            socket = object()

            def send_text(self, text):
                requests.append(json.loads(text))

            def receive_text(self):
                return '{"id":1,"result":{}}'

        publisher = argparse.Namespace(retryAt=None, retry=lambda: None)
        eventWatcher = watcher["TeamsWatcher"](FakeConnection(), lambda command: None)
        with patch.object(watcher["select"], "select", side_effect=[([FakeConnection.socket], [], []), RuntimeError("idle boundary")]) as selectReads:
            with self.assertRaisesRegex(RuntimeError, "idle boundary"):
                eventWatcher.run(publisher)
        self.assertEqual([request["method"] for request in requests], ["Target.setDiscoverTargets"])
        self.assertIsNone(selectReads.call_args.args[3], "No pending requests: idle select must have no timeout")

    def testSocketDelivery(self):
        commands = []
        serverErrors = []
        with tempfile.TemporaryDirectory(prefix="teams-watch-test-", dir="/tmp") as directory:
            socketPath = str(Path(directory) / "fake.sock")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                server.bind(socketPath)
                server.listen(1)
                server.settimeout(3)

                def receive():
                    try:
                        connection, _ = server.accept()
                        with connection:
                            connection.settimeout(3)
                            commands.append(json.loads(connection.makefile("rb").readline()))
                            connection.sendall(b'{"ok":true}\n')
                    except (OSError, ValueError) as error:
                        serverErrors.append(str(error))

                worker = threading.Thread(target=receive)
                worker.start()
                publisher = watcher["Publisher"](argparse.Namespace(dry_run=False, socket=socketPath))
                command = watcher["mappedState"]({"inCall": False}, "", None)
                publisher.publish(command)
                publisher.publish(command)
                worker.join(timeout=4)
                self.assertFalse(worker.is_alive())
                self.assertEqual(serverErrors, [])
                self.assertEqual(commands, [command])
                self.assertIsNone(publisher.pending)
                self.assertIsNone(publisher.retryAt)


if __name__ == "__main__":
    unittest.main(verbosity=2)
