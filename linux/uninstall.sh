#!/bin/sh
# CommitOwl for Linux - removes the daily schedule, the menu entry and the command.
# Your repositories are not touched. Settings stay in ~/.config/commitowl (delete it to remove them too).
# Developed by: EMR Industries - Version 1.3 - Built 2026.11.06
DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$DIR/commitowl.py" schedule off 2>/dev/null || true
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/commitowl.desktop" "$HOME/.local/bin/commitowl"
echo "CommitOwl is uninstalled. You can now delete $DIR"
echo "Settings and log: ~/.config/commitowl and ~/.local/state/commitowl"
