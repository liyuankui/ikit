#!/bin/bash
# iKit Agent CLI Best Practices — E2E Test Suite
# Tests exit codes, progressive help, error messages, output format
# Reference: context/note/agent-cli-best-practices.md

set -u

IKIT="${1:-.build/debug/ikit}"
PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_exit() {
  local name="$1"
  local expected_exit="$2"
  local cmd="$3"
  TOTAL=$((TOTAL + 1))

  eval "$cmd" > /tmp/ikit_test_stdout 2>/tmp/ikit_test_stderr
  local actual_exit=$?

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo -e "  ${GREEN}✅${NC} $name (exit:$actual_exit)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}❌${NC} $name — expected exit:$expected_exit, got exit:$actual_exit"
    FAIL=$((FAIL + 1))
  fi
}

assert_stdout_contains() {
  local name="$1"
  local pattern="$2"
  local cmd="$3"
  TOTAL=$((TOTAL + 1))

  local output
  output=$(eval "$cmd" 2>&1)
  if echo "$output" | grep -qE "$pattern"; then
    echo -e "  ${GREEN}✅${NC} $name"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}❌${NC} $name — pattern '$pattern' not found in output"
    echo "     Output: $(echo "$output" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

assert_stdout_not_contains() {
  local name="$1"
  local pattern="$2"
  local cmd="$3"
  TOTAL=$((TOTAL + 1))

  local output
  output=$(eval "$cmd" 2>&1)
  if echo "$output" | grep -qE "$pattern"; then
    echo -e "  ${RED}❌${NC} $name — pattern '$pattern' FOUND (should be absent)"
    echo "     Output: $(echo "$output" | head -3)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}✅${NC} $name"
    PASS=$((PASS + 1))
  fi
}

# ═══════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🧪 iKit Agent CLI Best Practices — E2E Tests"
echo "   Binary: $IKIT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check binary exists
if [ ! -f "$IKIT" ]; then
  echo "❌ Binary not found: $IKIT"
  echo "   Run: swift build"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════
echo "📋 P0: Exit Code Propagation"
echo "   Shell exit code must match [exit:N] metadata"
echo ""

assert_exit "Unknown command → exit:1" 1 "$IKIT badcommand"
assert_exit "Missing transcribe arg → exit:1" 1 "$IKIT transcribe"
assert_exit "File not found → exit:1" 1 "$IKIT transcribe /tmp/nonexistent_file_xyz.mp3"
assert_exit "Invalid engine → exit:1" 1 "$IKIT transcribe /dev/null --engine badengine"
assert_exit "Missing tts arg → exit:1" 1 "$IKIT tts"
assert_exit "TTS file not found → exit:1" 1 "$IKIT tts /tmp/nonexistent_xyz.md"
assert_exit "OCR missing arg → exit:1" 1 "$IKIT ocr"
assert_exit "--help → exit:0" 0 "$IKIT --help"
assert_exit "--version → exit:0" 0 "$IKIT --version"
assert_exit "config show → exit:0" 0 "$IKIT config show"
assert_exit "doctor → exit:0" 0 "$IKIT doctor"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 P0: Unknown Command Detection"
echo "   Agent must detect wrong commands via exit code + error message"
echo ""

assert_stdout_contains "Unknown cmd has [error] prefix" '^\[error\]' "$IKIT badcommand"
assert_stdout_contains "Unknown cmd has suggestion" 'Try:' "$IKIT badcommand"
assert_stdout_contains "Unknown cmd has exit metadata" '\[exit:1' "$IKIT badcommand"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 P1: Progressive Help — Missing Subcommand"
echo "   Module with no subcommand gives actionable error, not help dump"
echo ""

assert_exit "task (no sub) → exit:1" 1 "$IKIT task"
assert_exit "cal (no sub) → exit:1" 1 "$IKIT cal"
assert_exit "note (no sub) → exit:1" 1 "$IKIT note"
assert_exit "contact (no sub) → exit:1" 1 "$IKIT contact"
assert_exit "photo (no sub) → exit:1" 1 "$IKIT photo"
assert_exit "sc (no sub) → exit:1" 1 "$IKIT sc"
assert_exit "config (no sub) → exit:1" 1 "$IKIT config"

assert_stdout_contains "task: specific error" 'missing subcommand' "$IKIT task"
assert_stdout_contains "cal: specific error" 'missing subcommand' "$IKIT cal"
assert_stdout_contains "note: specific error" 'missing subcommand' "$IKIT note"
assert_stdout_contains "contact: specific error" 'missing subcommand' "$IKIT contact"
assert_stdout_contains "photo: specific error" 'missing subcommand' "$IKIT photo"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 P1: Progressive Help — Missing Required Args"
echo "   Subcommand with missing args gives specific error"
echo ""

