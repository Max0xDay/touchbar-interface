"""Compile temporary Swift harnesses, optionally retaining coverage objects."""
import os
from pathlib import Path
import shutil
import subprocess


def compileSwiftHarness(executablePath, sources, compilationArguments=()):
    coverageDirectory = os.environ.get("MTMR_COVERAGE_DIRECTORY")
    coverageArguments = []
    if coverageDirectory:
        coverageArguments = ["-profile-generate", "-profile-coverage-mapping", "-module-name", "CoreCoverage"]
    compilation = subprocess.run(
        ["swiftc", "-target", "arm64-apple-macosx11.0", "-swift-version", "5",
         *coverageArguments, *map(str, sources), *compilationArguments, "-o", executablePath],
        capture_output=True, text=True, timeout=180)
    if coverageDirectory and compilation.returncode == 0:
        shutil.copy2(executablePath, Path(coverageDirectory) / Path(executablePath).name)
    return compilation


def compileAppHarness(repositoryRoot, executablePath, harnessPath):
    sourceDirectory = repositoryRoot / "build/work/src"
    sources = sorted(path for path in sourceDirectory.rglob("*.swift") if path.name != "main.swift")
    # Use original overlay paths so coverage reports identify the maintained sources.
    sources = [repositoryRoot / "mtmr/overlay" / path.name
               if (repositoryRoot / "mtmr/overlay" / path.name).exists() else path for path in sources]
    sources.append(harnessPath)
    bridgeObjects = sorted((repositoryRoot / "build/work/objects").glob("*.o"))
    if not bridgeObjects:
        raise RuntimeError("Run mtmr/build.sh before the core binding tests")
    sdkExecution = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True, text=True,
                                  check=True, timeout=10)
    sdkPath = Path(sdkExecution.stdout.strip())
    arguments = ["-sdk", str(sdkPath), "-import-objc-header",
                 str(sourceDirectory / "CBridge/TouchBarPrivateApi-Bridging.h"),
                 "-I", str(sourceDirectory / "CBridge"),
                 "-F", str(sdkPath / "System/Library/PrivateFrameworks"), *map(str, bridgeObjects)]
    for framework in ("Cocoa", "CoreLocation", "CoreAudio", "AVFoundation", "IOKit", "EventKit",
                      "ScriptingBridge", "ServiceManagement", "DFRFoundation", "MultitouchSupport",
                      "CoreBrightness", "CoreDisplay"):
        arguments.extend(["-framework", framework])
    return compileSwiftHarness(executablePath, sources, arguments)
