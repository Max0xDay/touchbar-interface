#!/bin/bash
# Run after mtmr/build.sh; all sockets/status commands are temporary fakes.
set -euo pipefail
scriptDirectory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for testPath in "${scriptDirectory}"/test-*.py; do
  python3 -I "${testPath}"
done
