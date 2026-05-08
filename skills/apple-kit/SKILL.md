---
name: apple-kit
description: Unified access to Apple ecosystem (Notes, Tasks, Calendar, Photos, Contacts) + multi-engine ASR/TTS via iKit CLI. Agent-first design with smart engine selection (FunASR for Chinese, MLX-Whisper for English). Use when user asks about Apple apps, audio transcription, meeting recording, or needs language-aware transcription.
---

# Apple Kit

**Powered by**: iKit v2.9.0 - Swift CLI for Apple Ecosystem
**Architecture**: JSON-First, Agent-First CLI design


## When to Use

Use this skill when the user asks about Apple apps (Notes, Tasks, Calendar, Photos, Contacts) or needs audio transcription, text-to-speech, or meeting recording via iKit CLI.

## Agent CLI Features

iKit follows "CLI is All Agents Need" principles:

- **Progressive --help**: Commands show usage when called without arguments
- **Error remediation**: Errors include "💡 Try:" suggestions for self-correction
- **Metadata output**: Results include `[exit:N | Xs]` for cost awareness
- **Single namespace**: All capabilities as `ikit <command>`

Example:
```bash
$ ikit transcribe
[error] transcribe: usage: transcribe <audio-file> [--language zh|en|auto] [--engine groq|funasr]
💡 Try: ikit transcribe meeting.m4a --engine groq
[exit:1 | 0ms]
```

## Quick Reference

| You want to... | iKit Command |
|----------------|--------------|
| **Search Notes** | `rg "keyword" {NOTES_DIR}/` or `ikit note search "keyword"` |
| **Sync Notes** | `ikit note sync` |
| **List Notes in folder** | `ikit note ls "{Folder}"` |
| **Create Note** | `ikit note new "Folder" "Title" "Content"` |
| **Move Note** | `notes-move "Title" "Target"` (faster) |
| **List Tasks** | `ikit task list` |
| **New Task** | `ikit task new "Buy milk" --due="2026-01-01 10:00"` |
| **Complete Task** | `ikit task complete "Buy milk"` |
| **List Calendar** | `ikit cal list` |
| **Outlook Agenda** | `outlook calendar` / `calendar-local.py --date today` |
| **New Event** | `ikit cal new "Meeting" "2024-01-01 10:00"` |
| **List Photos** | `ikit photo list` |
| **OCR Photo** | `ikit photo ocr <assetId>` |
| **OCR Image File** | `ikit ocr <image-path>` |
| **Search Contact** | `ikit contact search "Name"` |
| **Health Data** | `ikit health today steps` |
| **New Timer** | `ikit timer new --time 09:00` |
| **List Timers** | `ikit timer list` |
| **Transcribe (中文)** | `ikit transcribe audio.mp3` (funasr default) |
| **Transcribe (英文)** | `ikit meet transcribe audio.mp3 --engine mlx` ⭐ |
| **Record Meeting** | `ikit meet daemon ~/recordings` |
| **Record Meeting (英文)** | `ikit meet daemon ~/recordings --engine mlx` ⭐ |
| **Text-to-Speech** | `ikit tts article.md` |
| **System Check** | `ikit doctor` |
| **Show Config** | `ikit config show` |

## Module: Notes (备忘录)

### Architecture: Read-Only Mirror + Write Commands

**IMPORTANT**: Notes are synced to local filesystem for **zero-latency read access**.

```bash
# Sync notes (Smart Sync: ~0.2s check time)
ikit note sync

# Default path: {NOTES_DIR}/
# Or set in ~/.config/ikit/config.json: "notes_root": "{NOTES_DIR}"
```

### Read Notes (Always use filesystem mirror)

```bash
# Search notes - FASTER than any API
rg "keyword" {NOTES_DIR}/
rg "keyword" {NOTES_DIR}/{Folder}/ --type md

# List notes in folder
ls {NOTES_DIR}/{Folder}/
ikit note ls "{Folder}" --json   # CLI version with JSON output

# Search via iKit CLI (supports --folder filter)
ikit note search "keyword" --folder="{Folder}" --json

# Read specific note
cat {NOTES_DIR}/{Folder}/note-title.md
```

### Sync Notes

```bash
ikit note sync                         # Smart incremental sync
ikit note sync --since="2026-01-01"    # Sync notes changed after date
ikit note sync --folder="Work"         # Sync specific folder only
```

