#!/bin/sh
# CommitOwl for Linux - adds CommitOwl to your applications menu and the
# 'commitowl' command to ~/.local/bin. Nothing needs root.
# Developed by: EMR Industries - Version 1.3 - Built 2026.11.06
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
chmod +x "$DIR/start-commitowl.sh" "$DIR/commitowl.py" "$DIR/uninstall.sh"

ICON="$DIR/assets/commitowl.png"
[ -f "$ICON" ] || ICON="$(dirname "$DIR")/assets/commitowl.png"   # running from the source repository

APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APPS" "$HOME/.local/bin"
cat > "$APPS/commitowl.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=CommitOwl
Comment=Daily auto commit and push for electronics projects
Exec="$DIR/start-commitowl.sh"
Icon=$ICON
Terminal=false
Categories=Development;RevisionControl;
StartupWMClass=commitowl
DESKTOP
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" >/dev/null 2>&1 || true
ln -sf "$DIR/start-commitowl.sh" "$HOME/.local/bin/commitowl"

echo "CommitOwl is installed."
echo "  - Open it from your applications menu (search for CommitOwl), or run: commitowl"
echo "  - Command line: commitowl run | commitowl status | commitowl schedule 21:00"
python3 -c 'import tkinter' 2>/dev/null || echo "  ! Install Tk for Python first: sudo apt install python3-tk"
command -v git >/dev/null || echo "  ! Install git first: sudo apt install git"
