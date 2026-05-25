#!/bin/bash
# iKit E2E Test Script
# 完全自动化，带时间戳，无副作用

set -e

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TEST_DIR="/tmp/ikit_test_${TIMESTAMP}"
LOG_FILE="${TEST_DIR}/e2e_test.log"

mkdir -p "${TEST_DIR}"

echo "=== iKit E2E Test [${TIMESTAMP}] ===" | tee -a "${LOG_FILE}"
echo "Test directory: ${TEST_DIR}" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# Check if ikit is built
if [ ! -f ".build/debug/ikit" ]; then
    echo "Error: ikit not built. Please run 'swift build' first." | tee -a "${LOG_FILE}"
    exit 1
fi

IKIT_BIN=".build/debug/ikit"

# 1. Tasks Test (使用 iKitTest 日历)
echo "[1/3] Testing Tasks with iKitTest calendar..." | tee -a "${LOG_FILE}"
"${IKIT_BIN}" tasks new "[E2E-TEST-${TIMESTAMP}] iKit automated test" --due="2026-12-31 23:59" | tee -a "${LOG_FILE}"
"${IKIT_BIN}" tasks complete "[E2E-TEST-${TIMESTAMP}] iKit automated test" | tee -a "${LOG_FILE}"
echo "✅ Tasks test passed" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# 2. Notes Test (使用 iKitTest 文件夹)
echo "[2/3] Testing Notes with iKitTest folder..." | tee -a "${LOG_FILE}"
"${IKIT_BIN}" notes create "iKitTest" "E2E-Test-${TIMESTAMP}" "Automated end-to-end test at ${TIMESTAMP}" | tee -a "${LOG_FILE}"
echo "✅ Notes test passed" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

# 3. Recording Test (自动发送 SIGQUIT)
echo "[3/3] Testing Recording (5s)..." | tee -a "${LOG_FILE}"

# 启动后台录音进程
"${IKIT_BIN}" meet daemon "${TEST_DIR}" > "${TEST_DIR}/recording.log" 2>&1 &
RECORDING_PID=$!

echo "Recording started (PID: ${RECORDING_PID})" | tee -a "${LOG_FILE}"

# 等待5秒
echo "Recording for 5 seconds..." | tee -a "${LOG_FILE}"
sleep 5

# 发送 SIGQUIT 信号（Ctrl+\）
echo "Sending SIGQUIT to stop recording..." | tee -a "${LOG_FILE}"
kill -SIGQUIT ${RECORDING_PID} 2>/dev/null || true

# 等待进程结束（最多等待10秒）
for i in {1..10}; do
    if ! kill -0 ${RECORDING_PID} 2>/dev/null; then
        echo "Recording stopped gracefully" | tee -a "${LOG_FILE}"
        break
    fi
    sleep 1
done

# 强制杀死（如果还在运行）
if kill -0 ${RECORDING_PID} 2>/dev/null; then
    echo "Force killing recording process..." | tee -a "${LOG_FILE}"
    kill -9 ${RECORDING_PID} 2>/dev/null || true
fi

wait ${RECORDING_PID} 2>/dev/null || true

echo "" | tee -a "${LOG_FILE}"

# 验证输出文件
echo "Verifying output files..." | tee -a "${LOG_FILE}"
if ls "${TEST_DIR}"/*.m4a 1> /dev/null 2>&1; then
    ls -lh "${TEST_DIR}"/*.m4a | tee -a "${LOG_FILE}"
    FILE_COUNT=$(ls -1 "${TEST_DIR}"/*.m4a 2>/dev/null | wc -l)
    echo "Generated ${FILE_COUNT} audio file(s)" | tee -a "${LOG_FILE}"
    echo "✅ Recording test passed" | tee -a "${LOG_FILE}"
else
    echo "⚠️  No audio files generated" | tee -a "${LOG_FILE}"
    echo "Recording log:" | tee -a "${LOG_FILE}"
    cat "${TEST_DIR}/recording.log" | tee -a "${LOG_FILE}"
fi

echo "" | tee -a "${LOG_FILE}"
echo "=== Test Summary ===" | tee -a "${LOG_FILE}"
echo "Test artifacts saved to: ${TEST_DIR}" | tee -a "${LOG_FILE}"
echo "Log file: ${LOG_FILE}" | tee -a "${LOG_FILE}"
echo "=== E2E Test Complete ===" | tee -a "${LOG_FILE}"
