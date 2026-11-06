#!/usr/bin/env python3
# =====================================================================
#  CommitOwl for Linux - daily auto commit and push for electronics projects
#  Core: settings, Git helpers, the commit-and-push worker, the daily
#  timer and the command line.
#
#    commitowl.py                      open the window
#    commitowl.py run                  commit and push all active repositories
#    commitowl.py run --repo DIR       commit and push one repository
#    commitowl.py schedule HH:MM       daily commit and push at HH:MM
#    commitowl.py schedule off         turn the daily run off
#    commitowl.py status               show repositories and the schedule
#
#  Developed by: EMR Industries
#  Version 1.3 - Built 2026.11.06
#  MIT License - see LICENSE
# =====================================================================

import argparse
import datetime as dt
import fcntl
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile

APP_NAME = 'CommitOwl'
APP_VERSION = '1.3'
APP_BUILD_DATE = '2026.11.06'
APP_VENDOR = 'EMR Industries'

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser('~')
CONFIG_DIR = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.join(HOME, '.config'), 'commitowl')
STATE_DIR = os.path.join(os.environ.get('XDG_STATE_HOME') or os.path.join(HOME, '.local', 'state'), 'commitowl')
CONFIG_FILE = os.path.join(CONFIG_DIR, 'config.json')
STATE_FILE = os.path.join(STATE_DIR, 'state.json')
LOG_FILE = os.path.join(STATE_DIR, 'commitowl.log')
LOCK_FILE = os.path.join(STATE_DIR, 'run.lock')
LOG_MAX_BYTES = 2 * 1024 * 1024

SYSTEMD_DIR = os.path.join(os.environ.get('XDG_CONFIG_HOME') or os.path.join(HOME, '.config'), 'systemd', 'user')
UNIT = 'commitowl'
CRON_TAG = '# CommitOwl daily commit and push'



def _find(relative):
    """Shared files sit next to the scripts in a release download, and one folder up in the source repository."""
    for base in (HERE, os.path.dirname(HERE)):
        p = os.path.join(base, relative)
        if os.path.exists(p):
            return p
    return os.path.join(HERE, relative)


ICON_PNG = _find(os.path.join('assets', 'commitowl.png'))
IGNORE_TEMPLATE = _find('electronics.gitignore')

# Files never committed automatically: secrets and keys
SECRET_PATTERNS = [
    '.env', '.env.*', '*.pem', '*.key', '*.p12', '*.pfx', '*.ppk', '*.keystore', '*.jks',
    'id_rsa', 'id_rsa*', 'id_dsa*', 'id_ecdsa*', 'id_ed25519*',
    'credentials', 'credentials.*', '*.secret', 'secrets.*', 'secrets_*.h', 'wifi_secrets.h',
]
# Files never committed automatically: lock files and editor scratch files
JUNK_PATTERNS = [
    '*.lck', '~*.lck', '~$*', '*.tmp', '*.swp', '_autosave-*', '#auto_saved_files#',
    'fp-info-cache', 'Thumbs.db', 'desktop.ini', '.DS_Store',
]

PAUSE_CHOICES = ['Active', 'Pause 1 day', 'Pause 3 days', 'Pause 1 week', 'Pause until I resume']
FOREVER = dt.datetime.max


# ---------------------------------------------------------------------
# Settings and state
# ---------------------------------------------------------------------
def default_config():
    return {
        'repos': [],
        'notify': 'problems',      # always | problems | never
        'maxFileMB': 50,           # files bigger than this are not committed
        'commitMessage': '',       # your text under the fixed "Auto-commit ..." header
        'listFiles': True,         # add the list of changed files at the end
    }


def load_config():
    cfg = default_config()
    try:
        with open(CONFIG_FILE, encoding='utf-8') as f:
            data = json.load(f)
        for k in cfg:
            if k in data and data[k] is not None:
                cfg[k] = data[k]
    except FileNotFoundError:
        pass
    except Exception as e:
        log(f'[WARN] Settings file could not be read, starting with defaults: {e}')
    repos = []
    for r in cfg.get('repos') or []:
        if not r or not r.get('path'):
            continue
        repos.append({
            'path': str(r['path']),
            'remote': r.get('remote') or 'origin',
            'branch': r.get('branch') or '',
            'enabled': True if r.get('enabled') is None else bool(r.get('enabled')),
            'pausedUntil': r.get('pausedUntil') or '',
        })
    cfg['repos'] = repos
    return cfg


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


