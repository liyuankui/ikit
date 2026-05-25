#!/bin/bash

# Configuration
INBOX="$HOME/Work/iKit/inbox"
PROCESSED="$HOME/Work/iKit/processed"
OUTBOX="$HOME/Notebooks/journal"
IKIT_BIN="$HOME/.local/bin/ikit"

echo "👀 Monitoring $INBOX for meeting recordings..."

while true; do
    # Find audio files (mp3, m4a, wav) and text/json files
    # Note: We process audio first to generate JSON, then process JSON to generate MD
    
    # 1. Check for Audio Files
    AUDIO_FILES=$(find "$INBOX" -maxdepth 1 -name "*.mp3" -o -name "*.m4a" -o -name "*.wav")
    if [ ! -z "$AUDIO_FILES" ]; then
        for FILE in $AUDIO_FILES; do
            echo "🎤 Found audio: $FILE"
            "$IKIT_BIN" meet transcribe "$FILE"
            
            # Move audio to processed immediately after transcription trigger?
            # Or keep it until JSON is processed?
            # Let's move it to processed to avoid re-transcription loop
            mv "$FILE" "$PROCESSED/"
            echo "✅ Transcribed. Audio moved to processed."
        done
    fi

    # 2. Check for Transcription Files (JSON from FunASR or legacy TXT)
    TRANS_FILES=$(find "$INBOX" -maxdepth 1 -name "*.json" -o -name "*.txt" -o -name "*.md")
    
    if [ ! -z "$TRANS_FILES" ]; then
        for FILE in $TRANS_FILES; do
            echo "🤖 Found transcription: $FILE"
            
            # Process with ikit (Summarize)
            "$IKIT_BIN" meet process "$FILE" "$OUTBOX"
            
            # Move to processed
            mv "$FILE" "$PROCESSED/"
            echo "✅ Summarized. Transcript moved to processed."
        done
    fi
    
    # Wait for 5 seconds
    sleep 5
done
