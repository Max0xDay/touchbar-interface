#!/usr/bin/env python3
"""Standalone notification and layout views; no hardware Touch Bar."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys

repositoryRoot = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(repositoryRoot / "tests/support"))
from harness import compileSwiftHarness

def renderedActualLayout(directory):
    """layouts/actual.json with ${REPO} substituted, exactly as `tbctl layout actual` would install it."""
    rendered = subprocess.run([str(repositoryRoot / "bin/tbctl"), "layout", "actual", "--dry-run"],
                              capture_output=True, text=True, check=True, timeout=10).stdout
    layoutPath = Path(directory) / "actual.json"
    layoutPath.write_text(rendered)
    return layoutPath


class ActualLayoutTests(unittest.TestCase):
    def testLayout(self):
        with tempfile.TemporaryDirectory() as temporaryDirectory:
            items = json.loads(renderedActualLayout(temporaryDirectory).read_text())
        self.assertIsInstance(items, list)
        identifiers = [item["id"] for item in items if "id" in item]
        self.assertEqual(len(identifiers), len(set(identifiers)))
        self.assertNotIn("teams-mic", identifiers)
        self.assertNotIn("teams-camera", identifiers)
        self.assertEqual([item["watcher"] for item in items if "watcher" in item],
                         [[str(repositoryRoot / "teams/teams-watch")]])
        appControls = [item for item in items if item["type"] == "appControls"]
        self.assertEqual(len(appControls), 1)
        self.assertEqual(appControls[0]["align"], "right")
        self.assertEqual(appControls[0]["panels"], ["system", "teams", "ytmusic", "praatvol", "stats", "fan"])
        self.assertEqual(appControls[0]["teams"], {"directory": str(repositoryRoot / "teams")})


class LayoutViewTests(unittest.TestCase):
    def testContainerAndUnchangedStack(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-layout-view-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "layout-view-tests")
            sourceDirectory = repositoryRoot / "build/work/src"
            sources = sorted(sourcePath for sourcePath in sourceDirectory.rglob("*.swift") if sourcePath.name != "main.swift")
            sources.append(repositoryRoot / "tests/features/LayoutViewTests.swift")
            sources.append(repositoryRoot / "tests/features/LiveButtonTests.swift")
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


class DebugLogTests(unittest.TestCase):
    def testLazyRuntimeToggle(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-debug-log-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "debug-log-tests")
            sources = [repositoryRoot / "mtmr/overlay/DebugLog.swift",
                       repositoryRoot / "tests/features/DebugLogTests.swift"]
            compilation = compileSwiftHarness(executablePath, sources)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executablePath], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertEqual(execution.stderr.count("MTMR-notif:"), 1)
            self.assertIn("MTMR-notif: event state=began directTouches=2", execution.stderr)


class NotificationAreaTests(unittest.TestCase):
    def testTextSwipeAndTransitions(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-area-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "notification-area-tests")
            sources = [repositoryRoot / "mtmr/overlay/DebugLog.swift",
                       repositoryRoot / "mtmr/overlay/NotificationLayoutSolver.swift",
                       repositoryRoot / "mtmr/overlay/NotificationAreaView.swift",
                       repositoryRoot / "mtmr/overlay/NotificationTouchBarItem.swift",
                       repositoryRoot / "mtmr/overlay/NotificationStore.swift",
                       repositoryRoot / "mtmr/overlay/TouchBarIcon.swift",
                       repositoryRoot / "tests/features/NotificationAreaTests.swift"]
            compilation = compileSwiftHarness(executablePath, sources)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executablePath], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("Notification area checks passed", execution.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
