#!/usr/bin/env python3
"""Pure Teams panel decode, clock and auto-selection tests; no live sockets."""
from pathlib import Path
import subprocess
import runpy
import tempfile
import unittest

repositoryRoot = Path(__file__).resolve().parents[2]


class TeamsPanelTests(unittest.TestCase):
    def testMeetingTitles(self):
        watcherModule = runpy.run_path(str(repositoryRoot / "teams/teams-watch"))
        resolveTitle = watcherModule["cdp"]["meeting_title"]
        for title in ("", "Microsoft Teams", "Chat", "Calendar", "Activity", "Teams", "Calendar | Microsoft Teams"):
            self.assertEqual(resolveTitle({"title": title}), "")
        self.assertEqual(resolveTitle({"title": "Planning | Microsoft Teams"}), "Planning")
        self.assertEqual(resolveTitle({"title": "test meeting"}), "test meeting")

        class Connection:
            def send_text(self, message):
                pass

        messages = []
        watcher = watcherModule["TeamsWatcher"](Connection(), messages.append)
        target = {"targetId": "call", "type": "page", "url": "https://teams.microsoft.com/", "title": "Microsoft Teams"}
        watcher.targetChanged(target)
        watcher.receiveSnapshot("call", {"inCall": True, "title": "Calendar"})
        self.assertEqual(messages[-1]["title"], "")
        watcher.processMessage({"method": "Target.targetInfoChanged", "params": {"targetInfo": dict(target, title="test meeting")}})
        self.assertEqual(messages[-1]["title"], "test meeting")
        watcher.receiveSnapshot("call", {"inCall": True, "title": "Page meeting | Microsoft Teams"})
        self.assertEqual(messages[-1]["title"], "Page meeting")
        watcher.receiveSnapshot("call", {"inCall": True, "title": "Microsoft Teams"})
        self.assertEqual(messages[-1]["title"], "test meeting")
        self.assertIn("title: document.title", watcherModule["observerScript"]())

    def testPanelStateAndSelection(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-teams-", dir="/tmp") as directory:
            executable = str(Path(directory) / "teams-tests")
            compilation = subprocess.run(["swiftc", "-target", "arm64-apple-macosx11.0", "-swift-version", "5",
                                          str(repositoryRoot / "mtmr/overlay/TeamsState.swift"),
                                          str(repositoryRoot / "mtmr/tests/TeamsPanelTests.swift"), "-o", executable],
                                         capture_output=True, text=True, timeout=120)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executable], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("Teams decode, clock and auto-selection checks passed", execution.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
