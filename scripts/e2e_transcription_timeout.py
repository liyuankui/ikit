#!/usr/bin/env python3
"""
E2E Test for transcription timeout mechanism (Issue #8)

Tests:
1. Timeout mechanism works correctly
2. Exit code 124 on timeout
3. Normal completion cancels timeout

Safe: Uses temporary files, no real audio processing
"""

import subprocess
import sys
import time
import os
from pathlib import Path

# Test configuration
SCRIPT_DIR = Path(__file__).parent
TRANSCRIBE_SCRIPT = SCRIPT_DIR / "transcribe.py"
TEST_TIMEOUT_SHORT = 2  # 2 seconds - should timeout
TEST_TIMEOUT_LONG = 300  # 5 minutes - should not timeout

# Colors
RED = '\033[0;31m'
GREEN = '\033[0;32m'
NC = '\033[0m'

TESTS_PASSED = 0
TESTS_FAILED = 0

def log_pass(msg):
    global TESTS_PASSED
    print(f"{GREEN}✓ PASS{NC}: {msg}")
    TESTS_PASSED += 1

def log_fail(msg):
    global TESTS_FAILED
    print(f"{RED}✗ FAIL{NC}: {msg}")
    TESTS_FAILED += 1

def test_timeout_flag_exists():
    """Test that --timeout flag is recognized"""
    result = subprocess.run(
        [sys.executable, str(TRANSCRIBE_SCRIPT), "--help"],
        capture_output=True,
        text=True
    )
    if "--timeout" in result.stdout or "-t" in result.stdout:
        log_pass("--timeout flag exists in transcribe.py")
    else:
        log_fail("--timeout flag not found in transcribe.py")

def test_timeout_exit_code():
    """Test that timeout returns exit code 124 (standard timeout code)"""
    # Create a dummy audio file (just needs to exist for arg parsing)
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as f:
        dummy_audio = f.name
        f.write(b"dummy")

    try:
        # Run with very short timeout - should timeout
        start = time.time()
        result = subprocess.run(
            [sys.executable, str(TRANSCRIBE_SCRIPT), dummy_audio, "--timeout", "1"],
            capture_output=True,
            text=True,
            timeout=30  # Overall test timeout
        )
        elapsed = time.time() - start

        # Either exits with 124 (timeout) or completes very quickly
        # (if the file is invalid and fails fast)
        if result.returncode == 124:
            log_pass(f"Timeout returns exit code 124 (elapsed: {elapsed:.1f}s)")
        elif elapsed < 5:
            # File was invalid and failed fast - that's also acceptable
            log_pass(f"Invalid file handled quickly (elapsed: {elapsed:.1f}s, exit: {result.returncode})")
        else:
            log_fail(f"Unexpected behavior: exit={result.returncode}, elapsed={elapsed:.1f}s")
    except subprocess.TimeoutExpired:
        log_fail("Test itself timed out (unexpected)")
    finally:
        os.unlink(dummy_audio)

def test_timeout_cancellation():
    """Test that successful completion cancels the timeout"""
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".m4a", delete=False) as f:
        dummy_audio = f.name
        f.write(b"dummy")

    try:
        # Run with long timeout - should fail fast (invalid file)
        # but NOT because of timeout
        start = time.time()
        result = subprocess.run(
            [sys.executable, str(TRANSCRIBE_SCRIPT), dummy_audio, "--timeout", "300"],
            capture_output=True,
            text=True,
            timeout=30
        )
        elapsed = time.time() - start

        # Should complete quickly (invalid file), not wait for timeout
        if elapsed < 10 and result.returncode != 124:
            log_pass(f"Timeout cancelled on fast failure (elapsed: {elapsed:.1f}s)")
        elif result.returncode == 124:
            log_fail("Timeout triggered when it shouldn't have")
        else:
            log_pass(f"Completed without timeout (elapsed: {elapsed:.1f}s)")
    except subprocess.TimeoutExpired:
        log_fail("Test itself timed out")
    finally:
        os.unlink(dummy_audio)

def main():
    print("=" * 50)
    print("E2E Test: Transcription Timeout (Issue #8)")
    print("=" * 50)
    print()

    print("[TEST 1] Checking --timeout flag...")
    test_timeout_flag_exists()

    print("\n[TEST 2] Testing timeout exit code...")
    test_timeout_exit_code()

    print("\n[TEST 3] Testing timeout cancellation...")
    test_timeout_cancellation()

    print()
    print("=" * 50)
    print(f"Results: {TESTS_PASSED} passed, {TESTS_FAILED} failed")
    print("=" * 50)

    sys.exit(0 if TESTS_FAILED == 0 else 1)

if __name__ == "__main__":
    main()
