#!/bin/bash
# iKit E2E Test - HealthKit Module (Post-removal)
# HealthKit was removed from CLI (issue #17) - verify stub behavior

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_DIR="/tmp/ikit_test_health_${TIMESTAMP}"
LOG_FILE="${TEST_DIR}/health_test.log"

mkdir -p "${TEST_DIR}"

echo "=== iKit HealthKit E2E Test [${TIMESTAMP}] ===" | tee "${LOG_FILE}"
echo "Test directory: ${TEST_DIR}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

if [ ! -f ".build/debug/ikit" ]; then
    echo "Error: ikit not built. Run: swift build" | tee -a "${LOG_FILE}"
    exit 1
fi

IKIT_BIN=".build/debug/ikit"
PASS_COUNT=0
FAIL_COUNT=0

# Output verification function
test_output() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    echo "[TEST] ${name}" | tee -a "${LOG_FILE}"

    output=$(eval "${cmd}" 2>&1)
    echo "$output" >> "${LOG_FILE}"

    if echo "$output" | grep -q "$expected"; then
        echo "✅ PASS: Found '${expected}'" | tee -a "${LOG_FILE}"
        ((PASS_COUNT++))
        return 0
    else
        echo "❌ FAIL: Expected '${expected}' not found" | tee -a "${LOG_FILE}"
        echo "   Got: $output" | tee -a "${LOG_FILE}"
        ((FAIL_COUNT++))
        return 1
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "🏥 HEALTH Module - CLI Limitation Stub" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# All health commands should show the CLI limitation message
test_output "Health: shows not available message" "${IKIT_BIN} health" "HealthKit is not available in CLI mode"
test_output "Health: mentions App Bundle requirement" "${IKIT_BIN} health" "App Bundle"
test_output "Health: mentions entitlements" "${IKIT_BIN} health" "entitlements"
test_output "Health: types also shows stub" "${IKIT_BIN} health types" "HealthKit is not available in CLI mode"
test_output "Health: today also shows stub" "${IKIT_BIN} health today steps" "HealthKit is not available in CLI mode"

echo "" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "🏥 HEALTH Module - Help Text" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# Help text should reflect limitation
test_output "Health help: shows not available" "${IKIT_BIN} help health" "Not available"

echo "" | tee -a "${LOG_FILE}"

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "📊 Test Summary" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "Total: $((PASS_COUNT + FAIL_COUNT)) | Passed: ${PASS_COUNT} | Failed: ${FAIL_COUNT}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"
echo "Test artifacts: ${TEST_DIR}" | tee -a "${LOG_FILE}"
echo "=== HealthKit E2E Test Complete ===" | tee -a "${LOG_FILE}"

if [ ${FAIL_COUNT} -gt 0 ]; then
    exit 1
fi
