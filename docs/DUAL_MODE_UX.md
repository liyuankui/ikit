# iKit Dual-Mode UX Design

> **Design Philosophy**: One codebase, two interfaces - optimized for both humans and AI agents.

---

## Executive Summary

iKit serves two distinct user types with fundamentally different needs:

| User Type | Primary Goal | Interaction Style | Output Format |
|-----------|-------------|-------------------|---------------|
| **Humans** | Understanding, exploration, collaboration | Visual, conversational, serendipitous | Rich UI, natural language |
| **AI Agents** | Automation, integration, efficiency | Structured, predictable, machine-readable | JSON, schemas, APIs |

**Key Insight**: These are not conflicting requirements - they are complementary. A well-designed system can excel at both.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         iKit Core                              │
│                    (Business Logic Layer)                     │
└────────────┬──────────────────────────────┬────────────────────┘
             │                              │
    ┌────────▼────────┐            ┌────────▼────────┐
    │  TUI Interface  │            │  JSON Interface │
    │  (Human-First)  │            │  (Agent-First)   │
    └─────────────────┘            └─────────────────┘
             │                              │
    ┌────────▼────────┐            ┌────────▼────────┐
    │  AI Chat Layer  │            │  Schema Layer   │
    │  (Optional)     │            │  (Typed)        │
    └─────────────────┘            └─────────────────┘
```

**Design Principle**: All commands support both modes. Mode is selected via flags or context.

---

## Mode 1: TUI (Human-First Interface)

### Design Philosophy

**Humans don't want structured data - they want understanding.**

The TUI mode prioritizes:
- ✅ **Situational awareness** - What's happening right now?
- ✅ **Exploration** - Serendipitous discovery
- ✅ **Conversation** - Ask questions, get suggestions
- ✅ **Visual feedback** - Progress, status, relationships

### Core Components

#### 1. Dashboard View (Home Screen)

```
┌─────────────────────────────────────────────────────────────────────┐
│  iKit v2.6.0                     [🟢 Daemon Running]  11:23:45    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  📊 Today's Summary                                                 │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Meetings: 3  |  Tasks: 12  |  Notes: 5  |  Recordings: 2    │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  🔴 Active Recording                                              │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Daily Standup • 14:23 elapsed • 2 speakers                │   │
│  │  [████████████████░░░░░░░░] 63%                            │   │
│  │  📸 127 screenshots • 🔍 OCR: 45/127 complete              │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  📝 Recent Activity                                                │
│  • 14:20  Task completed: "Review Q4 metrics"                   │
│  • 14:15  Calendar event: "1:1 with Sarah" added                │
│  • 13:50  Note synced: "Product roadmap"                         │
│                                                                     │
│  [Press '?' for help • 'q' to quit • '/' to search]              │
└─────────────────────────────────────────────────────────────────────┘
```

#### 2. Meeting View (Real-time Transcription)

```
┌─────────────────────────────────────────────────────────────────────┐
│  📼 Daily Standup                             [Recording • 14:23]    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  [14:23:10] Remote │ So for the Q4 metrics, we need to...      │
│  [14:23:15] You    │ What about the conversion rate?              │
│  [14:23:18] Remote │ That's actually improved by 15%...         │
│  [14:23:22] You    │ Great, what drove that?                       │
│  [14:23:25] Remote │ The new checkout flow, mainly...            │
│  [14:23:30] You    │ 👍 Nice work                                  │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │ 💡 AI Suggestion                                            │   │
│  │ Consider capturing the checkout flow                     │   │
│  │ optimization as a separate action item.                  │   │
│  │                                                            │   │
│  │ [a] Accept  [d] Dismiss  [?] Explain                      │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  💬 [Ask a question about this meeting...]                         │
│                                                                     │
│  [Press 's' to stop • 'p' to pause • 'h' for history]             │
└─────────────────────────────────────────────────────────────────────┘
```

#### 3. Task/Calendar View (Interactive Lists)

```
┌─────────────────────────────────────────────────────────────────────┐
│  ✅ Tasks                                               [12 total]   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  📅 Overdue (2)                              🔴 High Priority (3)    │
│  ☐ Review Q4 metrics                  Due: Yesterday               │
│  ☐ Update documentation                 Due: 2025-01-14             │
│                                                                     │
│  📅 Today (5)                                                     │
│  ☐ Send weekly report to team           Due: 5:00 PM               │
│  ☑ Review pull requests                ✓ Completed 2h ago        │
│  ☐ Prepare for design review            Due: 3:00 PM               │
│                                                                     │
│  📅 Upcoming (5)                                                   │
│  ☐ Q1 planning session                 Due: 2025-01-20             │
│                                                                     │
│  [+ Add Task]  [f] Filter  [s] Sort  [Enter] to view details      │
│                                                                     │
│  💬 [Ask AI: "What should I prioritize today?"]                   │
└─────────────────────────────────────────────────────────────────────┘
```

#### 4. AI Chat Interface (Future)

```
┌─────────────────────────────────────────────────────────────────────┐
│  🤖 AI Assistant                                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  You: What tasks are due this week?                                │
│                                                                     │
│  AI: You have 5 tasks due this week:                               │
│                                                                     │
│      📅 High Priority:                                             │
│      • Send weekly report (Today, 5:00 PM)                        │
│      • Design review prep (Today, 3:00 PM)                        │
│                                                                     │
│      📅 This Week:                                                 │
│      • Q1 planning session (Monday)                               │
│      • Review documentation (Wednesday)                           │
│                                                                     │
│      💡 Suggestion: The weekly report and design review        │
│      are both today. Would you like me to help prioritize?       │
│                                                                     │
│      [a] Yes, help me prioritize  [b] Show full task list       │
│                                                                     │
│  You: [typing...]                                                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Interactions

