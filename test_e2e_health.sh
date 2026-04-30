#!/bin/bash
# iKit E2E Test - HealthKit Module
# 测试 HealthKit 相关功能

# 不使用 set -e，因为我们需要测试失败的命令
# 改为手动检查每个测试的结果

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_DIR="/tmp/ikit_test_health_${TIMESTAMP}"
LOG_FILE="${TEST_DIR}/health_test.log"

mkdir -p "${TEST_DIR}"

echo "=== iKit HealthKit E2E Test [${TIMESTAMP}] ===" | tee "${LOG_FILE}"
echo "Test directory: ${TEST_DIR}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

if [ ! -f ".build/debug/ikit" ]; then
    echo "Error: ikit not built." | tee -a "${LOG_FILE}"
    exit 1
fi

IKIT_BIN=".build/debug/ikit"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Test function
test_cmd() {
    local name="$1"
    local cmd="$2"
    local expect_fail="${3:-false}"

    echo "[TEST] ${name}" | tee -a "${LOG_FILE}"

    if eval "${cmd}" >> "${LOG_FILE}" 2>&1; then
        if [ "$expect_fail" = "true" ]; then
            echo "❌ FAIL: Expected to fail but succeeded" | tee -a "${LOG_FILE}"
            ((FAIL_COUNT++))
            return 1
        else
            echo "✅ PASS" | tee -a "${LOG_FILE}"
            ((PASS_COUNT++))
            return 0
        fi
    else
        if [ "$expect_fail" = "true" ]; then
            echo "✅ PASS: Failed as expected" | tee -a "${LOG_FILE}"
            ((PASS_COUNT++))
            return 0
        else
            echo "❌ FAIL" | tee -a "${LOG_FILE}"
            ((FAIL_COUNT++))
            return 1
        fi
    fi
}

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
        ((FAIL_COUNT++))
        return 1
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "🏥 HEALTH Module - Basic Commands" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# Test 1: health types (应该总是工作，不需要 HealthKit)
test_output "Health: types command" "${IKIT_BIN} health types" "Available health data types"

# Test 2: health types 包含所有预期类型
test_output "Health: types includes steps" "${IKIT_BIN} health types" "steps"
test_output "Health: types includes distance" "${IKIT_BIN} health types" "distance"
test_output "Health: types includes activeEnergy" "${IKIT_BIN} health types" "activeEnergy"
test_output "Health: types includes heartRate" "${IKIT_BIN} health types" "heartRate"
test_output "Health: types includes restingHeartRate" "${IKIT_BIN} health types" "restingHeartRate"

echo "" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "🏥 HEALTH Module - Error Handling" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# Test 3: 无效子命令 - 应该显示帮助（友好设计）
test_output "Health: invalid subcommand shows help" "${IKIT_BIN} health invalid_subcommand" "Health: Query Apple Health data"

# Test 4: 无效数据类型
test_output "Health: invalid type shows error" "${IKIT_BIN} health today invalid_type" "Unknown type"

# Test 5: today 缺少参数 - 应该显示帮助
test_output "Health: today without type shows help" "${IKIT_BIN} health today" "Health: Query Apple Health data"

echo "" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "🏥 HEALTH Module - macOS Limitations" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# Test 6: HealthKit 不可用时的错误信息
test_output "Health: today shows limitation message" "${IKIT_BIN} health today steps" "HealthKit is not available"
test_output "Health: error mentions macOS 13" "${IKIT_BIN} health today steps" "macOS 13"
test_output "Health: error mentions entitlements" "${IKIT_BIN} health today steps" "entitlements"

echo "" | tee -a "${LOG_FILE}"

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "📊 Test Summary" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "Total: $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT)) | Passed: ${PASS_COUNT} | Failed: ${FAIL_COUNT} | Skipped: ${SKIP_COUNT}" | tee -a "${LOG_FILE}"
if [ $((PASS_COUNT + FAIL_COUNT)) -gt 0 ]; then
    SUCCESS_RATE=$(awk "BEGIN {printf \"%.1f\", ${PASS_COUNT}*100.0/(${PASS_COUNT}+${FAIL_COUNT})}")
    echo "Success Rate: ${SUCCESS_RATE}%" | tee -a "${LOG_FILE}"
fi
echo "" | tee -a "${LOG_FILE}"
echo "✅ Tested Features:" | tee -a "${LOG_FILE}"
echo "  - health types: 列出所有可用数据类型" | tee -a "${LOG_FILE}"
echo "  - health today: 显示今日汇总（需 HealthKit）" | tee -a "${LOG_FILE}"
echo "  - 错误处理: 无效命令/类型参数" | tee -a "${LOG_FILE}"
echo "  - macOS 限制: 清晰的错误提示" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"
echo "⚠️  Platform Notes:" | tee -a "${LOG_FILE}"
echo "  - HealthKit 在 macOS CLI 中访问受限" | tee -a "${LOG_FILE}"
echo "  - 完整功能需要 iOS/iPadOS 或 entitlements 配置" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"
echo "Test artifacts: ${TEST_DIR}" | tee -a "${LOG_FILE}"
echo "=== HealthKit E2E Test Complete ===" | tee -a "${LOG_FILE}"

if [ ${FAIL_COUNT} -gt 0 ]; then
    exit 1
fi
