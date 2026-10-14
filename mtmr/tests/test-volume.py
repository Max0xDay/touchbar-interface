#!/usr/bin/env python3
"""Focused volume tests: no Touch Bar, CoreAudio device access or volume writes."""

from pathlib import Path
import subprocess
import tempfile
import unittest

repositoryRoot = Path(__file__).resolve().parents[2]


class VolumeControlTests(unittest.TestCase):
    def testGeometryAndState(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-volume-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "volume-tests")
            sources = [repositoryRoot / "mtmr/overlay/VolumeControlGeometry.swift",
                       repositoryRoot / "mtmr/overlay/OutputVolumeController.swift",
                       repositoryRoot / "mtmr/tests/VolumeControlTests.swift"]
            compilation = subprocess.run(
                ["swiftc", "-target", "arm64-apple-macosx11.0", "-swift-version", "5",
                 *map(str, sources), "-framework", "CoreAudio", "-o", executablePath],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executablePath], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("Volume control geometry and state checks passed", execution.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