| Action | Key/Command | Behavior |
|--------|-------------|----------|
| **Navigation** | `Arrow keys` / `Tab` | Move between sections |
| **Search** | `/` | Incremental search across all data |
| **Quick Actions** | `Space` | Toggle checkbox / select item |
| **Details** | `Enter` | Expand item / show details |
| **AI Chat** | `c` | Enter AI conversation mode |
| **Help** | `?` | Context-sensitive help |
| **Quit** | `q` / `Ctrl+C` | Exit TUI |

### Real-time Feedback Patterns

#### 1. Progress Indicators

```
Processing: [████████████░░░░░] 60% (3/5 files)
ETA: 12s | Transcribing: meeting_20250116.m4a
```

#### 2. Status Changes

```
✅ Task completed: "Review Q4 metrics"
🔴 Recording started: Daily Standup
📝 New transcript available (14 sentences)
```

#### 3. Smart Notifications

```
💡 Suggestion: You have 3 tasks due in < 2 hours
   [s] Show tasks  [d] Dismiss  [snooze] 1h
```

---

## Mode 2: JSON (Agent-First Interface)

### Design Philosophy

**Agents need predictability and structure - not human-friendly formatting.**

The JSON mode prioritizes:
- ✅ **Consistent schemas** - Never change without versioning
- ✅ **Complete information** - No "..." truncation
- ✅ **Machine-readable** - No formatted strings, use raw types
- ✅ **Stable APIs** - Backward compatibility matters

### Core Schemas

#### Standard Output Format

```json
{
  "version": "2.6.0",
  "timestamp": "2025-01-16T11:23:45Z",
  "status": "success",
  "data": { /* command-specific data */ },
  "meta": {
    "processing_time_ms": 123,
    "cache_hit": false,
    "source": "eventkit"
  }
}
```

#### Command: Task List

```json
{
  "version": "2.6.0",
  "timestamp": "2025-01-16T11:23:45Z",
  "status": "success",
  "data": {
    "tasks": [
      {
        "id": "task_123://ical.mac.com/12345",
        "title": "Review Q4 metrics",
        "notes": "Check conversion rates",
        "due_date": "2025-01-15T17:00:00Z",
        "completed": false,
        "priority": "high",
        "created_at": "2025-01-14T09:00:00Z",
        "modified_at": "2025-01-15T10:30:00Z",
        "tags": ["q4", "metrics", "priority"],
        "calendar_event_id": null
      }
    ],
    "total": 12,
    "completed": 5,
    "overdue": 2,
    "due_today": 5
  },
  "meta": {
    "processing_time_ms": 45,
    "source": "eventkit",
    "filter": {
      "completed": false,
      "priority": null
    }
  }
}
```

