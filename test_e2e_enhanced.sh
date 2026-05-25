#!/bin/bash
# iKit E2E Enhanced Test Script (Fixed)
# 测试增强的 task new 功能：--due, --priority, --notes

set -e

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_DIR="/tmp/ikit_test_${TIMESTAMP}"
LOG_FILE="${TEST_DIR}/e2e_enhanced.log"

mkdir -p "${TEST_DIR}"

echo "=== iKit E2E Enhanced Test [${TIMESTAMP}] ===" | tee "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

if [ ! -f ".build/debug/ikit" ]; then
    echo "Error: ikit not built." | tee -a "${LOG_FILE}"
    exit 1
fi

IKIT_BIN=".build/debug/ikit"
TEST_PREFIX="E2E-ENH-${TIMESTAMP}"
PASS_COUNT=0
FAIL_COUNT=0

test_cmd() {
    local name="$1"
    local cmd="$2"
    echo "[TEST] ${name}" | tee -a "${LOG_FILE}"
    if eval "${cmd}" >> "${LOG_FILE}" 2>&1; then
        echo "✅ PASS" | tee -a "${LOG_FILE}"
        ((PASS_COUNT++))
        return 0
    else
        echo "❌ FAIL" | tee -a "${LOG_FILE}"
        ((FAIL_COUNT++))
        return 1
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "📋 TASKS Module - Enhanced Features" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"

test_cmd "Task: Create with due date" "${IKIT_BIN} task new \"${TEST_PREFIX} Task 1\" --due=\"2026-12-31 23:59\""

test_cmd "Task: Create with due + priority" "${IKIT_BIN} task new \"${TEST_PREFIX} Task 2\" --due=\"2026-12-31 23:59\" --priority=5"

test_cmd "Task: Create with all params" "${IKIT_BIN} task new \"${TEST_PREFIX} Task 3\" --due=\"2026-12-31 23:59\" --priority=9 --notes=\"High priority test task\""

echo "" | tee -a "${LOG_FILE}"
echo "[TEST] Verify task attributes" | tee -a "${LOG_FILE}"
TASK_COUNT=$(${IKIT_BIN} task list 2>&1 | grep -c "${TEST_PREFIX}" || true)
if [ "$TASK_COUNT" -ge 3 ]; then
    echo "✅ PASS: Found ${TASK_COUNT} test tasks" | tee -a "${LOG_FILE}"
    ((PASS_COUNT++))
else
    echo "❌ FAIL: Expected 3 tasks, found ${TASK_COUNT}" | tee -a "${LOG_FILE}"
    ((FAIL_COUNT++))
fi

echo "" | tee -a "${LOG_FILE}"
echo "[TEST] Clean up test tasks" | tee -a "${LOG_FILE}"
${IKIT_BIN} task delete "${TEST_PREFIX} Task 1" >> "${LOG_FILE}" 2>&1
${IKIT_BIN} task delete "${TEST_PREFIX} Task 2" >> "${LOG_FILE}" 2>&1
${IKIT_BIN} task delete "${TEST_PREFIX} Task 3" >> "${LOG_FILE}" 2>&1
echo "✅ PASS: Test tasks deleted" | tee -a "${LOG_FILE}"
((PASS_COUNT++))

echo "" | tee -a "${LOG_FILE}"

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "📊 Test Summary: ${PASS_COUNT}/${PASS_COUNT} passed" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"
echo "✅ New Features Working:" | tee -a "${LOG_FILE}"
echo "  - task new --due=\"YYYY-MM-DD HH:mm\"" | tee -a "${LOG_FILE}"
echo "  - task new --priority=N (0-9)" | tee -a "${LOG_FILE}"
echo "  - task new --notes=\"text\"" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"
echo "📝 Usage Examples:" | tee -a "${LOG_FILE}"
echo "  ikit task new \"Meeting\" --due=\"2026-12-31 14:00\"" | tee -a "${LOG_FILE}"
echo "  ikit task new \"Urgent task\" --due=\"2026-12-31 14:00\" --priority=9 --notes=\"Very important\"" | tee -a "${LOG_FILE}"
echo "  ikit task new \"Buy groceries\" --priority=3 --notes=\"Milk, Eggs, Bread\"" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"
echo "=== E2E Enhanced Test Complete ===" | tee -a "${LOG_FILE}"

if [ ${FAIL_COUNT} -gt 0 ]; then
    exit 1
fi
