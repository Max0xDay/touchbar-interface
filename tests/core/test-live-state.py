#!/usr/bin/env python3
"""Run actual live bindings and supervised fake scripts with a temporary home."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

repositoryRoot = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(repositoryRoot / "tests/support"))
from harness import compileAppHarness


class LiveStateTests(unittest.TestCase):
    def testBindingsAndWatcherLifecycle(self):
        with tempfile.TemporaryDirectory(prefix="mtmr-core-state-", dir="/tmp") as directory:
            executablePath = str(Path(directory) / "live-state-tests")
            compilation = compileAppHarness(repositoryRoot, executablePath,
                                            repositoryRoot / "tests/core/LiveStateTests.swift")
            self.assertEqual(compilation.returncode, 0, compilation.stderr)
            environment = dict(os.environ, MTMR_TEST_DIRECTORY=directory,
                               HOME=directory, CFFIXED_USER_HOME=directory)
            execution = subprocess.run([executablePath], env=environment, capture_output=True,
                                       text=True, timeout=12)
            self.assertEqual(execution.returncode, 0, execution.stderr)
            self.assertIn("Core binding and watcher checks passed", execution.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
