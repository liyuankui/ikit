#!/usr/bin/env python3
"""
Fetch notes from Apple Notes using AppleScript.

Usage:
    # List notes in a folder
    python3 scripts/fetch_apple_notes.py --folder "散文/修改中" --list

    # Get a specific note's content
    python3 scripts/fetch_apple_notes.py --note "笔记标题" --output /tmp/note.md
"""

import subprocess
import json
import argparse
import sys
from pathlib import Path


def run_applescript(script):
    """Run AppleScript and return output."""
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True,
            text=True,
            timeout=30
        )
        if result.returncode != 0:
            print(f"AppleScript error: {result.stderr}", file=sys.stderr)
            return None
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        print("AppleScript timed out", file=sys.stderr)
        return None
    except Exception as e:
        print(f"Error running AppleScript: {e}", file=sys.stderr)
        return None


def list_notes_in_folder(folder_path):
    """List all notes in a specific folder."""
    # Split folder path (e.g., "散文/修改中" -> ["散文", "修改中"])
    parts = folder_path.split('/')

    # Build AppleScript to traverse folder hierarchy
    script_parts = []

    if len(parts) == 1:
        script = f'''
        tell application "Notes"
            set folderName to "{parts[0]}"
            set output to ""
            if exists folder folderName then
                set targetFolder to folder folderName
                set noteList to every note in targetFolder
                repeat with n in noteList
                    set output to output & (name of n) & "\\n"
                end repeat
            else
                error "Folder '" & folderName & "' not found"
            end if
        end tell
        return output
        '''
    else:
        # For nested folders, traverse the hierarchy
        script = f'''
        tell application "Notes"
            set folderName to "{parts[0]}"
            set output to ""
            if exists folder folderName then
                set targetFolder to folder folderName
        '''

        # Add nested folder traversal
        for i, part in enumerate(parts[1:], 1):
            script += f'''
                try
                    set targetFolder to folder "{part}" in targetFolder
                on error
                    error "Folder '{part}' not found in folder hierarchy"
                end try
            '''

        # Get notes from final folder
        script += '''
                set noteList to every note in targetFolder
                repeat with n in noteList
                    set output to output & (name of n) & "\\n"
                end repeat
            else
                error "Folder not found"
            end if
        end tell
        return output
        '''

    result = run_applescript(script)
    if result:
        notes = [n.strip() for n in result.split('\n') if n.strip()]
        return notes
    return []


def get_note_content(note_name, folder_path=None):
    """Get the content of a specific note."""
    script = f'''
    tell application "Notes"
        set noteName to "{note_name}"
    '''

    if folder_path:
        parts = folder_path.split('/')
        script += f'''
        set targetFolder to folder "{parts[0]}"
        '''
        for part in parts[1:]:
            script += f'''
            set targetFolder to folder "{part}" in targetFolder
            '''
        script += f'''
        set targetNote to note noteName in targetFolder
        '''
    else:
        script += f'''
        set targetNote to note noteName
        '''

    script += '''
        set noteBody to body of targetNote
        return noteBody
    end tell
    '''

    return run_applescript(script)


def main():
    parser = argparse.ArgumentParser(description='Fetch notes from Apple Notes')
    parser.add_argument('--folder', help='Folder path (e.g., "散文/修改中")')
    parser.add_argument('--list', action='store_true', help='List notes in folder')
    parser.add_argument('--note', help='Note name to fetch')
    parser.add_argument('--output', help='Output file path')
    parser.add_argument('--exclude', help='Exclude notes containing this string')

    args = parser.parse_args()

    if args.list:
        if not args.folder:
            print("Error: --folder required when using --list", file=sys.stderr)
            sys.exit(1)

        notes = list_notes_in_folder(args.folder)
        if args.exclude:
            notes = [n for n in notes if args.exclude not in n]

        for note in notes:
            print(note)
        print(f"\nTotal: {len(notes)} notes", file=sys.stderr)

    elif args.note:
        content = get_note_content(args.note, args.folder)
        if content:
            if args.output:
                Path(args.output).write_text(content, encoding='utf-8')
                print(f"Saved to {args.output}")
            else:
                print(content)
        else:
            print(f"Error: Could not fetch note '{args.note}'", file=sys.stderr)
            sys.exit(1)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
