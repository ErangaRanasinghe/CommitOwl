# Installing CommitOwl on Windows

CommitOwl 1.3 · EMR Industries

Follow the steps in order. It takes about five minutes.

## 1. Install Git for Windows

Skip this step if Git is already installed. To check, open **PowerShell** and run `git --version`. If it prints a version number, Git is installed.

1. Download Git for Windows from https://git-scm.com/download/win
2. Run the installer and keep the default options.

## 2. Tell Git your name and email

Skip this step if you've already set them. Open **PowerShell** and run each line:

```powershell
git config --global user.name "Your Name"
```
```powershell
git config --global user.email "you@example.com"
```

## 3. Make sure each repository can push without asking

CommitOwl never stops to ask for a password, so each repository must push on its own:

- **HTTPS remote** (`https://github.com/...`): push once by hand in that repository (`git push`). Git for Windows saves your login in Windows Credential Manager.
- **SSH remote** (`git@github.com:...`): use an SSH key without a passphrase.

## 4. Extract CommitOwl

1. Download `CommitOwl-v1.3-windows.zip` from the **Releases** page on GitHub.
2. Right-click it and choose **Extract All...**
3. Extract it to a folder only you can edit, for example:
   `C:\Users\<you>\AppData\Local\CommitOwl`

   (Type `%LOCALAPPDATA%` in the Explorer address bar to get to `AppData\Local`.)

You should now have a `CommitOwl` folder containing `Start CommitOwl.bat`.

## 5. Open CommitOwl

1. Double-click **`Start CommitOwl.bat`**.
2. The first time, Windows may show *Unknown Publisher* or *Windows protected your PC*. Click **Run**, or **More info > Run anyway**. CommitOwl then unblocks its own files, so this only happens once.
3. The CommitOwl window opens after a few seconds.

## 6. Add your repositories

1. On the **Repositories** tab, click **Add repository...** and pick your project folder.
   - If the folder isn't a Git repository yet, CommitOwl offers to make it one and asks for the remote URL.
   - If it has no `.gitignore`, CommitOwl offers to add one for electronics projects.
2. Repeat for each project.
3. Select a repository and click **Commit & Push** once. The **Result** column should say it pushed. If not, see *Troubleshooting* in `README.md`.

## 7. Turn on the daily commit and push

1. Open the **Schedule & log** tab.
2. Tick **Commit and push every day at** and pick a time, for example 21:00.
3. Click **Save schedule**.

CommitOwl now commits and pushes every day at that time. If the PC is off or asleep then, it runs as soon as you're back.

## 8. Optional: your own commit message

On the **Commit message** tab, type a message and click **Save message**. It goes below the fixed `Auto-commit YYYY-MM-DD HH:mm (N files)` header line.

## 9. Optional: desktop shortcut with the owl icon

1. Open the CommitOwl folder in Explorer.
2. Click the address bar, type `powershell` and press Enter. PowerShell opens in that folder.
3. Paste these lines and press Enter:

```powershell
$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:USERPROFILE\Desktop\CommitOwl.lnk")
$s.TargetPath       = "$PWD\Start CommitOwl.bat"
$s.WorkingDirectory = "$PWD"
$s.IconLocation     = "$PWD\assets\commitowl.ico"
$s.WindowStyle      = 7
$s.Save()
```

A **CommitOwl** shortcut with the owl icon appears on your desktop. Right-click it to pin it to Start, or drag it onto the taskbar.

## Updating

Close CommitOwl, extract the new zip over the CommitOwl folder, and start it again. Your repositories and settings are kept in `%APPDATA%\CommitOwl`.

## Uninstalling

1. On the **Schedule & log** tab, untick the daily box and click **Save schedule**.
2. Delete the CommitOwl folder and `%APPDATA%\CommitOwl`.

See `README.md` for how CommitOwl works, every button and setting, and troubleshooting.

## Running from the source code

If you cloned the repository instead of downloading a release, double-click `windows\Start CommitOwl.bat`. It finds the icon and the `.gitignore` template in the repository root.