#### Command: Transcription Result

```json
{
  "version": "2.6.0",
  "timestamp": "2025-01-16T11:23:45Z",
  "status": "success",
  "data": {
    "recording": {
      "id": "20250116-110635",
      "started_at": "2025-01-16T11:06:35Z",
      "ended_at": "2025-01-16T11:12:29Z",
      "duration_seconds": 354,
      "files": {
        "mic": "/path/to/rec.m4a",
        "system": "/path/to/sys.m4a",
        "merged": "/path/to/merged.m4a"
      }
    },
    "transcript": {
      "sentences": [
        {
          "id": "sent_001",
          "text": "So for the Q4 metrics, we need to...",
          "speaker": "spk_001",
          "speaker_label": "Remote",
          "confidence": 0.95,
          "start_ms": 5000,
          "end_ms": 7500,
          "words": [
            {"text": "So", "start_ms": 5000, "end_ms": 5100},
            {"text": "for", "start_ms": 5100, "end_ms": 5200}
          ]
        }
      ],
      "speakers": [
        {"id": "spk_001", "label": "Remote", "name": null, "confidence": 0.92},
        {"id": "spk_002", "label": "Local", "name": null, "confidence": 0.88}
      ],
      "language": "en",
      "language_detected": true
    },
    "screenshots": [
      {
        "timestamp": 9,
        "path": "/path/to/shot_001.jpg",
        "ocr_text": "GitHub - Project...",
        "names": ["Kyle", "Li"]
      }
    ]
  },
  "meta": {
    "processing_time_ms": 9773,
    "engine": "funasr",
    "model": "paraformer-zh",
    "gating_ratio": 0.79
  }
}
```

### CLI Interface

```bash
# All commands support --json flag
ikit task list --json
ikit cal list --json --start "2025-01-01" --end "2025-01-31"
ikit note sync --json --path ~/Notes
ikit photo ocr --json --last 10 --screenshots

# Streaming mode for long-running operations
ikit meet daemon ~/recordings --json --stream
# Outputs: {"event": "started", ...}
#         {"event": "screenshot", "timestamp": 10, ...}
#         {"event": "transcription_progress", "percent": 45, ...}
#         {"event": "completed", ...}

# Query language for complex filters
ikit task list --json --filter 'due < today() AND priority == "high"'
```

### Agent Experience Design

#### Principle 1: Self-Documenting

Every JSON response includes schema metadata:

```json
{
  "data": { /* ... */ },
  "meta": {
    "schema_version": "2.6.0",
    "schema_url": "https://ikitt.dev/schemas/task-list.json"
  }
}
```

#### Principle 2: Error Clarity

```json
{
  "status": "error",
  "error": {
    "code": "PERMISSION_DENIED",
    "message": "Access to EventKit was denied",
    "recovery": {
      "steps": [
        "Open System Preferences > Privacy & Security",
        "Enable 'iKit' under 'Calendars' and 'Reminders'"
      ],
      "docs_url": "https://ikitt.dev/docs/permissions"
    }
  }
}
```

#### Principle 3: Incremental Results

For operations that take time:

```bash
# Request
ikit task list --json --stream

# Response (line-delimited JSON)
{"type": "start", "total_estimate": 150}
{"type": "progress", "current": 50, "total": 150}
{"type": "item", "data": {/* task 1 */}}
{"type": "item", "data": {/* task 2 */}}
{"type": "complete", "total": 150}
```

---

## Integration: AI Chat Layer

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     TUI Interface                           │
└──────────────────────┬──────────────────────────────────────┘
                       │
        ┌──────────────▼───────────────┐
        │     Conversation Manager     │
        │  - Context from iKit data    │
        │  - RAG on transcripts/notes   │
        │  - Tool calling capability   │
        └──────────────┬───────────────┘
                       │
        ┌──────────────▼───────────────┐
        │       AI Provider Layer      │
        │  - LiteLLM (unified API)     │
        │  - Ollama (local)            │
        │  - OpenAI (cloud)            │
        └──────────────────────────────┘
```

### Conversation Capabilities

#### 1. Query & Search

```
You: What did Sarah say about the Q4 metrics?