### Write Notes (Use iKit commands)

```bash
# Create new note
ikit note new "{Folder}" "Title" "Content"

# Append to existing note
ikit note append "{Folder}" "Title" "\n新增内容"

# Update note (replace content)
ikit note update "{Folder}" "Title" "New content"

# Move note between folders
ikit note move "{Folder}" "Title" "{TargetFolder}"

# Delete note
ikit note delete "{Folder}" "Title"
```

## Module: Tasks (提醒事项)

```bash
# List all tasks (JSON for AI parsing)
ikit task list --json

# Create new task
ikit task new "Buy milk"
ikit task new "Submit report" --due="2026-01-15 10:00" --priority=1 --notes="attach PDF"

# Complete task
ikit task complete "Buy milk"

# Delete task
ikit task delete "Buy milk"

# Dry-run (safety check)
ikit task delete "Buy milk" --dry-run
```

**Task Parameters**:
| Parameter | Description |
|-----------|-------------|
| `--due="YYYY-MM-DD HH:mm"` | Due date/time |
| `--priority=N` | Priority (1=high, 5=low) |
| `--notes="text"` | Additional notes |

## Module: Calendar (日历)

> **💡 Outlook 也能查日程**：`outlook calendar` / `calendar-local.py` 可获取 Outlook 365 agenda（含会议详情、与会者）。iKit `cal list` 读 Apple Calendar，Outlook skill 读 Exchange。按需选用。

```bash
# List events (JSON for AI parsing)
ikit cal list --json

# Create new event
ikit cal new "Team Standup" "2026-02-01 10:00"

# Delete event
ikit cal delete "Team Standup"
```

## Module: Photos (照片)

```bash
# List recent photos (JSON for AI parsing)
ikit photo list --json
ikit photo list --json --screenshots
ikit photo list --json --favorites
ikit photo list --json --last 5

# OCR (Extract text from photos)
ikit photo ocr <assetId>
ikit photo ocr --screenshots --last 5  # Batch OCR recent screenshots
```

**Photo metadata includes**:
- assetId
- filename
- filePath (for Read tool)
- creationDate
- modificationDate
- location (GPS coordinates - SENSITIVE!)

## Module: Contacts (联系人)

```bash
# Search contacts (JSON for AI parsing)
ikit contact search "Name" --json
```

## Module: Timer (定时器与自动化)

Schedule notifications and automate workflows.

```bash
# Create daily timer
ikit timer new --time 09:00 --daily --title "Daily Standup"

# Create one-time timer with file/app
ikit timer new --time 10:00 --date 2026-02-01 --open agenda.md

# Create weekly timer (0=Sun, 1=Mon, ...)
ikit timer new --time 14:00 --weekday 1 --with "Visual Studio Code"

# Resume session (restore working context)
ikit timer resume --time 16:30 --session abc123 --pwd {project-dir} --title "Continue coding"

# List all timers
ikit timer list

# Cancel timer
ikit timer cancel timer-daily-0900

# Show execution logs
ikit timer logs
```

**Timer Parameters**:
| Parameter | Description |
|-----------|-------------|
| `--time HH:MM` | Trigger time |
| `--date YYYY-MM-DD` | Specific date |
| `--daily` | Daily repeat |
| `--weekday N` | Weekly repeat (0=Sun, 1=Mon...) |
| `--session ID` | Session ID for resume |
| `--pwd PATH` | Working directory |
| `--open FILE` | Open file on trigger |
| `--with APP` | Open app on trigger |
| `--run CMD` | Run command |
| `--then-run CMD` | Run after notification |
| `--terminal APP` | Terminal app |
| `--title TITLE` | Notification title |
| `--message MSG` | Notification content |

## Module: Transcribe (语音转文字)

`ikit transcribe` 支持 **groq** 和 **funasr** 两个引擎。MLX-Whisper 通过 `ikit meet transcribe` 使用。

> **⚠️ Engine Selection Guide**:
> - **中文会议** → FunASR (`--engine funasr`, offline, default)
> - **英文会议** → MLX-Whisper via `ikit meet transcribe --engine mlx` ⭐
> - **快速/通用** → Groq API (`--engine groq`, cloud, 25MB limit)

