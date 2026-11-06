# Installing CommitOwl on Linux

CommitOwl 1.3 · EMR Industries

Run each command in a terminal, in order. These steps are for Ubuntu, Debian and Mint, with `CommitOwl-v1.3-linux.tar.gz` from the GitHub **Releases** page in your **Downloads** folder. Fedora and Arch commands are at the end of step 1.

## 1. Install Git, Tk for Python and notifications

```sh
sudo apt update
```
```sh
sudo apt install git python3-tk libnotify-bin
```

- Fedora: `sudo dnf install git python3-tkinter libnotify`
- Arch: `sudo pacman -S git tk libnotify`

## 2. Go to your Downloads folder

```sh
cd ~/Downloads
```

## 3. Create the install folder

```sh
mkdir -p ~/.local/opt
```

## 4. Extract CommitOwl into it

```sh
tar -xzf CommitOwl-v1.3-linux.tar.gz -C ~/.local/opt
```

- `-x` extracts, `-z` means the file is gzip-compressed, `-f` gives the file name.
- `-C ~/.local/opt` extracts into that folder, so you get `~/.local/opt/CommitOwl/`.

## 5. Run the installer

```sh
~/.local/opt/CommitOwl/install.sh
```

It prints *CommitOwl is installed.* It adds CommitOwl to your applications menu, with the owl icon, and the `commitowl` command. No root is needed.

## 6. Tell Git your name and email

Skip this step if you've already set them.

```sh
git config --global user.name "Your Name"
```
```sh
git config --global user.email "you@example.com"
```

## 7. Make sure each repository can push without asking

CommitOwl never stops to ask for a password, so each repository must push on its own:

- **HTTPS remote** (`https://github.com/...`): save your login once, then push by hand:
  ```sh
  git config --global credential.helper store
  ```
  ```sh
  cd ~/path/to/your/repo && git push
  ```
  Enter your username and access token once; Git saves them. (`store` keeps them in a plain file, `~/.git-credentials`. Git Credential Manager is a more secure alternative.)
- **SSH remote** (`git@github.com:...`): use an SSH key without a passphrase for repositories pushed by the daily timer.

## 8. Open CommitOwl

```sh
commitowl
```

Or search for **CommitOwl** in your applications menu. If the `commitowl` command isn't found, log out and back in once, or run:

```sh
~/.local/opt/CommitOwl/start-commitowl.sh
```

## 9. Add your repositories

1. On the **Repositories** tab, click **Add repository...** and pick your project folder.
   - If the folder isn't a Git repository yet, CommitOwl offers to make it one and asks for the remote URL.
   - If it has no `.gitignore`, CommitOwl offers to add one for electronics projects.
2. Repeat for each project.
3. Select a repository and click **Commit & Push** once. The **Result** column should say it pushed. If not, see *Troubleshooting* in `README.md`.

## 10. Turn on the daily commit and push

1. Open the **Schedule & log** tab.
2. Tick **Commit and push every day at** and pick a time, for example 21:00.
3. Click **Save schedule**.

Check that the timer is set:

```sh
systemctl --user list-timers commitowl.timer
```

It shows the next run time. If the PC is off or asleep at that time, the run happens at the next boot.

To run it even when you're not logged in (optional):

```sh
sudo loginctl enable-linger $USER
```

## 11. Optional: your own commit message

On the **Commit message** tab, type a message and click **Save message**. It goes below the fixed `Auto-commit YYYY-MM-DD HH:mm (N files)` header line.

## Updating

```sh
tar -xzf CommitOwl-v1.3-linux.tar.gz -C ~/.local/opt
```

Extracting over the old folder updates it. Your repositories and settings are kept in `~/.config/commitowl`.

## Uninstalling

```sh
~/.local/opt/CommitOwl/uninstall.sh
```
```sh
rm -rf ~/.local/opt/CommitOwl ~/.config/commitowl ~/.local/state/commitowl
```

The first command turns off the daily run and removes the menu entry and the `commitowl` command. The second deletes CommitOwl, its settings and its log. Your repositories are not touched.

See `README.md` for how CommitOwl works, every button and setting, the command line, and troubleshooting.

## Running from the source code

If you cloned the repository instead of downloading a release:

```sh
cd CommitOwl/linux
./install.sh
```

The scripts find the icon and the `.gitignore` template in the repository root.