assert_exit "task new (no title) → exit:1" 1 "$IKIT task new"
assert_exit "task complete (no query) → exit:1" 1 "$IKIT task complete"
assert_exit "task delete (no query) → exit:1" 1 "$IKIT task delete"
assert_exit "cal new (no args) → exit:1" 1 "$IKIT cal new"
assert_exit "cal delete (no title) → exit:1" 1 "$IKIT cal delete"
assert_exit "note search (no keyword) → exit:1" 1 "$IKIT note search"
assert_exit "note ls (no args) → exit:1" 1 "$IKIT note ls"
assert_exit "contact search (no name) → exit:1" 1 "$IKIT contact search"
assert_exit "sc run (no name) → exit:1" 1 "$IKIT sc run"

assert_stdout_contains "task new: mentions <title>" 'missing.*title' "$IKIT task new"
assert_stdout_contains "cal new: mentions <title>/<time>" 'missing.*title.*time' "$IKIT cal new"
assert_stdout_contains "note search: mentions <keyword>" 'missing.*keyword' "$IKIT note search"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 P1: Progressive Help — Unknown Subcommand"
echo "   Module with wrong subcommand gives specific error"
echo ""

assert_exit "task xyz → exit:1" 1 "$IKIT task xyz"
assert_exit "cal xyz → exit:1" 1 "$IKIT cal xyz"
assert_exit "note xyz → exit:1" 1 "$IKIT note xyz"
assert_exit "timer xyz → exit:1" 1 "$IKIT timer xyz"
assert_exit "config xyz → exit:1" 1 "$IKIT config xyz"

assert_stdout_contains "task xyz: mentions unknown" "unknown subcommand 'xyz'" "$IKIT task xyz"
assert_stdout_contains "cal xyz: mentions unknown" "unknown subcommand 'xyz'" "$IKIT cal xyz"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 P1: Note ls Path UX"
echo "   'ikit note ls \"folder\"' without path gives helpful error"
echo ""

assert_exit "note ls 'folder' without path → exit:1" 1 "$IKIT note ls 散文"
assert_stdout_contains "note ls path hint" 'missing path.*before folder' "$IKIT note ls 散文"
assert_stdout_contains "note ls suggests correct syntax" 'ikit note ls /' "$IKIT note ls 散文"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 P1: Calendar Output — No Optional()"
echo "   Date output must not contain Swift Optional() wrapper"
echo ""

assert_stdout_not_contains "cal list: no Optional()" 'Optional\(' "$IKIT cal list"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 P1: Output Format Consistency"
echo "   User-facing output should not have [timestamp] prefix"
echo ""

assert_stdout_not_contains "timer list: no timestamp prefix" '^\[20[0-9]{2}-' "$IKIT timer list"
assert_stdout_not_contains "task list: no timestamp prefix" '^\[20[0-9]{2}-' "$IKIT task list"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 P1: Error Message Format"
echo "   All errors follow [error] + suggestion pattern"
echo ""

assert_stdout_contains "transcribe error has [error]" '^\[error\]' "$IKIT transcribe /tmp/nope.mp3"
assert_stdout_contains "transcribe error has Try:" 'Try:' "$IKIT transcribe /tmp/nope.mp3"
assert_stdout_contains "transcribe error has [exit:1]" '\[exit:1' "$IKIT transcribe /tmp/nope.mp3"
assert_stdout_contains "unknown cmd has [error]" '^\[error\]' "$IKIT xyz"
assert_stdout_contains "task (no sub) has [error]" '^\[error\]' "$IKIT task"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "📋 Misc: Help Output"
echo "   --help still works correctly"
echo ""

assert_stdout_contains "top help shows version" 'iKit v' "$IKIT --help"
assert_stdout_contains "top help shows modules" 'notes|tasks|calendar' "$IKIT --help"
assert_stdout_contains "top help shows system section" 'config|doctor|init' "$IKIT --help"
assert_stdout_contains "task --help shows usage" 'Task:' "$IKIT task --help"
assert_stdout_contains "note --help shows usage" 'Note:' "$IKIT note --help"
assert_stdout_contains "transcribe --help shows usage" 'Transcribe:' "$IKIT transcribe --help"

echo ""

# ═══════════════════════════════════════════════════════════════
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Results: $PASS/$TOTAL passed, $FAIL failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Cleanup
rm -f /tmp/ikit_test_stdout /tmp/ikit_test_stderr

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
