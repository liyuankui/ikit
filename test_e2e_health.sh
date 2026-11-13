#!/bin/bash
# iKit E2E Test - Health Module (shortcut drop ingestion, issue #24)
# Mac-side HealthKit is blocked (issue #17 SIGKILL; issue #24: free-team profiles
# never carry the healthkit entitlement). Data comes from the iPhone shortcut
# drop files; the CLI reads them.

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_DIR="/tmp/ikit_test_health_${TIMESTAMP}"
LOG_FILE="${TEST_DIR}/health_test.log"

mkdir -p "${TEST_DIR}"

echo "=== iKit Health E2E Test [${TIMESTAMP}] ===" | tee -a "${LOG_FILE}"
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

# --- Fixtures: two valid drops + one bad file + one empty dir ---
FIXTURE_DIR="${TEST_DIR}/drops"
EMPTY_DIR="${TEST_DIR}/empty"
mkdir -p "${FIXTURE_DIR}" "${EMPTY_DIR}"
cat > "${FIXTURE_DIR}/health-2026-11-12.json" <<'JSON'
{"date":"2026-11-12","generated_at":"2026-11-12T06:05:00+08:00","sleep":{"asleep_minutes":420,"deep_minutes":80,"rem_minutes":85,"bedtime":"2026-11-11 23:20","wake":"2026-11-12 06:30"},"hrv":{"avg_ms":52,"samples":5},"resting_hr":51,"hr_zone":{"min":44,"max":172,"avg":63}}
JSON
cat > "${FIXTURE_DIR}/health-2026-11-13.json" <<'JSON'
{"date":"2026-11-13","generated_at":"2026-11-13T06:05:00+08:00","sleep":{"asleep_minutes":435,"deep_minutes":95,"rem_minutes":90,"bedtime":"2026-11-12 23:12","wake":"2026-11-13 06:28"},"hrv":{"avg_ms":48,"samples":6},"resting_hr":53,"hr_zone":{"min":45,"max":165,"avg":61}}
JSON
echo "not json" > "${FIXTURE_DIR}/bad.json"

export IKIT_HEALTH_DIR="${FIXTURE_DIR}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "🏥 HEALTH Module - Drop Ingestion" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

test_output "Health: status shows sources and latest" "${IKIT_BIN} health" "latest: 2026-11-13"
test_output "Health: status warns on unreadable file" "${IKIT_BIN} health" "unreadable JSON"
test_output "Health: today renders summary" "${IKIT_BIN} health today" "HRV 48 ms"
test_output "Health: today shows sleep window" "${IKIT_BIN} health today" "asleep 7.2h"
test_output "Health: today --json echoes raw drop" "${IKIT_BIN} health today --json" "asleep_minutes"
test_output "Health: trend renders table" "${IKIT_BIN} health trend" "| 2026-11-13 |"
test_output "Health: trend averages row" "${IKIT_BIN} health trend" "avg"
test_output "Health: trend --days 1 narrows window" "${IKIT_BIN} health trend --days 1" "last 1 day"
test_output "Health: trend --json returns array" "${IKIT_BIN} health trend --json --days 1" "sleep_hours"

# --- Exporter App 格式 fixture（多日多指标 + workouts 干扰文件）---
cat > "${FIXTURE_DIR}/health_export_1794538810_TEST01.json" <<'JSON'
{"exportInfo":{"appVersion":"1.7.0","exportDate":"2026-11-13T03:00:10Z"},"sleepTime":[{"date":"2026-11-10","unit":"min","value":408.8,"stages":{"deep":53.8,"rem":90.2}},{"date":"2026-11-11","unit":"min","value":349.5,"stages":{"deep":53.8,"rem":91.7}}],"heartRateVariability":[{"date":"2026-11-10","unit":"ms","value":32},{"date":"2026-11-11","unit":"ms","value":47}],"restingHeartRate":[{"date":"2026-11-10","unit":"bpm","value":60},{"date":"2026-11-11","unit":"bpm","value":55}],"exerciseMinutes":[{"date":"2026-11-10","unit":"min","value":2}]}
JSON
echo '{"exportInfo":{"appVersion":"1.7.0"},"workouts":[{"activity":"badminton"}]}' > "${FIXTURE_DIR}/workouts_export_TEST.json"

test_output "Health: exporter-format days parsed" "${IKIT_BIN} health trend" "| 2026-11-11 | 5.8h"
test_output "Health: exporter days in trend (deep stage)" "${IKIT_BIN} health trend" "| 2026-11-10 | 6.8h | 0.9h"
test_output "Health: workouts file skipped silently" "${IKIT_BIN} health status" "1 unreadable"

test_output "Health: unknown subcommand fails cleanly" "${IKIT_BIN} health foo" "unknown health subcommand"


# --- prune 测试：多快照按类保留最新 N ---
touch -t 202611130900 "${FIXTURE_DIR}/health_export_1000_OLD.json" "${FIXTURE_DIR}/workouts_export_1000_OLD.json"
touch -t 202611130901 "${FIXTURE_DIR}/health_export_1001_MID.json" "${FIXTURE_DIR}/workouts_export_1001_MID.json"
test_output "Health: prune dry-run lists old snapshots" "${IKIT_BIN} health prune --keep 1 --dry-run" "dry-run.*OLD\|OLD.json"
${IKIT_BIN} health prune --keep 1 >/dev/null 2>&1
[ ! -f "${FIXTURE_DIR}/health_export_1000_OLD.json" ] && [ ! -f "${FIXTURE_DIR}/workouts_export_1001_MID.json" ] && echo "✅ PASS: prune trashed old snapshots" | tee -a "${LOG_FILE}" && ((PASS_COUNT++)) || { echo "❌ FAIL: prune did not trash" | tee -a "${LOG_FILE}"; ((FAIL_COUNT++)); }

echo "" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "🏥 HEALTH Module - Empty State" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

test_output "Health: empty dir gives actionable error" "IKIT_HEALTH_DIR=${EMPTY_DIR} ${IKIT_BIN} health today" "no health drops found"

echo "" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "🏥 HEALTH Module - Help Text" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

test_output "Health help: describes drop reader" "${IKIT_BIN} health --help" "iPhone shortcut drops"

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "📊 Test Summary" | tee -a "${LOG_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "${LOG_FILE}"
echo "Total: $((PASS_COUNT + FAIL_COUNT)) | Passed: ${PASS_COUNT} | Failed: ${FAIL_COUNT}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"
echo "Test artifacts: ${TEST_DIR}" | tee -a "${LOG_FILE}"
echo "=== Health E2E Test Complete ===" | tee -a "${LOG_FILE}"

if [ ${FAIL_COUNT} -gt 0 ]; then
    exit 1
fi
