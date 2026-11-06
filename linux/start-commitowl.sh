#!/bin/sh
# CommitOwl for Linux - opens the CommitOwl window.
# Developed by: EMR Industries - Version 1.3 - Built 2026.11.06
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# The window needs Tk; the command line (run, status, schedule) does not
if { [ $# -eq 0 ] || [ "$1" = gui ]; } && ! python3 -c 'import tkinter' 2>/dev/null; then
    MSG="CommitOwl needs Tk for Python. Install it with:  sudo apt install python3-tk  (Fedora: sudo dnf install python3-tkinter, Arch: sudo pacman -S tk)"
    echo "$MSG" >&2
    command -v notify-send >/dev/null && notify-send -a CommitOwl "CommitOwl" "$MSG"
    exit 1
fi
exec python3 "$DIR/commitowl.py" "$@"
