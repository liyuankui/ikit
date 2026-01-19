# AGENTS.md - iKit Repository Guide

> This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Layer 1: Surface (凝)

> **Purpose**: Quick orientation, < 30 seconds to grasp where you are
> **Exposure**: Always visible

### What is this place?

**iKit** is a native macOS CLI tool (Swift) designed for AI Agents to manage Apple's core productivity applications: Notes, Tasks, Calendar, Photos, Contacts, Shortcuts, and a Meeting recording/transcription system.

**Architecture**: Monolithic single-file design (`main.swift` - ~2,400 lines) organized with MARK sections.

**Platform**: macOS 14.0+ | **Language**: Swift 5.9+ | **Version**: v2.6.0

### Hard Rules (硬规则)

**所有 AI 助手必须遵守的硬规则:**

1. **语言优先级 (Language Priority)**
   - 默认使用**中文**回答所有问题
   - 关键概念可添加英文参考
   - 仅当用户明确要求时使用英文

2. **Markdown 文件自动打开 (Auto-open Created MD Files)**
   - 代理工作过程中创建任何 `.md` 文件后，必须自动为用户打开
   - 使用 macOS 命令: `open /path/to/file.md`

3. **会话结束检查 (Session Closing Checklist)**
   - 会话结束时确认: 测试通过、代码已格式化、提交信息正确
   - 运行 E2E 测试确保功能完整

### Quick Start Commands

```bash
# Build (debug)
swift build

# Build (release)
swift build -c release

# Install
make install

# Run E2E tests
./test_e2e_comprehensive.sh

# Format code
swift-format --strict --parallel Sources/iKit/main.swift
```

---

## Layer 2: Operations (析)

> **Purpose**: Daily operations, what agents need 80% of the time
> **Exposure**: Per task

### Build Commands

```bash
# Debug build
swift build

# Release build (optimized)
swift build -c release

# Install to ~/.local/bin/
swift build -c release && cp .build/release/ikit ~/.local/bin/ikit

# Or using Makefile
make install

# Clean build artifacts
rm -rf .build && swift build -c release
```

Build output: `.build/arm64-apple-macosx/debug/ikit` or `.build/arm64-apple-macosx/release/ikit`

---

### Test Commands

The project uses shell-based E2E tests (no Swift unit tests):

```bash
# Comprehensive E2E test suite (covers all documented features)
./test_e2e_comprehensive.sh

# Other E2E test variants
./test_e2e.sh
./test_e2e_enhanced.sh
./test_e2e_final.sh

# Feature coverage analysis
./test_coverage.sh
```

Test artifacts are created in `/tmp/ikit_test_<timestamp>/`

---

### Linting & Formatting

**Tool**: swift-format (via pre-commit hooks)

```bash
# Install swift-format
brew install swift-format

# Format Swift code
swift-format --strict --parallel Sources/iKit/main.swift

# Run pre-commit hooks manually
pre-commit run --all-files

# Skip hooks (emergency only)
git commit --no-verify -m "message"
```

Pre-commit hooks include: trailing-whitespace, end-of-file-fixer, check-yaml, detect-private-key, swift-format.

Install hooks: `pip install pre-commit && pre-commit install`

---

### Git Workflows

**CRITICAL**: Always use `--no-pager` flag for git commands

```bash
# Check status and view changes in parallel
git --no-pager status && git --no-pager diff

# Stage and commit
git add . && git commit -m "Add: description"

# View recent commits
git --no-pager log --oneline -10
```

**Commit message patterns**:
- `Log: [description]` - Record events, conversations, sessions
- `Add: [description]` - Add new content, prompts, features
- `Update: [description]` - Update existing content, information
- `Fix: [description]` - Correct errors, broken links, bugs
- `Reorganize: [description]` - Restructure files, move code
- `Clean: [description]` - Remove duplicates, unused content

---

### File Operations Safety Rules

**Before ANY file operation:**
```bash
# 1. Always check file existence
view /path/to/file

# 2. Use edit tool, NOT create for existing files
edit /path/to/existing-file.md
```

**Safety rules**:
- Use `view` before editing existing files
- Use `edit` for modifications (NOT `create` on existing files)
- Always verify file existence before operations
- **DO NOT create `.old`, `.bak`, or `.tmp` backup files** - Git history serves as backup

**File Deletion**:
- **Use `trash` command instead of `rm`** - moves to macOS Trash for recovery

---

## Layer 3: Architecture (控)

> **Purpose**: Project-specific architecture and conventions
> **Exposure**: Per task

