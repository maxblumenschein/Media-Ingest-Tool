#!/bin/bash
# Double-click this file to run the Media Ingest Tool on macOS.
#
# What this does, plainly: it just finds a working Python 3 and runs
# ingest_tool.py, which starts its own interactive wizard when given no
# extra options (three plain questions, always a safe preview first).
# This script exists only to make that a double-click instead of a
# command line - it doesn't add any behavior of its own.
#
# If your Mac ever refuses to run this because it's from an
# unidentified developer: right-click (or Control-click) this file,
# choose "Open", then confirm in the dialog that appears. You only need
# to do that once.

set -u

# cd to this script's own folder, so it finds ingest_tool.py right next
# to it regardless of where it was double-clicked from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "Could not find the folder this script is in."
    read -r -p "Press Enter to close this window..."
    exit 1
}

echo "===================================================================="
echo " Media Ingest Tool"
echo "===================================================================="
echo

if [ ! -f "ingest_tool.py" ]; then
    echo "ERROR: Could not find ingest_tool.py in this folder:"
    echo "  $(pwd)"
    echo
    echo "Make sure \"ingest_tool.py\" is saved in the SAME folder as this"
    echo "file, then try again."
    echo
    read -r -p "Press Enter to close this window..."
    exit 1
fi

# Prefer python3 (the standard command on macOS and most Linux
# distributions); fall back to a plain "python" only if that's a real
# Python 3, since on some older systems "python" means Python 2.
PYTHON=""
if command -v python3 >/dev/null 2>&1; then
    PYTHON="python3"
elif command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)' >/dev/null 2>&1; then
    PYTHON="python"
fi

if [ -z "$PYTHON" ]; then
    echo "ERROR: Python 3 was not found on this Mac."
    echo
    echo "Recent macOS versions don't include Python by default. The"
    echo "easiest fix is usually one of:"
    echo "  - Install Python 3 from https://www.python.org/downloads/macos/"
    echo "  - Or, if you have Homebrew installed, run: brew install python"
    echo
    read -r -p "Press Enter to close this window..."
    exit 1
fi

echo "Starting..."
echo

"$PYTHON" ingest_tool.py
EXITCODE=$?

echo
if [ "$EXITCODE" -ne 0 ]; then
    echo "===================================================================="
    echo "The tool exited with an error (code $EXITCODE)."
    echo "If you saw a message above explaining what went wrong, that's the"
    echo "cause - copy it and share it so it can be fixed."
    echo "===================================================================="
    echo
fi

read -r -p "Press Enter to close this window..." || true
exit "$EXITCODE"
