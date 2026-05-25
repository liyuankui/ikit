# Meeting Recorder Skill

A meeting recording and transcription automation skill for AI agents (Claude, Copilot CLI, etc.). Supports iKit + MacWhisper dual workflows for recording, transcribing, summarizing, and archiving meetings.

## Features

- 🎙️ **Recording**: iKit daemon for continuous recording (mic-only or system + mic)
- 📝 **Transcription**: FunASR (via iKit) or MacWhisper
- 📋 **Summaries**: Structured meeting notes with highlights, decisions, action items
- 📅 **Outlook Integration**: Auto-fetch meeting metadata via `/outlook-helper` skill
- 🗂️ **Recurring Meetings**: Track and auto-match recurring meetings
- 🔄 **Archive**: Auto-archive to journal with bi-directional links

## Requirements

- **iKit** (this repo) — meeting recording daemon (`ikit meet daemon`)
- [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper) (optional) — alternative transcription
- Node.js — for utility scripts
- `/outlook-helper` skill (optional) — for Outlook calendar integration

## Setup

> **If you already have iKit installed**, the skill ships at `iKit/skills/meeting-recorder/` — just copy it to your agent's skills directory.

1. **Copy this skill** to your agent's skills directory:
   ```bash
   # From the iKit repo root
   cp -r skills/meeting-recorder ~/.agents/skills/
   # or for Claude Code
   cp -r skills/meeting-recorder ~/.claude/skills/
   ```

2. **Configure SKILL.md** — replace all `{WORKSPACE_DIR}` and `{SKILL_DIR}` placeholders:
   - `{WORKSPACE_DIR}` → your workspace root (e.g., `~/Notebooks`, `~/Work`)
   - `{SKILL_DIR}` → path to this skill (e.g., `~/.agents/skills/meeting-recorder`)

3. **Set up recordings directory**:
   ```bash
   mkdir -p ~/recordings
   ```

4. **Configure MacWhisper** (if using Workflow B):
   - Set output directory to `{WORKSPACE_DIR}/inbox/whisper/`

5. **Add your recurring meetings** to `data/recurrent-meetings.json`

## Usage

Trigger the skill by telling your AI agent:

- `"录个会"` / `"Start recording"` → Starts iKit recording daemon
- `"解读会议"` / `"Interpret meeting"` → Processes latest MacWhisper transcript
- `"生成纪要"` / `"Generate meeting notes"` → Reads iKit JSON transcripts and generates notes
- `"管理定期会议"` / `"Manage recurring meetings"` → Lists/adds/matches recurring meetings
- `"stop"` / `"停止录音"` → Stops recording and triggers summary generation

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/merge-transcripts.js` | Merge iKit JSON transcripts with optional time-range filter |
| `scripts/meeting-manager.js` | Manage recurring meetings (list/match/add/history) |

### merge-transcripts.js
```bash
# Merge all transcripts for a day
node scripts/merge-transcripts.js ~/recordings/2026-01-01

# Merge only transcripts from a specific hour (e.g., 16:xx)
node scripts/merge-transcripts.js ~/recordings/2026-01-01 16
```

### meeting-manager.js
```bash
# Set your journal directory
export MEETING_JOURNAL_DIR=~/your-workspace/journal

node scripts/meeting-manager.js list
node scripts/meeting-manager.js match
node scripts/meeting-manager.js add --name "Standup" --day monday --time "10:00-11:00"
node scripts/meeting-manager.js history weekly-standup
```

## Customization

### Highlights Focus Areas

In `SKILL.md`, the **Highlights** section has example focus areas. Customize these to match your interests:
```
- Technical Innovation
- Process Improvement
- Risk & Decisions
- Team & Collaboration
```

### Timezone

Update `timezone` in `data/recurrent-meetings.json` and ensure your system timezone is configured correctly.

### Archive Path

Replace `{WORKSPACE_DIR}` in `SKILL.md` with your workspace root to configure where meeting notes are archived.

## File Structure

```
meeting-recorder/
├── SKILL.md                        # Main skill definition
├── README.md                       # This file
├── data/
│   └── recurrent-meetings.json     # Your recurring meetings registry
├── references/
│   ├── recurring-meetings.md       # Recurring meetings documentation
│   ├── decisions-template.md       # Template for recording design decisions
│   └── learnings-template.md       # Template for capturing learnings
└── scripts/
    ├── merge-transcripts.js        # Merge iKit JSON transcripts
    └── meeting-manager.js          # Manage recurring meetings
```

## License

MIT