AI: Based on the "Daily Standup" meeting (14:20-14:35):

     Sarah mentioned:
     "The Q4 metrics show improvement across the board.
      Conversion rate is up 15%, driven by the new
      checkout flow we deployed last month."

     [View full transcript] [Jump to timestamp]
```

#### 2. Action Suggestions

```
You: I'm feeling overwhelmed today.

AI: I can help. Here's what you have:

     🔴 Due in 2 hours:
     • Send weekly report (5:00 PM)
     • Design review prep (3:00 PM)

     💡 Suggestion: The design review might be flexible
     if you ask. Want me to draft a message to reschedule?

     [a] Yes, draft message  [b] Show calendar  [c] I'll handle it
```

#### 3. Synthesis & Summaries

```
You: Give me a summary of this week's meetings.

AI: This week's meeting summary (3 meetings, 2h 15m total):

     Key Topics:
     • Q4 metrics review - conversion up 15%
     • Product roadmap planning - Q1 priorities set
     • Design review - checkout flow approved

     Action Items:
     • Deploy new checkout flow (assigned to you)
     • Schedule Q1 planning follow-up (due: Monday)
     • Update documentation (due: Wednesday)
```

#### 4. Proactive Notifications

```
AI: Heads up - your 1:1 with Sarah starts in 15 minutes.

     Based on your calendar, she wants to discuss:
     • Q4 metrics performance
     • Team capacity planning

     Would you like me to:
     [a] Pull up relevant notes/tasks
     [b] Draft a meeting agenda
     [c] Show recent conversations with Sarah
```

### Tool Calling (Agent Integration)

Even in TUI mode, AI can call iKit commands:

```swift
// AI can suggest actions that map to iKit commands
AI: I can help you organize that. Let me:
     1. Create a task for the design review
     2. Add it to your calendar
     3. Create a note for reference

     [Confirm] [Cancel]

