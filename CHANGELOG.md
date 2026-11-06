# Changelog

All notable changes to CommitOwl are listed here, for both the Windows and the Linux version.

## [1.3] - 2026-11-06

### Both
- **Commit message** tab: write your own message under the fixed `Auto-commit YYYY-MM-DD HH:mm (N files)` header, choose whether to list the changed files, and see a live preview.
- **Commit** column on the Repositories tab with the short hash of the latest commit (double-click to copy).
- Conflict alert: when the remote has changes to the same files, CommitOwl stops, keeps your commit locally and shows *auto commit stopped - conflict* (notification, and a message after Commit & Push).
- One repository for both versions, with shared icon, `.gitignore` template, README and changelog. `tools/build-release.py` builds both downloads.

### Linux
- First Linux release, with the same features as the Windows version: Python 3 + Tk window, systemd user timer (cron fallback), desktop notifications, applications-menu entry and a `commitowl` command line.

### Windows
- No PowerShell console window when opening CommitOwl or running Commit & Push (also on Windows 11 with Windows Terminal).
- Auto push drop-down text is black instead of faded.

The versions below were Windows only.

## [1.2] - 2026-11-06

- **Auto push** drop-down on every repository: Active, Pause 1 day, Pause 3 days, Pause 1 week, Pause until I resume. Paused repositories are skipped by the daily run and resume on their own.
- Git wording instead of "snapshot": **Commit & Push**, **Commit & Push all**, **Add repository...**, **Commit and push every day at**, *Last push* column.
- Commit message is now `Auto-commit YYYY-MM-DD HH:mm (N files)`.
- Released under the MIT License (`LICENSE`), with a note that CommitOwl is not affiliated with the Git project.
- Removed all references to third-party Git clients; messages now give plain `git` commands.
- The Task Scheduler entry is now `\CommitOwl\Daily commit and push`. The old `Daily snapshot` task is moved over automatically, keeping its time.

## [1.1] - 2026-11-06

- The window shows an error message (and logs it) if it cannot start, instead of failing silently.
- README explains how to open CommitOwl and make a desktop shortcut with the owl icon.
- Save schedule and Add folder... buttons use the normal font.
- Icon files moved into an `assets` folder.
- Fixed: the buttons on the Repositories and Schedule & log tabs were pushed off the bottom of the window. The window now lays itself out and scales with Windows display scaling.

## [1.0] - 2026-11-05

First release.

- Daily snapshot of every ticked repository: commit all changes, rebase on the remote, push. Never force-pushes.
- Runs from Windows Task Scheduler (`\CommitOwl\Daily snapshot`), catching up if the PC was off.
- Guards: secrets and keys, lock and temp files, and files over the size limit are never committed automatically.
- Commits locally when offline and pushes on the next run.
- Window with Repositories, Schedule & log and About tabs; turns plain folders into Git repositories.
- Electronics `.gitignore` template (KiCad, Altium, Eagle, PlatformIO, STM32CubeIDE, ESP-IDF).
- Windows notifications when something needs attention.
