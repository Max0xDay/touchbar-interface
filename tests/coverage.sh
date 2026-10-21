#!/bin/bash
# Run after mtmr/build.sh. Measure only the explicit core source list.
set -euo pipefail
scriptDirectory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repositoryRoot="$(cd "${scriptDirectory}/.." && pwd)"
cd "${repositoryRoot}"
coverageDirectory="$(mktemp -d /tmp/touchbar-coverage.XXXXXX)"
printf 'Coverage artifacts: %s\n' "${coverageDirectory}"
printf 'Coverage is informational; there is no target.\n'
export MTMR_COVERAGE_DIRECTORY="${coverageDirectory}"
export LLVM_PROFILE_FILE="${coverageDirectory}/%m-%p.profraw"
export COVERAGE_FILE="${coverageDirectory}/.coverage"
coreFiles=(
  mtmr/overlay/NotificationLayoutSolver.swift
  mtmr/overlay/NotificationStore.swift
  mtmr/overlay/NotificationSocketServer.swift
  mtmr/overlay/LiveButtonStore.swift
  mtmr/overlay/LiveButtonBinding.swift
  mtmr/overlay/WatcherSupervisor.swift
)
pythonCoverage=false
if python3 -m coverage --version >/dev/null 2>&1; then
  pythonCoverage=true
  export MTMR_PYTHON_COVERAGE=1
else
  printf 'SKIP: Python coverage requires coverage.py; reporting Swift coverage only.\n'
fi
for testPath in "${scriptDirectory}/core"/test-*.py; do
  if [[ "${pythonCoverage}" == true ]]; then
    python3 -m coverage run --parallel-mode "${testPath}"
  else
    python3 -I "${testPath}"
  fi
done
xcrun llvm-profdata merge -sparse "${coverageDirectory}"/*.profraw -o "${coverageDirectory}/core.profdata"
coverageObjects=()
for executablePath in "${coverageDirectory}"/*; do
  if [[ -x "${executablePath}" && -f "${executablePath}" ]]; then
    if [[ "${#coverageObjects[@]}" -eq 0 ]]; then
      coverageObjects+=("${executablePath}")
    else
      coverageObjects+=(-object "${executablePath}")
    fi
  fi
done
xcrun llvm-cov report "${coverageObjects[@]}" -instr-profile="${coverageDirectory}/core.profdata" \
  "${coreFiles[@]}" | tee "${coverageDirectory}/swift-report.txt"
coverageStatus=0
for sourcePath in "${coreFiles[@]}"; do
  if ! awk -v name="$(basename "${sourcePath}")" '$1 == name { found=1 } END { exit !found }' "${coverageDirectory}/swift-report.txt"; then
    printf 'FAIL: No coverage mapping for %s.\n' "${sourcePath}" >&2
    coverageStatus=1
  fi
done
if [[ "${pythonCoverage}" == true ]]; then
  python3 -m coverage combine "${coverageDirectory}"
  if ! python3 -m coverage report --include="*/bin/tbctl" --precision=2; then
    coverageStatus=1
  fi
fi
exit "${coverageStatus}"
