#!/usr/bin/env python3
# =====================================================================
#  CommitOwl - builds both release downloads into dist/
#
#    python3 tools/build-release.py
#
#  dist/CommitOwl-v<version>-windows.zip    (CRLF line endings)
#  dist/CommitOwl-v<version>-linux.tar.gz   (LF line endings, executable scripts)
#
#  Each download is a self-contained "CommitOwl" folder with the program,
#  the shared icon and .gitignore template, README, the platform's
#  INSTALL.md, CHANGELOG and LICENSE.
#
#  Developed by: EMR Industries - MIT License
# =====================================================================

import io
import os
import re
import sys
import tarfile
import time
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, 'dist')

SHARED = ['LICENSE', 'CHANGELOG.md', 'electronics.gitignore',
          'assets/commitowl.png', 'assets/commitowl.svg',
          'assets/screenshots/repositories.png', 'assets/screenshots/commit-message.png',
          'assets/screenshots/schedule-and-log.png']
WINDOWS = ['Start CommitOwl.bat', 'CommitOwl.ps1', 'commitowl-run.ps1', 'commitowl-common.ps1',
           'commitowl-hidden.vbs', 'INSTALL.md']
LINUX = ['commitowl.py', 'commitowl_gui.py', 'start-commitowl.sh', 'install.sh', 'uninstall.sh', 'INSTALL.md']
EXECUTABLE = {'commitowl.py', 'start-commitowl.sh', 'install.sh', 'uninstall.sh'}
TEXT = ('.md', '.ps1', '.bat', '.vbs', '.py', '.sh', '.svg', '.gitignore', 'LICENSE')


def version():
    src = open(os.path.join(ROOT, 'linux', 'commitowl.py'), encoding='utf-8').read()
    v = re.search(r"APP_VERSION = '([^']+)'", src).group(1)
    win = open(os.path.join(ROOT, 'windows', 'commitowl-common.ps1'), encoding='utf-8').read()
    wv = re.search(r"\$script:AppVersion\s*=\s*'([^']+)'", win).group(1)
    if v != wv:
        sys.exit(f'Version mismatch: linux/commitowl.py says {v}, windows/commitowl-common.ps1 says {wv}')
    return v


def readme_for(platform):
    """The root README, with links fixed for a download that has only one platform."""
    text = open(os.path.join(ROOT, 'README.md'), encoding='utf-8').read()
    other = 'linux' if platform == 'windows' else 'windows'
    text = text.replace(f'({platform}/INSTALL.md)', '(INSTALL.md)')
    text = text.replace(f'[{other}/INSTALL.md]({other}/INSTALL.md)', f'{other}/INSTALL.md (in the {other.title()} download)')
    text = text.replace('](../../releases/latest)', '](https://github.com/)')  # no repo URL inside a download
    text = text.replace('from [Releases](https://github.com/)', 'from the GitHub Releases page')
    return text


def content(path, crlf):
    data = open(path, 'rb').read()
    if path.endswith(TEXT):
        data = data.replace(b'\r\n', b'\n')
        if crlf:
            data = data.replace(b'\n', b'\r\n')
    return data


def files(platform):
    """Yields (path inside the download, bytes, executable)."""
    crlf = platform == 'windows'
    shared = SHARED + (['assets/commitowl.ico'] if platform == 'windows' else [])
    for f in shared:
        yield f, content(os.path.join(ROOT, f), crlf), False
    for f in (WINDOWS if platform == 'windows' else LINUX):
        yield f, content(os.path.join(ROOT, platform, f), crlf), f in EXECUTABLE
    readme = readme_for(platform).replace('\r\n', '\n')
    yield 'README.md', (readme.replace('\n', '\r\n') if crlf else readme).encode('utf-8'), False


def build_zip(v):
    out = os.path.join(DIST, f'CommitOwl-v{v}-windows.zip')
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data, _ in files('windows'):
            z.writestr('CommitOwl/' + name, data)
    return out


def build_tar(v):
    out = os.path.join(DIST, f'CommitOwl-v{v}-linux.tar.gz')
    now = time.time()
    with tarfile.open(out, 'w:gz') as t:
        dirs = set()
        for name, data, exe in files('linux'):
            parts = ('CommitOwl/' + name).split('/')[:-1]
            for i in range(1, len(parts) + 1):
                d = '/'.join(parts[:i])
                if d not in dirs:
                    dirs.add(d)
                    di = tarfile.TarInfo(d)
                    di.type, di.mode, di.mtime = tarfile.DIRTYPE, 0o755, now
                    t.addfile(di)
            ti = tarfile.TarInfo('CommitOwl/' + name)
            ti.size, ti.mode, ti.mtime = len(data), (0o755 if exe else 0o644), now
            t.addfile(ti, io.BytesIO(data))
    return out


def main():
    v = version()
    os.makedirs(DIST, exist_ok=True)
    for path in (build_zip(v), build_tar(v)):
        print(f'Built {os.path.relpath(path, ROOT)}  ({os.path.getsize(path) // 1024} KB)')


if __name__ == '__main__':
    main()
