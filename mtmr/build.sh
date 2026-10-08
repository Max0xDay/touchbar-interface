#!/bin/bash
# Builds a native arm64 MTMR.app from the upstream MTMR source using only the Xcode Command Line Tools.
# No Xcode, no Rosetta, no network, no sudo. Output: <repo>/build/MTMR.app
# Runbook and the reasons behind every step: docs/runbook-build-mtmr.md
#
# Usage:  mtmr/build.sh
# Env:    MTMR_CHECKOUT  path to a clone of https://github.com/Toxblh/MTMR (default: ../MTMR next to this repo)
set -euo pipefail

readonly EXPECTED_UPSTREAM_COMMIT="94fc98cceff94cf69a2e7c28f726cf35ab93c461"
readonly BUNDLE_NAME="MTMR.app"
readonly DEPLOYMENT_TARGET="11.0"

scriptDirectory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repositoryRoot="$(cd "${scriptDirectory}/.." && pwd)"
checkoutDirectory="${MTMR_CHECKOUT:-${repositoryRoot}/../MTMR}"
buildDirectory="${repositoryRoot}/build"
workDirectory="${buildDirectory}/work"
bundlePath="${buildDirectory}/${BUNDLE_NAME}"

step() { printf '==> %s\n' "$*"; }
fail() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

check_prerequisites() {
  [[ "$(uname -m)" == "arm64" ]] || fail "this build is arm64-only and must run on Apple Silicon (never under Rosetta)"
  [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)" != "1" ]] || fail "running under Rosetta translation; refusing"
  command -v swiftc >/dev/null || fail "swiftc not found; install the Command Line Tools (xcode-select --install)"
  command -v clang >/dev/null || fail "clang not found; install the Command Line Tools"
  [[ -d "${checkoutDirectory}/MTMR" ]] || fail "MTMR checkout not found at ${checkoutDirectory} (set MTMR_CHECKOUT)"

  sdkPath="$(xcrun --show-sdk-path)"
  privateFrameworksPath="${sdkPath}/System/Library/PrivateFrameworks"
  local framework
  for framework in DFRFoundation MultitouchSupport CoreBrightness; do
    [[ -d "${privateFrameworksPath}/${framework}.framework" ]] || fail "SDK has no ${framework} stub: ${privateFrameworksPath}"
  done

  local actualCommit
  actualCommit="$(git -C "${checkoutDirectory}" rev-parse HEAD)"
  [[ "${actualCommit}" == "${EXPECTED_UPSTREAM_COMMIT}" ]] \
    || fail "upstream is at ${actualCommit}, patches were made for ${EXPECTED_UPSTREAM_COMMIT}; check out that commit or regenerate the patches"
  [[ -z "$(git -C "${checkoutDirectory}" status --porcelain)" ]] || fail "MTMR checkout has local changes; build from a clean checkout"
}

prepare_sources() {
  step "Copying upstream sources"
  rm -rf "${workDirectory}"
  mkdir -p "${workDirectory}/src" "${workDirectory}/objects"
  # Excluded: Xcode-only resources (storyboard, asset catalogue), Sparkle updater key, entitlements, Info.plist (replaced by the overlay).
  rsync -a \
    --exclude 'Assets.xcassets' --exclude 'Base.lproj' --exclude '*.entitlements' \
    --exclude 'Info.plist' --exclude '*.pem' --exclude 'defaultPreset.json' \
    "${checkoutDirectory}/MTMR/" "${workDirectory}/src/"

  step "Applying patches"
  local patch
  for patch in "${scriptDirectory}"/patches/*.patch; do
    patch --quiet -p1 -d "${workDirectory}/src" < "${patch}"
  done
  cp "${scriptDirectory}"/overlay/*.swift "${workDirectory}/src/"
}

compile_bridge() {
  step "Compiling Objective-C/C bridge (arm64)"
  local source
  for source in "${workDirectory}"/src/CBridge/*.m "${workDirectory}"/src/CBridge/*.c; do
    # -fmodules is required: Xcode enables Objective-C modules by default, plain clang does not.
    clang -arch arm64 -mmacosx-version-min="${DEPLOYMENT_TARGET}" -isysroot "${sdkPath}" \
      -fmodules -fmodules-cache-path="${workDirectory}/modulecache" -fobjc-arc -F "${privateFrameworksPath}" \
      -c "${source}" -o "${workDirectory}/objects/$(basename "${source}").o"
  done
}

compile_swift() {
  step "Compiling and linking Swift (arm64)"
  local swiftSources=()
  while IFS= read -r source; do swiftSources+=("${source}"); done < <(find "${workDirectory}/src" -name '*.swift')

  mkdir -p "${bundlePath}/Contents/MacOS"
  # CoreDisplay is a private framework needed for the brightness slider; the SDK ships a link stub for it.
  swiftc -target "arm64-apple-macosx${DEPLOYMENT_TARGET}" -sdk "${sdkPath}" -swift-version 5 -O \
    -import-objc-header "${workDirectory}/src/CBridge/TouchBarPrivateApi-Bridging.h" \
    -I "${workDirectory}/src/CBridge" -F "${privateFrameworksPath}" \
    -module-cache-path "${workDirectory}/modulecache" \
    "${swiftSources[@]}" "${workDirectory}"/objects/*.o \
    -framework Cocoa -framework CoreLocation -framework CoreAudio -framework AVFoundation \
    -framework IOKit -framework EventKit -framework ScriptingBridge -framework ServiceManagement \
    -framework DFRFoundation -framework MultitouchSupport -framework CoreBrightness -framework CoreDisplay \
    -o "${bundlePath}/Contents/MacOS/MTMR"
}

assemble_bundle() {
  step "Assembling ${BUNDLE_NAME}"
  local resources="${bundlePath}/Contents/Resources"
  mkdir -p "${resources}"
  cp "${scriptDirectory}/overlay/Info.plist" "${bundlePath}/Contents/Info.plist"
  cp "${checkoutDirectory}/MTMR/defaultPreset.json" "${resources}/"

  # Each asset-catalogue imageset holds one PNG; ship it as Resources/<imageset name>.png (see BundledImage.swift).
  local imageset png
  for imageset in "${checkoutDirectory}"/MTMR/Assets.xcassets/*.imageset; do
    png="$(find "${imageset}" -maxdepth 1 -name '*.png' | head -n 1)"
    if [[ -n "${png}" ]]; then
      cp "${png}" "${resources}/$(basename "${imageset}" .imageset).png"
    fi
  done
}

sign_and_verify() {
  step "Signing (ad hoc) and verifying"
  codesign --force --sign - "${bundlePath}"
  local architectures
  architectures="$(lipo -archs "${bundlePath}/Contents/MacOS/MTMR")"
  [[ "${architectures}" == "arm64" ]] || fail "expected an arm64-only binary, got: ${architectures}"
  plutil -lint "${bundlePath}/Contents/Info.plist" >/dev/null
  step "Built ${bundlePath} (${architectures})"
}

check_prerequisites
rm -rf "${bundlePath}"
prepare_sources
compile_bridge
compile_swift
assemble_bundle
sign_and_verify
