#!/bin/bash

# Configuration
IKIT_BIN="$HOME/.local/bin/ikit"
OUT_DIR="$HOME/Work/iKit/inbox/always_on"
JOURNAL_DIR="$HOME/Notebooks/journal"
CHUNK_DURATION=900 # 15 minutes per slice

echo "🚀 iKit Always-on Recording Active..."
echo "📂 Saving to: $OUT_DIR"

while true; do
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    AUDIO_FILE="$OUT_DIR/$TIMESTAMP.m4a"
    JSON_FILE="$OUT_DIR/$TIMESTAMP.json"
    
    echo "🔴 Recording block [$TIMESTAMP] for $CHUNK_DURATION seconds..."
    
    # 1. Start Recording (Blocking for CHUNK_DURATION)
    # Target common meeting apps
    "$IKIT_BIN" meet record "$AUDIO_FILE" --duration "$CHUNK_DURATION" "Teams" "Meeting" "微信读书" "NetEaseMusic" "Safari" "Chrome" "Slack"
    
    # 2. Trigger Background Processing
    # We use a subshell to run this in background so we can start next recording immediately
    (
        echo "⚙️ Processing block $TIMESTAMP..."
        
        # ASR
        "$IKIT_BIN" meet transcribe "$AUDIO_FILE"
        
        # LLM Summary (if JSON generated)
        if [ -f "$JSON_FILE" ]; then
            "$IKIT_BIN" meet process "$JSON_FILE" "$JOURNAL_DIR"
            echo "✅ Block $TIMESTAMP summarized."
        fi
        
        # Clean up (Move to processed)
        mv "$AUDIO_FILE" "$HOME/Work/iKit/processed/always_on/"
        [ -f "$JSON_FILE" ] && mv "$JSON_FILE" "$HOME/Work/iKit/processed/always_on/"
        
    ) &
    
    # Brief pause to ensure OS handles file locks
    sleep 1
done