```bash
# Quick transcription (FunASR default for Chinese)
ikit transcribe /tmp/recording.mp3

# Specify engine
ikit transcribe meeting.m4a --engine funasr   # Chinese, offline
ikit transcribe meeting.m4a --engine groq     # Fast cloud API, 25MB limit

# Specify language
ikit transcribe audio.wav --language zh
ikit transcribe audio.wav --language en
ikit transcribe audio.wav --language auto     # Auto-detect

# For English with MLX-Whisper (better accuracy) — use meet transcribe
ikit meet transcribe recording.m4a --engine mlx    # English ⭐

# Output: <audio-path>.txt (same directory)
```

**Engine Comparison**:

| Engine | Command | Language | Speed | Accuracy | Cost | Limit |
|--------|---------|----------|-------|----------|------|-------|
| **funasr** | `ikit transcribe` | 中文/中英 | 30x RTF | ⭐⭐⭐⭐ | Free | None |
| **mlx** | `ikit meet transcribe` | **英文专用** | ~10x RTF | ⭐⭐⭐⭐⭐ | Free | None |
| **groq** | `ikit transcribe` | 通用 | 54s/96min | ⭐⭐⭐ | API | 25MB |

**Real-world Performance** (2026-05实测):
| 场景 | FunASR | MLX-Whisper |
|------|--------|-------------|
| 纯中文会议 | ✅ 准确 | ⚠️ 未测试 |
| 纯英文会议 | ❌ 中英混杂 | ✅ **干净准确** |

**Agent Decision Rule**:
```python
if meeting_language == "zh":
    # ikit transcribe --engine funasr
elif meeting_language == "en":
    # ikit meet transcribe --engine mlx
else:
    # 先用 funasr，检查英文词比例决定是否重跑 mlx
```

**Environment**:
- FunASR 1.3.0 + PyTorch (check: `ikit doctor`)
- MLX-Whisper (Apple Silicon optimized, available via `ikit meet`)
- Python: `{FUNASR_ENV}/bin/python3`
- Groq API Key: LiteLLM config

## Module: TTS (文字转语音)

Convert Markdown articles to speech using Edge TTS (Microsoft Azure).

```bash
# Preview markdown cleaning
ikit tts article.md --preview

# Generate TTS (outputs to /tmp by default)
ikit tts article.md

# Specify output path
ikit tts article.md -o ~/Music/podcasts/intro.mp3

# Specify voice
ikit tts article.md --voice zh-CN-XiaoxiaoNeural

# Streaming playback (start playing as first chunk generates)
ikit tts long-article.md --streaming
```

**Available Voices**:
- `zh-CN-XiaoxiaoNeural` (default, female)
- `zh-CN-YunxiNeural` (male)
- `en-US-JennyNeural` (female)
- `en-US-GuyNeural` (male)

