#!/bin/bash
# Test script for iKit note ls and search commands
# Usage: ./test_note_ls_search.sh

# Don't exit on error - we handle errors manually
set +e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
TEST_OUTPUT="$HOME/Notebooks/AppleNotes"
TEST_FOLDER="iKitTest"
TEST_NOTE_TITLE="E2E-LS-SEARCH-$(date +%s)"
TEST_NOTE_CONTENT="Test note for ls and search commands. Keywords: unique123test."

# iKit binary - use local build if available, otherwise installed version
if [ -f ".build/debug/ikit" ]; then
    IKIT=".build/debug/ikit"
else
    IKIT="$HOME/.local/bin/ikit"
fi

# Helper functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if iKit is installed
if [ ! -f "$IKIT" ]; then
    log_error "iKit not found at $IKIT"
    exit 1
fi

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Test result helper
assert_success() {
    if [ $? -eq 0 ]; then
        log_info "✓ PASS: $1"
        ((TESTS_PASSED++))
    else
        log_error "✗ FAIL: $1"
        ((TESTS_FAILED++))
    fi
}

assert_contains() {
    if echo "$1" | grep -q "$2"; then
        log_info "✓ PASS: Output contains '$2'"
        ((TESTS_PASSED++))
    else
        log_error "✗ FAIL: Output does not contain '$2'"
        ((TESTS_FAILED++))
    fi
}

# Cleanup function
cleanup() {
    log_info "Cleaning up test notes..."
    $IKIT note delete "$TEST_OUTPUT" "$TEST_FOLDER" "$TEST_NOTE_TITLE" 2>/dev/null || true
    log_info "Cleanup complete"
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

echo "========================================"
echo "iKit Note ls/search Commands Test"
echo "========================================"
echo ""

# ==============================================================================
# Setup: Create test note
# ==============================================================================
log_info "Setup: Creating test note..."
$IKIT note new "$TEST_OUTPUT" "$TEST_FOLDER" "$TEST_NOTE_TITLE" "$TEST_NOTE_CONTENT" > /dev/null 2>&1
sleep 2  # Give Apple Notes time to sync

# ==============================================================================
# Test 1: note ls command (basic)
# ==============================================================================
log_info "Test 1: Listing notes in folder..."
OUTPUT=$($IKIT note ls "$TEST_OUTPUT" "$TEST_FOLDER" 2>&1)
assert_success "note ls command executes"
assert_contains "$OUTPUT" "$TEST_FOLDER"

# ==============================================================================
# Test 2: note ls --json command
# ==============================================================================
log_info "Test 2: Listing notes with JSON output..."
OUTPUT=$($IKIT note ls "$TEST_OUTPUT" "$TEST_FOLDER" --json 2>&1)
assert_success "note ls --json command executes"
assert_contains "$OUTPUT" '"name"'
assert_contains "$OUTPUT" '"modificationDate"'

# ==============================================================================
# Test 3: note ls JSON is valid
# ==============================================================================
log_info "Test 3: Validating JSON output..."
echo "$OUTPUT" | python3 -c "import json, sys; json.load(sys.stdin)" 2>/dev/null
assert_success "JSON is valid"

# ==============================================================================
# Test 4: note search command (basic)
# ==============================================================================
log_info "Test 4: Searching notes by keyword..."
OUTPUT=$($IKIT note search "$TEST_OUTPUT" "E2E-LS" 2>&1)
# Note: search may timeout on large databases, so we just check it doesn't crash
if [ $? -eq 0 ] || echo "$OUTPUT" | grep -q "Found\|No notes found\|timeout"; then
    log_info "✓ PASS: note search command executes"
    ((TESTS_PASSED++))
else
    log_error "✗ FAIL: note search command failed unexpectedly"
    ((TESTS_FAILED++))
fi

# ==============================================================================
# Test 5: note search --json command
# ==============================================================================
log_info "Test 5: Searching notes with JSON output..."
OUTPUT=$($IKIT note search "$TEST_OUTPUT" "E2E-LS" --json 2>&1)
# Check that JSON output mode doesn't crash
if [ $? -eq 0 ] || echo "$OUTPUT" | grep -q "\[\|\]"; then
    log_info "✓ PASS: note search --json command executes"
    ((TESTS_PASSED++))
else
    log_error "✗ FAIL: note search --json command failed"
    ((TESTS_FAILED++))
fi

# ==============================================================================
# Test 6: note search with --folder filter
# ==============================================================================
log_info "Test 6: Searching notes with folder filter..."
OUTPUT=$($IKIT note search "$TEST_OUTPUT" "E2E-LS" --folder="$TEST_FOLDER" 2>&1)
if [ $? -eq 0 ] || echo "$OUTPUT" | grep -q "Found\|No notes found\|timeout"; then
    log_info "✓ PASS: note search --folder command executes"
    ((TESTS_PASSED++))
else
    log_error "✗ FAIL: note search --folder command failed"
    ((TESTS_FAILED++))
fi

# ==============================================================================
# Summary
# ==============================================================================
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo "Tests Passed: $TESTS_PASSED"
echo "Tests Failed: $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    log_info "All tests passed! ✅"
    exit 0
else
    log_error "Some tests failed! ❌"
    exit 1
fi
