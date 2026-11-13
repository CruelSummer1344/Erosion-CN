#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/erosion-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
xcrun swiftc \
  Erosion/Helpers/Functions/SystemCompatibility.swift \
  Erosion/Helpers/Functions/WriteHelpers.swift \
  Erosion/Helpers/Functions/VerifiedBackup.swift \
  Tests/Regressions.swift -o "$TEST_BUILD_DIR/regressions"
"$TEST_BUILD_DIR/regressions"
