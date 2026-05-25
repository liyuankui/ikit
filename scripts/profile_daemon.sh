#!/bin/bash
# iKit Daemon Profiler
# 监控 daemon 运行状态、CPU、内存、转录队列

INTERVAL=5
RECORDING_DIR="$HOME/recordings"
LOG_FILE="$RECORDING_DIR/profile_$(date +%Y%m%d_%H%M%S).log"

echo "🔍 iKit Daemon Profiler"
echo "📊 Interval: ${INTERVAL}s"
echo "📁 Recording dir: $RECORDING_DIR"
echo "📝 Log file: $LOG_FILE"
echo ""

# Header
echo "TIME           IKit CPU   IKit MEM   PY PROC   TRANSCRIBING   QUEUE   ERRS" | tee -a "$LOG_FILE"
echo "------------- ---------- --------- -------- ------------- ------- ----" | tee -a "$LOG_FILE"

while true; do
    NOW=$(date "+%H:%M:%S")

    # iKit 进程 CPU 和内存
    IKIT_STATS=$(ps aux | grep -E "[i]kit meet daemon" | awk '{cpu+=$3; mem+=$4} END {printf "%.1f%% %.0fMB", cpu, mem/1024}')

    # Python 转录进程数量
    PY_COUNT=$(ps aux | grep -c "[p]ython.*transcribe.py" || echo "0")

    # 正在转录的文件
    TRANSCRIBING=$(ps aux | grep "[p]ython.*transcribe.py" | grep -o "20260116-[0-9]*" | sort -u | head -1 | xargs -I {} basename {} .m4a 2>/dev/null)

    # 待转录队列（m4a 文件数 - json 文件数）
    TODAY_DIR=$(ls -td "$RECORDING_DIR"/20* 2>/dev/null | head -1)
    if [ -n "$TODAY_DIR" ]; then
        M4A_COUNT=$(find "$TODAY_DIR" -name "*.m4a" 2>/dev/null | wc -l | xargs)
        JSON_COUNT=$(find "$TODAY_DIR" -name "*.json" 2>/dev/null | wc -l | xargs)
        QUEUE=$((M4A_COUNT / 2 - JSON_COUNT))  # 除以2因为双轨
        [ $QUEUE -lt 0 ] && QUEUE=0
    else
        QUEUE="N/A"
    fi

    # 最近的错误
    ERRS=0
    if [ -n "$TODAY_DIR" ] && [ -f "$TODAY_DIR"/ikit-*.log ]; then
        ERRS=$(tail -100 "$TODAY_DIR"/ikit-*.log 2>/dev/null | grep -c "ERROR\|❌\|Failed" || echo "0")
    fi

    # 输出
    printf "%-13s %-10s %-9s %-8s %-13s %-7s %s\n" \
        "$NOW" \
        "$IKIT_STATS" \
        "${PY_COUNT} proc" \
        "$TRANSCRIBING" \
        "$QUEUE files" \
        "$ERRS errs" | tee -a "$LOG_FILE"

    sleep $INTERVAL
done
