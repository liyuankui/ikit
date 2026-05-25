#!/bin/bash
# Test for note sync --since parameter (Issue #14)

set -e

IKIT_BIN=".build/debug/ikit"
TEST_DIR="/tmp/ikit-since-test-$$"
TEST_NOTES_DIR="${TEST_DIR}/notes"

echo "[TEST] note sync --since parameter"
echo "======================================"

# Build first
echo "[1/4] Building iKit..."
swift build >/dev/null 2>&1 || { echo "❌ Build failed"; exit 1; }
echo "✅ Build successful"

# Test 2: Verify --since parameter is accepted
echo ""
echo "[2/4] Testing --since parameter parsing..."
TEST_OUTPUT=$(${IKIT_BIN} note sync "${TEST_NOTES_DIR}" --since "invalid-time-format-xyz" 2>&1 || true)

if echo "${TEST_OUTPUT}" | grep -q "Failed to parse time expression"; then
    echo "✅ PASS: Invalid format produces error message"
else
    echo "❌ FAIL: Expected error message for invalid format"
    echo "Output: ${TEST_OUTPUT}"
    exit 1
fi

# Test 3: Verify --since with valid format
echo ""
echo "[3/4] Testing --since with valid format..."
mkdir -p "${TEST_NOTES_DIR}"
TEST_OUTPUT=$(${IKIT_BIN} note sync "${TEST_NOTES_DIR}" --since "1d" 2>&1 || true)

# Should either succeed or fail with permission/error, not crash with "Failed to parse"
if echo "${TEST_OUTPUT}" | grep -q "Failed to parse time expression"; then
    echo "❌ FAIL: Valid format '1d' should not produce parse error"
    echo "Output: ${TEST_OUTPUT}"
    exit 1
else
    echo "✅ PASS: Valid format '1d' accepted (may have other errors, but not parse error)"
fi

# Test 4: Verify help text includes --since
echo ""
echo "[4/4] Testing help text..."
HELP_OUTPUT=$(${IKIT_BIN} note --help 2>&1 || true)
if echo "${HELP_OUTPUT}" | grep -q "\-\-since=TIME"; then
    echo "✅ PASS: Help text includes --since=TIME"
else
    echo "❌ FAIL: Help text missing --since=TIME"
    echo "Output: ${HELP_OUTPUT}"
    exit 1
fi

# Cleanup
rm -rf "${TEST_DIR}"

echo ""
echo "======================================"
echo "✅ All tests passed!"