// When confirmed, execute:
// ikit task new "Design review prep" --due "2025-01-16 15:00"
// ikit cal new "Design Review" "2025-01-16 15:00"
// ikit note new "Design Reviews" "Prep notes..."
```

---

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
- [ ] Add `--json` flag to all existing commands
- [ ] Define JSON schemas for all outputs
- [ ] Add streaming mode for long operations
- [ ] Document JSON API versioning strategy

### Phase 2: TUI Framework (Week 3-4)
- [ ] Integrate SwiftTUI or BlinkUI
- [ ] Build dashboard view skeleton
- [ ] Implement task list view
- [ ] Add keyboard navigation

### Phase 3: Real-time Features (Week 5-6)
- [ ] Daemon status monitoring
- [ ] Live transcription display
- [ ] Progress indicators
- [ ] Screenshot OCR visualization

### Phase 4: AI Integration (Week 7-8)
- [ ] Design conversation schema
- [ ] Implement RAG on iKit data
- [ ] Add tool calling capability
- [ ] Build chat interface

### Phase 5: Polish (Week 9-10)
- [ ] Performance optimization
- [ ] Error handling
- [ ] User testing
- [ ] Documentation

---

## Design Principles Summary

### For Humans (TUI)
1. **Show, Don't Tell** - Visual over textual
2. **Reduce Cognitive Load** - Smart defaults, progressive disclosure
3. **Enable Serendipity** - Browsing, searching, discovering
4. **Conversation First** - Natural language interaction

### For Agents (JSON)
1. **Structure Over Formatting** - Raw types, not strings
2. **Complete Information** - No truncation, full metadata
3. **Stable Contracts** - Versioned schemas, backward compatible
4. **Error Recovery** - Clear error codes, recovery steps

### For Both
1. **Consistency** - Same data, different presentation
2. **Composability** - Combine outputs meaningfully
3. **Performance** - Fast responses, streaming for long ops
4. **Reliability** - Handle failures gracefully

---

## Open Questions for Review

### ✅ RESOLVED - Jeff Dean Review (2025-01-16)

1. **TUI Framework**:
   - ✅ Decision: SwiftTUI primary, ncurses Swift binding as fallback
   - ⚠️ Risk acknowledged: Swift TUI ecosystem is immature
   - 📋 Action: Build POC before committing to framework

2. **AI Provider**:
   - ✅ Decision: LiteLLM-style unified interface (base_url + api_key)
   - ✅ Compatibility: OpenAI/Claude/Ollama all supported
   - ✅ Core neutrality: iKit remains provider-agnostic

3. **Streaming**:
   - ✅ Decision: NDJSON (Newline Delimited JSON) over stdout
   - ✅ Unix-friendly: Pipe-compatible, industry standard

4. **Schema Versioning**:
   - ✅ Decision: Version in meta field, not URL/command
   - ✅ Breaking changes: Major version bump (v3.0)
   - ✅ Agent compatibility: `--schema-version` flag to lock behavior

5. **Offline Support**:
   - ✅ Decision: Local First - SQLite/filesystem
   - ✅ Graceful degradation: AI → search/read-only when offline

6. **Privacy**:
   - ✅ Decision: Optional PII Sanitizer before cloud AI
   - ✅ Local Ollama: Full data (no filtering)

### 🚨 ADDITIONAL RISKS IDENTIFIED

7. **IPC Architecture** (HIGH PRIORITY):
   - Problem: TUI (foreground) needs real-time Daemon status
   - Solution: XPC or Unix Domain Socket for macOS
   - TUI as JSON Stream consumer

8. **Context Window Management**:
   - Problem: RAG may pull excessive data
   - Solution: Summary-only APIs + Token counter

9. **Human-in-the-Loop (HITL)**:
   - Requirement: All write operations need explicit confirmation
   - Implementation: `--dry-run` mode for AI previews

---

## Review History

### Jeff Dean Review (2025-01-16) - ✅ APPROVED

**Verdict**: Approved for execution

**Key Feedback**:
- Strategic alignment with "Human-AI Symbiosis" vision
- Agent-First design is ahead of industry curve
- TUI situational awareness approach validated

**Critical Risks Raised**:
1. 🔴 Swift TUI ecosystem immaturity - requires POC
2. 🔴 IPC architecture for Daemon-TUI communication
3. 🔴 Context window explosion in AI chat

**Recommendations Accepted**:
- NDJSON streaming format
- XPC/Unix Domain Socket for IPC
- Summary-only APIs for RAG
- `--dry-run` mode for all write operations
- PII Sanitizer before cloud AI

**Priority Adjustments**:
```
P0 (Critical): --json support for all commands (foundation)
P1 (High):     Daemon IPC architecture (enables real-time TUI)
P2 (Medium):   TUI POC + framework selection
P3 (Low):      AI Chat integration
```

---

## Appendix: Example Workflows

### Human Workflow (TUI)

```bash
# User starts iKit
$ ikit tui

# Sees dashboard, notices overdue tasks
# Presses 't' to go to tasks

# Filters to "Overdue", sees "Review Q4 metrics"
# Presses 'c' to chat with AI

You: Help me understand what this task involves

AI: This task involves reviewing Q4 metrics including:
     • Conversion rates
     • User acquisition
     • Retention numbers

     The data should be in the "Q4 2024" report.
     Want me to open it?

# User presses 'a' to accept
# AI calls ikit note list, finds the report
# TUI switches to note view showing the report

# User reviews, presses 'Space' to complete task
# TUI shows confirmation, updates dashboard
```

### Agent Workflow (JSON)

```python
import subprocess
import json

# List tasks
result = subprocess.run(
    ["ikit", "task", "list", "--json"],
    capture_output=True,
    text=True
)
data = json.loads(result.stdout)

# Find high-priority overdue tasks
overdue_high = [
    t for t in data["data"]["tasks"]
    if t["due_date"] < today and t["priority"] == "high"
]

# For each task, ask AI for summary
for task in overdue_high:
    summary = ask_ai(
        f"Summarize task: {task['title']}. Notes: {task['notes']}"
    )
    print(f"{task['title']}: {summary}")

# Mark completed if summary is short
for task in overdue_high:
    if len(task["notes"]) < 100:
        subprocess.run([
            "ikit", "task", "complete",
            task["id"], "--json"
        ])
```

---

**Document Version**: 1.1
**Last Updated**: 2025-01-16 (Jeff Dean Review Incorporated)
**Author**: Kyle Li (with Claude)
**Status**: ✅ Approved for Execution
**Next Review**: After P0-P1 completion