### High-Level Architecture

#### File Structure

```
Sources/iKit/
├── main.swift              # Entire CLI (monolithic, 2,385 lines)
└── speech_recorder.swift   # Apple SpeechAnalyzer wrapper (unused, requires macOS 26)

scripts/                    # Python helper scripts
├── transcribe.py           # FunASR transcription with gating
├── fetch_apple_notes.py    # AppleScript notes bridge
├── fuzzy_join.py           # Fuzzy matching utility
├── monitor_meet.sh         # Meeting monitor wrapper
└── always_on.sh            # Keep-alive daemon wrapper
```

#### Module Organization (main.swift)

```
main.swift MARK sections:
├── Imports (11 frameworks: EventKit, Photos, Vision, Contacts, etc.)
├── IOKit Power Management Declarations
├── Global Signal Handling (SIGQUIT for graceful shutdown)
├── Logger (struct) - Unified logging to stderr + ~/recordings/ikit.log
├── Timezone Helper (beijingDateTime)
├── Config Management (~/.config/ikit/config.json)
├── Recorder Module (~line 200)
│   ├── MicRecorder (AVFoundation)
│   ├── SystemRecorder (ScreenCaptureKit)
│   ├── Daemon (background recording with configurable segmentation)
│   └── MeetSession
├── Notes Bridge (AppleScript, ~line 1398)
├── Tool Classes (~line 1659)
│   ├── NotesTool (sync/create/update/delete)
│   ├── RemindersTool (EventKit CRUD)
│   ├── CalendarTool (EventKit CRUD)
│   ├── PhotoTool (Photos framework + Vision OCR)
│   ├── ContactsTool (Contacts framework)
│   └── ShortcutsTool
├── Models (~line 2027)
│   └── SecretaryTool (transcription orchestration)
└── App Entry Point (~line 2162)
```

#### Key Dependencies

- **EventKit** - Reminders & Calendar (native, no app launch required)
- **Photos** + **Vision** - Photo library access + OCR
- **Contacts** - Contact search
- **ScreenCaptureKit** - System audio recording
- **AVFoundation** - Microphone recording
- **IOKit** - Power management (prevent sleep during daemon mode)
- Python (optional): `torch torchaudio funasr modelscope librosa scipy soundfile`

---

### Important Conventions

1. **Signal Handling**: Use **Ctrl+\\** (SIGQUIT) for graceful daemon shutdown, NOT Ctrl+C
2. **Permissions**: EventKit, Photos, ScreenCaptureKit require user authorization on first run
3. **Config Location**: `~/.config/ikit/config.json`
4. **Logs**: `~/recordings/ikit.log`
5. **Recording Default**: `~/recordings/`
6. **Daemon Mode**: Prevents sleep via IOKit assertions; auto-saves recordings at configurable intervals
7. **CLI Pattern**: `ikit [command] [subcommand] [args] [--json] [--id] [--dry-run] [-v]`

#### Daemon Recording Modes

- `--mic-only`: Microphone only
- `--system-only`: System audio only (no echo risk)
- Default (no flag): Both tracks with aggressive gating
- `--interval=N`: Segment duration in minutes (default 15)

#### Meet Transcription

The daemon supports auto-transcription via `scripts/transcribe.py` using FunASR with:
- Aggressive gating to eliminate echo
- Speaker diarization (Local/Remote)
- Dual-track processing (mic + system audio)

---

### Common Development Tasks

**When modifying `main.swift`:**
1. Maintain MARK section organization
2. Use Logger for all output (not print statements)
3. All tool methods use async/await
4. Test changes with E2E suite before committing
5. Format code with swift-format before commit

**When adding new daemon features:**
- Respect the SIGQUIT shutdown pattern
- Consider sleep prevention implications
- Test auto-processing (transcription) independence

**Before committing changes:**
1. Run `./test_e2e_comprehensive.sh` to verify functionality
2. Run `swift-format --strict --parallel Sources/iKit/main.swift`
3. Review changes with `git --no-pager diff`
4. Use appropriate commit message prefix (Add:, Fix:, Update:, etc.)

---

## Layer 4: Context (深)

> **Purpose**: Additional context for this repository
> **Exposure**: On-demand

### Project Context

This is Kyle Li's personal project - an **Agent-Native CLI** optimized for AI agent workflows. Key design philosophy:

- **Agent-First**: JSON output modes for easy parsing
- **Apple-Native**: Uses EventKit, Photos, Contacts - no third-party APIs
- **Offline-First**: All transcription via local FunASR (no cloud dependencies)
- **Dual-Track Recording**: Separate mic/system audio with aggressive gating

### Related Documentation

- **README.md**: Chinese documentation for end users
- **test_e2e_comprehensive.sh**: Full feature coverage examples
- **scripts/transcribe.py**: FunASR integration details

---

### ASR 转录模型详解

项目支持 **3 个 ASR 引擎**，不同引擎使用不同的模型和优化策略。

#### 模型对比表

| ASR 引擎 | 语音识别模型 | 说话人分离模型 | 苹果架构优化 | 适用场景 |
|---------|-------------|---------------|------------|---------|
| **FunASR** | Paraformer (zh/en) | **Cam++** | ❌ MPS 加速（非原生） | 中文会议（默认） |
| **MLX-Whisper** | Whisper large-v3 (MLX) | **pyannote Community-1** | ✅ 深度优化 | 英文会议（Apple Silicon） |
| **WhisperX** | Whisper large-v3 | **内置 DiarizationPipeline** | ❌ 不支持 MPS | 英文会议 |
| **SpeechAnalyzer** | Apple 系统模型 | ❌ **不支持** | ✅ 原生优化 | 仅转录（无需说话人） |

#### FunASR（中文默认）

```python
# 中文配置（完整功能）
model = "paraformer-zh"              # 语音识别
vad_model = "fsmn-vad"               # 语音活动检测
punc_model = "ct-punc"               # 标点恢复
spk_model = "cam++"                  # 说话人分离 ✅

# 英文配置（无说话人分离）
model = "iic/speech_paraformer_asr-en-16k-vocab4199-pytorch"
# spk_model: 不支持 ❌（英文模型无时间戳）
```

**来源**: ModelScope（阿里达摩院）
**设备**: 支持 MPS（通过 PyTorch `torch.backends.mps`）

#### MLX-Whisper（英文，Apple Silicon 优化）

```python
# 语音识别（苹果 MLX 框架）
model = "mlx-community/whisper-large-v3-mlx"

# 说话人分离（HuggingFace）
pipeline = "pyannote/speaker-diarization-community-1"
```

**特点**: 使用苹果官方 MLX 框架，专门针对 Apple Silicon 优化

#### WhisperX（英文）

```python
model = "large-v3"                   # OpenAI Whisper
diarize_model = DiarizationPipeline  # 内置说话人分离
```

**限制**: faster_whisper 不支持 MPS，自动降级到 CPU

#### SpeechAnalyzer（苹果原生，macOS 26+）

```swift
// speech_recorder.swift
@available(macOS 26.0, *)
class AppleSpeechRecorder {
    let transcriber = SpeechTranscriber(locale: locale)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
}
```

**能力**:
- ✅ 超快速度（原生优化）
- ✅ 支持中文/英文
- ✅ 时间戳 (`audioTimeRange`)
- ❌ **不支持说话人分离**

**为什么未启用**: 缺少说话人分离功能，无法满足会议转录的核心需求

#### 时间戳与说话人识别

| 能力 | 模型来源 |
|------|---------|
| **时间戳** | 所有 ASR 模型本身都具备（Paraformer、Whisper） |
| **说话人识别** | 独立的说话人分离模型（Cam++、pyannote、DiarizationPipeline） |

**双轨录制 + 说话人策略**:

```
1. Aggressive Gating（消除回声）
   ├─ 系统音频 → Remote speaker
   └─ 麦克风音频（已消回声）→ Local speaker

2. ASR 转录
   ├─ 系统音频 → ASR (timestamp + spk)
   └─ 麦克风音频 → ASR (timestamp + spk)

3. 合并时间线
   └─ 按 timestamp 排序，保留 track 来源

4. OCR 匹配（可选）
   └─ pyannote + 截图 OCR → 说话人姓名
```

#### 选择建议

| 使用场景 | 推荐方案 | 原因 |
|---------|---------|------|
| 中文会议（需要说话人） | **FunASR** | 唯一支持中文说话人分离 |
| 英文会议 + Apple Silicon | **MLX-Whisper + pyannote** | 苹果原生优化 |
| 仅转录文本（无需说话人） | **SpeechAnalyzer** | 原生速度最快 |

**中文 ASR 目前没有像 MLX-Whisper 那样的深度苹果架构优化版本**，FunASR 只能通过 MPS 获得间接加速。

---

**Last Updated**: 2026-01-16
**Version**: 1.1 - Added ASR models and transcription details