def save_config(cfg):
    _write_json(CONFIG_FILE, {
        'repos': cfg['repos'],
        'notify': cfg['notify'],
        'maxFileMB': int(cfg['maxFileMB']),
        'commitMessage': cfg.get('commitMessage') or '',
        'listFiles': bool(cfg.get('listFiles', True)),
    })


def load_state():
    try:
        with open(STATE_FILE, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def set_state(repo_path, result, detail, commit_hash=''):
    st = load_state()
    st[repo_path] = {
        'time': dt.datetime.now().strftime('%Y-%m-%d %H:%M'),
        'hash': commit_hash,
        'result': result,
        'detail': detail,
    }
    _write_json(STATE_FILE, st)


# ---------------------------------------------------------------------
# Pause and commit message
# ---------------------------------------------------------------------
def get_pause(repo):
    """None = active, FOREVER = paused until resumed, a datetime = paused until that day."""
    if not repo.get('enabled', True):
        return FOREVER
    until = repo.get('pausedUntil')
    if until:
        try:
            d = dt.datetime.strptime(until, '%Y-%m-%d')
            if dt.datetime.now() < d:
                return d
        except ValueError:
            pass
    return None


def format_pause(until):
    if until == FOREVER:
        return 'Paused until I resume'
    return 'Paused until ' + until.strftime('%a %-d %b')


def set_pause(repo, choice):
    """Applies a choice from the Auto push drop-down. Returns True if something changed."""
    today = dt.date.today()
    days = {'Pause 1 day': 1, 'Pause 3 days': 3, 'Pause 1 week': 7}
    if choice == 'Active':
        repo['enabled'], repo['pausedUntil'] = True, ''
    elif choice in days:
        repo['enabled'] = True
        repo['pausedUntil'] = (today + dt.timedelta(days=days[choice])).isoformat()
    elif choice == 'Pause until I resume':
        repo['enabled'], repo['pausedUntil'] = False, ''
    else:
        return False
    name = os.path.basename(repo['path'])
    until = get_pause(repo)
    log(f'[{name}] [PAUSED] {format_pause(until)}.' if until else f'[{name}] Auto push resumed.')
    return True


def build_commit_message(stamp, changes, cfg, manual=False):
    n = len(changes)
    files = '1 file' if n == 1 else f'{n} files'
    msg = f'Auto-commit {stamp} ({files})'
    body = (cfg.get('commitMessage') or '').strip()
    if not body:
        body = ('Committed with the Commit & Push button in CommitOwl.' if manual
                else 'Daily automatic commit by CommitOwl.')
    msg += '\n\n' + body.replace('\r\n', '\n')
    if cfg.get('listFiles', True) and n:
        msg += '\n\n' + '\n'.join(changes[:60])
        if n > 60:
            msg += f'\n... and {n - 60} more'
    return msg


# ---------------------------------------------------------------------
# Log
# ---------------------------------------------------------------------
def log(message, echo=True):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_BYTES:
            os.replace(LOG_FILE, LOG_FILE + '.old')
        with open(LOG_FILE, 'a', encoding='utf-8') as f:
            f.write(f"{dt.datetime.now():%Y-%m-%d %H:%M:%S}  {message}\n")
    except Exception:
        pass
    if echo:
        print(message, flush=True)


# ---------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------
GIT = shutil.which('git')


def git(repo, *args):
    """Runs git and never stops to ask for a password. Returns (exit code, output text)."""
    env = dict(os.environ)
    env.update({
        'GIT_TERMINAL_PROMPT': '0',
        'GCM_INTERACTIVE': 'never',
        'GIT_ASKPASS': 'true',
        'SSH_ASKPASS': '',
        'LC_ALL': 'C',
    })
    env.setdefault('GIT_SSH_COMMAND', 'ssh -o BatchMode=yes')
    try:
        p = subprocess.run([GIT, '-C', repo, '-c', 'core.quotepath=off', '-c', 'color.ui=false', *args],
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           env=env, text=True, encoding='utf-8', errors='replace', timeout=600)
        return p.returncode, p.stdout.strip()
    except subprocess.TimeoutExpired:
        return 124, 'git timed out'
    except Exception as e:
        return 1, str(e)


def lines(text):
    return [l for l in text.splitlines() if l.strip()]


def matches(path, patterns):
    name = os.path.basename(path)
    return any(fnmatch.fnmatchcase(name, p) for p in patterns)


def current_branch(path):
    code, out = git(path, 'symbolic-ref', '--quiet', '--short', 'HEAD')
    return out if code == 0 else ''


def head_hash(path):
    code, out = git(path, 'rev-parse', '--short', 'HEAD')
    return out if code == 0 else ''


# ---------------------------------------------------------------------
# Worker: commit and push one repository
# ---------------------------------------------------------------------
def commit_push(repo, cfg, manual=False):
    path, remote = repo['path'], repo.get('remote') or 'origin'
    tag = f'[{os.path.basename(path.rstrip("/"))}]'

    def say(m):
        log(f'{tag} {m}')

    if not os.path.isdir(path):
        say('[ERROR] Folder not found. Is the drive mounted?')
        return 'error', 'Folder not found'
    if git(path, 'rev-parse', '--show-toplevel')[0] != 0:
        say('[ERROR] Not a Git repository.')
        return 'error', 'Not a Git repository'

    git_dir = git(path, 'rev-parse', '--absolute-git-dir')[1]
    for busy in ('MERGE_HEAD', 'rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG'):
        if os.path.exists(os.path.join(git_dir, busy)):
            say(f'[SKIP] A merge, rebase or similar is in progress ({busy}). Finish it in your Git client first.')
            return 'skipped', 'Merge or rebase in progress'
    if os.path.exists(os.path.join(git_dir, 'index.lock')):
        say('[SKIP] Git is busy (index.lock exists). If no Git program is running, delete .git/index.lock.')
        return 'skipped', 'Git is busy (index.lock)'

    cur = current_branch(path)
    if not cur:
        say('[SKIP] Detached HEAD (no branch checked out).')
        return 'skipped', 'No branch checked out'
    branch = repo.get('branch') or cur
    if branch != cur:
        say(f"[SKIP] Branch '{cur}' is checked out, but this repository is set to '{branch}'. CommitOwl never switches branches.")
        return 'skipped', f"On '{cur}', set to '{branch}'"

    # ---------------- 1. Commit ----------------
    committed = 0
    notes = []
    code, out = git(path, 'add', '-A')
    if code != 0:
        say('[ERROR] git add failed: ' + out)
        return 'error', 'git add failed'

    staged = lines(git(path, 'diff', '--cached', '--name-only', '--diff-filter=ACMR')[1])
    limit = int(cfg.get('maxFileMB') or 50) * 1024 * 1024
    for f in staged:
        why = None
        if matches(f, SECRET_PATTERNS):
            why = 'looks like a secret or key'
        elif matches(f, JUNK_PATTERNS):
            why = 'lock or temporary file'
        else:
            full = os.path.join(path, f)
            if (os.path.isfile(full) and os.path.getsize(full) > limit
                    and not git(path, 'check-attr', 'filter', '--', f)[1].endswith('filter: lfs')):
                why = f"over {cfg.get('maxFileMB')} MB, use Git LFS"
        if why:
            git(path, 'reset', '-q', '--', f)
            notes.append(f'{f} ({why})')
    if notes:
        say(f'[GUARD] Left out {len(notes)} file(s): ' + ', '.join(notes) + '. Add them to .gitignore to silence this.')
        notes = [f'left out {len(notes)} file(s)']

    changes = lines(git(path, 'diff', '--cached', '--name-status')[1])
    if changes:
        stamp = dt.datetime.now().strftime('%Y-%m-%d %H:%M')
        msg = build_commit_message(stamp, changes, cfg, manual)
        with tempfile.NamedTemporaryFile('w', delete=False, encoding='utf-8', suffix='.txt', prefix='commitowl-msg-') as tf:
            tf.write(msg + '\n')
            msg_file = tf.name
        code, out = git(path, 'commit', '-q', '-F', msg_file)
        os.unlink(msg_file)
        if code != 0:
            if 'user.name' in out or 'user.email' in out or 'Please tell me who you are' in out:
                say('[ERROR] Git does not know your name and email. Run once:  git config --global user.name "Your Name"  and  git config --global user.email "you@example.com"')
            else:
                say('[ERROR] Commit failed: ' + out)
            return 'error', 'Commit failed'
        committed = len(changes)
        say(f"Committed {'1 file' if committed == 1 else f'{committed} files'}.")
    else:
        say('No changes to commit.')

    # ---------------- 2. Push ----------------
    if remote not in lines(git(path, 'remote')[1]):
        say(f"[WARN] No remote named '{remote}'. The commit is saved locally only. Add a remote to back it up.")
        return ('local' if committed else 'ok'), f"No remote '{remote}'"

    code, out = git(path, 'fetch', '--quiet', remote, branch)
    remote_ref = f'refs/remotes/{remote}/{branch}'
    if code != 0:
        if "couldn't find remote ref" in out or 'could not find remote ref' in out:
            remote_has = False      # branch does not exist on the remote yet
        else:
            say('[WARN] Could not reach the remote, will try again next run: ' + (out.splitlines() or [''])[0])
            return 'local', 'Offline - committed locally'
    else:
        remote_has = git(path, 'rev-parse', '--verify', '--quiet', remote_ref)[0] == 0

    if remote_has:
        behind = int(git(path, 'rev-list', '--count', f'HEAD..{remote_ref}')[1] or 0)
        if behind:
            say(f'Remote has {behind} new commit(s). Rebasing on top of them...')
            if git(path, 'rebase', '--autostash', remote_ref)[0] != 0:
                git(path, 'rebase', '--abort')
                say('[ERROR] Your changes conflict with the remote. Nothing was pushed and your commit is safe. Pull and resolve it in your Git client (git pull).')
                return 'conflict', 'Conflict with remote - push stopped'
        ahead = int(git(path, 'rev-list', '--count', f'{remote_ref}..HEAD')[1] or 0)
        if not ahead:
            say('Remote is already up to date.')
            return 'ok', '; '.join(notes) if notes else 'Up to date'

    push = ['push', '--porcelain']
    if git(path, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')[0] != 0 or not remote_has:
        push.append('-u')
    push += [remote, f'HEAD:refs/heads/{branch}']
    code, out = git(path, *push)
    if code != 0:
        if any(k in out for k in ('Authentication failed', 'could not read Username', 'terminal prompts disabled',
                                  'Permission denied', '403')):
            say('[ERROR] Push needs a login. Push once by hand (git push) so your login is saved, then CommitOwl can push on its own.')
        elif 'rejected' in out:
            say('[ERROR] Remote rejected the push (it changed again). Will retry next run.')
        else:
            say('[ERROR] Push failed: ' + out)
        return 'local', 'Push failed - committed locally'
    say(f'Pushed to {remote}/{branch}.')
    detail = f'{committed} file(s) committed and pushed' if committed else 'Pushed earlier commits'
    if notes:
        detail += '; ' + '; '.join(notes)
    return 'ok', detail


def notify(title, text, problem=False):
    exe = shutil.which('notify-send')
    if not exe:
        return
    args = [exe, '--app-name=CommitOwl', '--urgency=' + ('critical' if problem else 'normal')]
    if os.path.exists(ICON_PNG):
        args.append('--icon=' + ICON_PNG)
    try:
        subprocess.run(args + [title, text], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def run(repo_path=None, manual=False):
    """Commits and pushes. Exit code: 0 ok, 1 problems, 2 git missing, 3 conflict."""
    if not GIT:
        log('[ERROR] git not found. Install it with your package manager, e.g.  sudo apt install git')
        return 2
    os.makedirs(STATE_DIR, exist_ok=True)
    lock = open(LOCK_FILE, 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log('[SKIP] Another commit and push is already running.')
        return 0

    cfg = load_config()
    if repo_path:
        repo_path = os.path.abspath(os.path.expanduser(repo_path))
        repos = [r for r in cfg['repos'] if os.path.abspath(r['path']) == repo_path] or \
                [{'path': repo_path, 'remote': 'origin', 'branch': '', 'enabled': True, 'pausedUntil': ''}]
    else:
        repos = []
        for r in cfg['repos']:
            until = get_pause(r)
            if until:
                log(f"[{os.path.basename(r['path'].rstrip('/'))}] [PAUSED] {format_pause(until)}. Skipped.")
            else:
                repos.append(r)

    n = len(repos)
    log(f"===== Commit and push started ({'manual' if manual else 'scheduled'}) - {n} repositor{'y' if n == 1 else 'ies'} =====")
    summary, problems, conflicts = [], 0, []
    for r in repos:
        name = os.path.basename(r['path'].rstrip('/'))
        try:
            result, detail = commit_push(r, cfg, manual)
        except Exception as e:
            log(f'[{name}] [ERROR] {e}')
            result, detail = 'error', str(e)
        set_state(r['path'], result, detail, head_hash(r['path']) if os.path.isdir(r['path']) else '')
        if result in ('error', 'local', 'conflict'):
            problems += 1
        if result == 'conflict':
            conflicts.append(name)
        summary.append(f'{name}: {detail}')
    log(f'===== Commit and push finished - {problems} problem(s) =====')

    if cfg['notify'] != 'never' and conflicts:
        notify('CommitOwl: auto commit stopped - conflict',
               ', '.join(conflicts) + ': the remote has changes that conflict with yours. Nothing was pushed; '
               'your work is committed locally. Pull and resolve it, and the next run pushes it.', True)
    elif n and not manual and (cfg['notify'] == 'always' or (cfg['notify'] == 'problems' and problems)):
        title = ('CommitOwl: 1 repository needs attention' if problems == 1 else
                 f'CommitOwl: {problems} repositories need attention' if problems else 'CommitOwl: commit and push done')
        notify(title, '\n'.join(summary[:4]), bool(problems))
    return 3 if conflicts else (1 if problems else 0)


# ---------------------------------------------------------------------
# Daily schedule: systemd user timer (falls back to cron)
# ---------------------------------------------------------------------
def _systemctl(*args):
    try:
        p = subprocess.run(['systemctl', '--user', *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=30)
        return p.returncode, p.stdout.strip()
    except Exception as e:
        return 1, str(e)


def systemd_available():
    return bool(shutil.which('systemctl')) and _systemctl('show-environment')[0] == 0


def _cron_lines():
    try:
        p = subprocess.run(['crontab', '-l'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        return p.stdout.splitlines() if p.returncode == 0 else []
    except Exception:
        return []


def _cron_write(lines_):
    subprocess.run(['crontab', '-'], input='\n'.join(lines_) + '\n', text=True, check=True)


def set_schedule(hhmm):
    """hhmm = 'HH:MM' to turn on, None to turn off. Returns a message."""
    me = os.path.abspath(__file__)
    service = os.path.join(SYSTEMD_DIR, UNIT + '.service')
    timer = os.path.join(SYSTEMD_DIR, UNIT + '.timer')
    if systemd_available():
        if hhmm is None:
            _systemctl('disable', '--now', UNIT + '.timer')
            for f in (service, timer):
                if os.path.exists(f):
                    os.remove(f)
            _systemctl('daemon-reload')
            return 'Daily commit and push is off.'
        os.makedirs(SYSTEMD_DIR, exist_ok=True)
        with open(service, 'w') as f:
            f.write(f"""[Unit]
Description=CommitOwl daily commit and push (EMR Industries)

[Service]
Type=oneshot
ExecStart={sys.executable} "{me}" run
""")
        with open(timer, 'w') as f:
            f.write(f"""[Unit]
Description=CommitOwl daily commit and push at {hhmm}

[Timer]
OnCalendar=*-*-* {hhmm}:00
Persistent=true

[Install]
WantedBy=timers.target
""")
        _systemctl('daemon-reload')
        code, out = _systemctl('enable', '--now', UNIT + '.timer')
        if code != 0:
            raise RuntimeError(out)
        return f'Saved. CommitOwl will commit and push every day at {hhmm}.'

    # cron fallback
    if not shutil.which('crontab'):
        raise RuntimeError('Neither a systemd user session nor crontab is available.')
    kept = [l for l in _cron_lines() if CRON_TAG not in l]
    if hhmm is None:
        _cron_write(kept)
        return 'Daily commit and push is off.'
    h, m = hhmm.split(':')
    kept.append(f'{int(m)} {int(h)} * * * {sys.executable} "{me}" run >/dev/null 2>&1 {CRON_TAG}')
    _cron_write(kept)
    return f'Saved (cron). CommitOwl will commit and push every day at {hhmm}. Cron does not catch up if the PC was off.'


def get_schedule():
    """Returns dict: enabled, time 'HH:MM' or '', next run text, backend."""
    timer = os.path.join(SYSTEMD_DIR, UNIT + '.timer')
    if os.path.exists(timer):
        t = ''
        with open(timer) as f:
            for l in f:
                if l.startswith('OnCalendar='):
                    t = l.strip().split()[-1][:5]
        enabled = _systemctl('is-enabled', UNIT + '.timer')[1] == 'enabled'
        nxt = _systemctl('show', UNIT + '.timer', '--property=NextElapseUSecRealtime', '--value')[1]
        last = _systemctl('show', UNIT + '.service', '--property=ExecMainExitTimestamp', '--value')[1]
        result = _systemctl('show', UNIT + '.service', '--property=ExecMainStatus', '--value')[1]
        return {'enabled': enabled, 'time': t, 'next': nxt or '-', 'last': last or '-',
                'result': result, 'backend': 'systemd'}
    for l in _cron_lines():
        if CRON_TAG in l:
            m, h = l.split()[:2]
            return {'enabled': True, 'time': f'{int(h):02d}:{int(m):02d}', 'next': '-', 'last': '-',
                    'result': '', 'backend': 'cron'}
    return {'enabled': False, 'time': '', 'next': '-', 'last': '-', 'result': '', 'backend': ''}


# ---------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(prog='commitowl', description='CommitOwl - daily auto commit and push for electronics projects')
    sub = ap.add_subparsers(dest='cmd')
    pr = sub.add_parser('run', help='commit and push now')
    pr.add_argument('--repo', help='only this repository')
    pr.add_argument('--manual', action='store_true', help=argparse.SUPPRESS)
    ps = sub.add_parser('schedule', help='set the daily time (HH:MM) or "off"')
    ps.add_argument('when')
    sub.add_parser('status', help='show repositories and the schedule')
    sub.add_parser('gui', help='open the window (default)')
    a = ap.parse_args(argv)

    if a.cmd == 'run':
        return run(a.repo, a.manual or bool(a.repo))
    if a.cmd == 'schedule':
        try:
            when = None if a.when.lower() == 'off' else dt.datetime.strptime(a.when, '%H:%M').strftime('%H:%M')
            print(set_schedule(when))
            return 0
        except Exception as e:
            print(f'Could not set the schedule: {e}', file=sys.stderr)
            return 1
    if a.cmd == 'status':
        cfg, st, sch = load_config(), load_state(), get_schedule()
        print(f"Schedule: {'every day at ' + sch['time'] if sch['enabled'] else 'off'}"
              + (f"  (next: {sch['next']})" if sch['enabled'] else ''))
        for r in cfg['repos']:
            u = get_pause(r)
            s = st.get(r['path'], {})
            print(f"  {r['path']}\n    {format_pause(u) if u else 'Active'} | last push {s.get('time', '-')} "
                  f"| {s.get('hash') or '-'} | {s.get('detail', 'Not pushed yet')}")
        return 0
    # default: window
    sys.path.insert(0, HERE)
    import commitowl_gui
    return commitowl_gui.main()


if __name__ == '__main__':
    sys.exit(main())
