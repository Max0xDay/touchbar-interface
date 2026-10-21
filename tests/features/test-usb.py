#!/usr/bin/env python3
"""USB filter and preview protocol tests without accessing USB hardware."""

from pathlib import Path
import json
import subprocess
import tempfile
import unittest

repositoryRoot = Path(__file__).resolve().parents[2]


class USBDeviceTests(unittest.TestCase):
    def testDeviceFilter(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-usb-test-") as temporaryDirectory:
            executablePath = str(Path(temporaryDirectory) / "usb-tests")
            compilation = subprocess.run(
                ["swiftc", "-target", "arm64-apple-macosx11.0", "-swift-version", "5",
                 str(repositoryRoot / "mtmr/overlay/USBDeviceMonitor.swift"),
                 str(repositoryRoot / "mtmr/overlay/ChargingMonitor.swift"),
                 str(repositoryRoot / "tests/features/USBDeviceTests.swift"),
                 "-framework", "Cocoa", "-framework", "IOKit", "-o", executablePath],
                capture_output=True, text=True, timeout=120)
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            execution = subprocess.run([executablePath], capture_output=True, text=True, timeout=10)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("USB device filter checks passed", execution.stdout)

    def testUSBPreview(self):
        preview = subprocess.run(
            [str(repositoryRoot / "bin/tbctl"), "particles", "--usb", "--dry-run"],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(preview.returncode, 0, preview.stderr)
        self.assertEqual(json.loads(preview.stdout), {"cmd": "particles", "preset": "usb"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
