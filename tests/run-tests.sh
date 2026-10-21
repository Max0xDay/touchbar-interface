#!/bin/bash
# Run after mtmr/build.sh; all sockets/status commands are temporary fakes.
set -euo pipefail
scriptDirectory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for testGroup in core features; do
  for testPath in "${scriptDirectory}/${testGroup}"/test-*.py; do
    printf '==> %s\n' "${testPath}"
    python3 -I "${testPath}"
  done
done
