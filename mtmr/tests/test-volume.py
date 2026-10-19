#!/usr/bin/env python3
"""Focused volume tests: no Touch Bar, CoreAudio device access or volume writes."""

from pathlib import Path
import json
import subprocess
import tempfile
import unittest

repositoryRoot = Path(__file__).resolve().parents[2]


class VolumeControlTests(unittest.TestCase):
    def testActualLayout(self):
        layout = json.loads((repositoryRoot / "layouts/actual.json").read_text())
        self.assertFalse(any(item["type"] == "exitTouchbar" for item in layout))
        self.assertEqual(layout[0]["type"], "volume")
        self.assertEqual(layout[0]["width"], 30)
        self.assertEqual(sum(item["type"] == "volume" for item in layout), 1)
        self.assertEqual(layout[1]["type"], "staticButton")
        self.assertEqual(layout[1]["width"], 1)
        self.assertFalse(layout[1]["bordered"])

    def testSystemSlidersPressAndState(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-volume-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "volume-tests")
            sources = [repositoryRoot / "mtmr/overlay/VolumeControlGeometry.swift",
                       repositoryRoot / "mtmr/overlay/OutputVolumeController.swift",
                       repositoryRoot / "mtmr/overlay/DisplayBrightnessController.swift",
                       repositoryRoot / "mtmr/overlay/TouchBarIcon.swift",
                       repositoryRoot / "mtmr/overlay/VolumeControl.swift",
                       repositoryRoot / "mtmr/tests/VolumeControlTests.swift"]
            compilation = subprocess.run(
                ["swiftc", "-target", "arm64-apple-macosx11.0", "-swift-version", "5",
                 *map(str, sources), "-framework", "Cocoa", "-framework", "CoreAudio", "-framework", "IOKit", "-o", executablePath],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executablePath], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("Universal control system sliders, clamping, press timing and volume state checks passed", execution.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