**Markdown Cleaning**: Automatically removes:
- YAML frontmatter (`---`)
- Code blocks
- Markdown symbols (`#`, `**`, `__`, `` ` ``, `>`)
- Empty lines

**Streaming Controls**:
- Space: pause/resume
- q: quit

## Security & Privacy

**CRITICAL WARNINGS**:

- **Photos may contain GPS coordinates** - NEVER share without explicit permission
- **Contacts contain personal data** - Handle with care
- **Notes may contain sensitive information** - Ask before sharing

**Safety Features**:
- iKit supports `--dry-run` for destructive operations
- Notes use Read-Only mirror for queries

## Configuration

**Config file**: `~/.config/ikit/config.json`

```json
{
  "notes_root": "{NOTES_DIR}",
  "python_path": "/usr/local/bin/python3",
  "transcribe_script": "{IKIT_DIR}/scripts/transcribe.py",
  "ollama_url": "http://localhost:11434/api/generate",
  "ollama_model": "qwen3:4b",
  "litellm_url": "http://localhost:4444/v1/completions",
  "litellm_model": "deepseek-v3",
  "litellm_vision_model": "qwen-vl",
  "litellm_api_key": "sk-...",
  "meet": {
    "default_mode": "both",
    "default_interval": "15m",
    "auto_transcribe": false,
    "auto_summary": true
  }
}
```

**Config commands**:
```bash
ikit config show    # Show current config
ikit config init    # Initialize default config
```

## Module: Health (健康数据)

Query Apple HealthKit data locally.

```bash
# List available data types
ikit health types

# Get today's summary
ikit health today steps
ikit health today heartRate
ikit health today activeEnergy

# Get recent data
ikit health recent bloodGlucose          # Last 1 hour (default)
ikit health recent heartRate --hours=2   # Last 2 hours
ikit health recent steps --hours=24
```

**Available Data Types**:
| Type | 说明 |
|------|------|
| `steps` | 步数 |
| `distance` | 距离 |
| `activeEnergy` | 活动能量 |
| `heartRate` | 心率 |
| `restingHeartRate` | 静息心率 |
| `bloodGlucose` | 血糖 |

> ⚠️ Requires Health data permission: System Settings > Privacy > Health

## Module: OCR (图片文字识别)

Two OCR pathways:

```bash
# 1. Standalone OCR from image file
ikit ocr /path/to/screenshot.png
ikit ocr /path/to/image.jpg

# 2. OCR from Photos library (by assetId)
ikit photo ocr <assetId>
ikit photo ocr --screenshots --last 5   # Batch OCR last 5 screenshots
```

## System Commands

```bash
# Initialize iKit (first-time setup)
ikit init

# Show current config
ikit config show

# Initialize default config file
ikit config init

# System health check (Python, FunASR, MLX, models cache)
ikit doctor
```

`ikit doctor` checks:
- Python installation
- FunASR, ModelScope, PyTorch
- MLX-Whisper, WhisperX, pyannote
- Model cache sizes (ModelScope + HuggingFace)

## Advanced: Meeting Recording & Transcription

iKit includes `meet` module for recording and transcribing meetings.

> **⚠️ 截屏默认关闭**：`auto_ocr`（录制时自动截屏+OCR）默认 `false`，以降低 CPU 占用。需要截屏时显式传 `--auto-ocr`。
>
> **⚠️ 引擎选择**：中文会议用 FunASR（默认），**英文会议用 MLX-Whisper (`--engine mlx`)**

```bash
# Start background recording (15min segments)
# 中文会议（默认 FunASR）
ikit meet daemon ~/recordings --background --interval=15m

# 英文会议（推荐 MLX-Whisper）
ikit meet daemon ~/recordings --background --interval=15m --engine mlx

# Start with screenshot enabled (higher CPU)
ikit meet daemon ~/recordings --background --interval=15m --auto-ocr

# Check status
ikit meet status

# Stop recording
ikit meet stop

# Transcribe audio with specific engine
ikit meet transcribe ~/recordings/20260101/recording.m4a --engine funasr  # 中文
ikit meet transcribe ~/recordings/20260101/recording.m4a --engine mlx     # 英文 ⭐

# Process transcripts into summary
ikit meet process ~/recordings/20260101/*.txt summary.md
```

## Troubleshooting

### Notes path not found

```bash
# Check config
cat ~/.config/ikit/config.json

# Sync first
ikit note sync
```

### Command not found

```bash
# Check iKit installation
which ikit
# Should output: ~/.local/bin/ikit

# If not found, check symlink
ls -la ~/.local/bin/ikit
```

### Permission denied

macOS requires permissions for:
- **Notes** - System Settings > Privacy > Notes
- **Calendar** - System Settings > Privacy > Calendar
- **Reminders** - System Settings > Privacy > Reminders
- **Photos** - System Settings > Privacy > Photos

## Related Documentation

- **iKit README**: `iKit/README.md`
- **iKit source**: Install path, default `~/.local/bin/ikit`
- **LiteLLM config**: `~/.config/litellm/` (for Groq API key)

### iKit Helper Scripts

Simple shell wrappers for filesystem operations (faster than iKit commands):

```bash
notes-move "Title" "Archive"      # Move note via mv
notes-delete "Title"              # Delete note via rm
notes-list "Folder"               # List notes via ls
notes-search "keyword"            # Search notes via rg
```

Add scripts to `~/bin/` or your PATH for easy access.

---

**Last Updated**: 2026-05-06
**iKit Version**: v2.8.0+ (Multi-engine support + MLX-Whisper for English meetings)

**Key Changes**:
- ✅ Added MLX-Whisper engine for **clean English transcription**
- ✅ Updated engine selection guide (中文 → FunASR, 英文 → MLX)
- ✅ Agent decision rules for automatic engine selection

**See also**: `skills/meeting-recorder/SKILL.md` - Full meeting recording & transcription workflow
