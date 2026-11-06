# =====================================================================
#  CommitOwl for Linux - the window
#  Repositories, Commit message, Schedule & log, About.
#
#  Developed by: EMR Industries
#  Version 1.3 - Built 2026.11.06
#  MIT License - see LICENSE
# =====================================================================

import datetime as dt
import os
import shutil
import subprocess
import sys
import tkinter as tk
import tkinter.font
from tkinter import filedialog, messagebox, simpledialog, ttk

import commitowl as core

COLS = ('repo', 'pause', 'branch', 'remote', 'time', 'hash', 'result')
HEAD = {'repo': 'Repository', 'pause': 'Auto push', 'branch': 'Branch', 'remote': 'Remote',
        'time': 'Last push', 'hash': 'Commit', 'result': 'Result'}
WIDTH = {'repo': 280, 'pause': 175, 'branch': 80, 'remote': 70, 'time': 135, 'hash': 75, 'result': 260}
NOTIFY = [('problems', 'Only when something needs attention'), ('always', 'After every push'), ('never', 'Never')]


class App:
    def __init__(self, root):
        self.root = root
        self.cfg = core.load_config()
        self.proc = None

        root.title(f'CommitOwl {core.APP_VERSION}')
        root.geometry('1040x620')
        root.minsize(760, 480)
        if os.path.exists(core.ICON_PNG):
            self.icon = tk.PhotoImage(file=core.ICON_PNG)
            root.iconphoto(True, self.icon)

        style = ttk.Style()
        if 'clam' in style.theme_names():
            style.theme_use('clam')
        lh = tk.font.nametofont('TkDefaultFont').metrics('linespace')
        style.configure('Treeview', rowheight=lh + 10, foreground='black', background='white', fieldbackground='white')
        style.map('Treeview', background=[('selected', '#cce4f7')], foreground=[('selected', 'black')])
        style.configure('Grey.TLabel', foreground='#555555')
        style.configure('TButton', padding=(10, 4))

        self.tabs = ttk.Notebook(root)
        self.tabs.pack(fill='both', expand=True, padx=6, pady=6)
        self.build_repos()
        self.build_message()
        self.build_schedule()
        self.build_about()
        self.tabs.bind('<<NotebookTabChanged>>', self.on_tab)

        self.refresh_repos()
        self.load_message()
        self.refresh_schedule()
        self.refresh_log()

    # ------------------------------------------------------------------ helpers
    def info(self, text):
        messagebox.showinfo('CommitOwl', text, parent=self.root)

    def warn(self, text):
        messagebox.showwarning('CommitOwl', text, parent=self.root)

    def ask(self, text):
        return messagebox.askyesno('CommitOwl', text, parent=self.root)

    @staticmethod
    def open_path(path):
        opener = shutil.which('xdg-open')
        if opener:
            subprocess.Popen([opener, path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # ------------------------------------------------------------------ Repositories tab
    def build_repos(self):
        f = ttk.Frame(self.tabs, padding=8)
        self.tabs.add(f, text='Repositories')
        ttk.Label(f, text='Active repositories are committed and pushed every day. Click Auto push to pause one, '
                          'for a day or until you resume it.').pack(anchor='w', pady=(0, 6))

        box = ttk.Frame(f)
        box.pack(fill='both', expand=True)
        self.tree = ttk.Treeview(box, columns=COLS, show='headings', selectmode='browse')
        for c in COLS:
            self.tree.heading(c, text=HEAD[c], anchor='w')
            self.tree.column(c, width=WIDTH[c], anchor='w', stretch=(c in ('repo', 'result')))
        sb = ttk.Scrollbar(box, orient='vertical', command=self.tree.yview)
        self.tree.configure(yscrollcommand=sb.set)
        self.tree.pack(side='left', fill='both', expand=True)
        sb.pack(side='right', fill='y')
        self.tree.tag_configure('error', foreground='#b22222')
        self.tree.tag_configure('local', foreground='#d2691e')
        self.tree.tag_configure('paused', foreground='#808080')
        self.tree.bind('<Button-1>', self.on_tree_click)
        self.tree.bind('<Double-1>', self.on_tree_double)

        bar = ttk.Frame(f)
        bar.pack(fill='x', pady=(8, 0))
        self.btns = []
        for text, cmd in (('Add repository...', self.add_repo), ('Remove', self.remove_repo),
                          ('Commit & Push', self.run_one), ('Commit & Push all', self.run_all),
                          ('Add .gitignore', self.add_ignore), ('Open folder', self.open_repo)):
            b = ttk.Button(bar, text=text, command=cmd)
            b.pack(side='left', padx=(0, 6))
            self.btns.append(b)
        self.status = ttk.Label(f, style='Grey.TLabel')
        self.status.pack(anchor='w', pady=(6, 0))

    def selected(self, quiet=False):
        sel = self.tree.selection()
        if not sel:
            if not quiet:
                self.info('Select a repository in the list first.')
            return None
        return self.cfg['repos'][int(sel[0])]

    def counts(self):
        active = sum(1 for r in self.cfg['repos'] if not core.get_pause(r))
        return active, len(self.cfg['repos'])

    def update_status(self):
        if self.proc:
            return
        a, n = self.counts()
        self.status.configure(text=f'{a} of {n} repositories are committed and pushed every day.'
                                   + (f' {n - a} paused.' if n - a else ''))

    def refresh_repos(self):
        state = core.load_state()
        keep = self.tree.selection()
        self.tree.delete(*self.tree.get_children())
        for i, r in enumerate(self.cfg['repos']):
            until = core.get_pause(r)
            pause = core.format_pause(until) if until else 'Active'
            br = r.get('branch') or (core.current_branch(r['path']) if os.path.isdir(r['path']) else '(missing)') or '?'
            st = state.get(r['path'])
            tags = ()
            if st:
                vals = (r['path'], pause + '  ▾', br, r['remote'], st.get('time', '-'),
                        st.get('hash') or '-', st.get('detail', ''))
                if st.get('result') in ('error', 'conflict'):
                    tags = ('error',)
                elif st.get('result') == 'local':
                    tags = ('local',)
            else:
                vals = (r['path'], pause + '  ▾', br, r['remote'], '-', '-', 'Not pushed yet')
            if until:
                tags = ('paused',)
            self.tree.insert('', 'end', iid=str(i), values=vals, tags=tags)
        for k in keep:
            if self.tree.exists(k):
                self.tree.selection_set(k)
        self.update_status()

    def on_tree_click(self, ev):
        if self.tree.identify_region(ev.x, ev.y) != 'cell':
            return
        row, col = self.tree.identify_row(ev.y), self.tree.identify_column(ev.x)
        if not row or col != '#2':
            return
        self.tree.selection_set(row)
        repo = self.cfg['repos'][int(row)]
        until = core.get_pause(repo)
        current = 'Active' if not until else ('Pause until I resume' if until == core.FOREVER else None)
        menu = tk.Menu(self.root, tearoff=0, foreground='black', activeforeground='black')
        if until and until != core.FOREVER:
            menu.add_command(label=core.format_pause(until), state='disabled')
            menu.add_separator()
        for choice in core.PAUSE_CHOICES:
            mark = '✓  ' if choice == current else '     '
            menu.add_command(label=mark + choice, command=lambda c=choice, r=repo: self.choose_pause(r, c))
        x0, y0, w, h = self.tree.bbox(row, '#2')
        menu.tk_popup(self.tree.winfo_rootx() + x0, self.tree.winfo_rooty() + y0 + h)
        return 'break'

    def choose_pause(self, repo, choice):
        if core.set_pause(repo, choice):
            core.save_config(self.cfg)
        self.refresh_repos()

    def on_tree_double(self, ev):
        row, col = self.tree.identify_row(ev.y), self.tree.identify_column(ev.x)
        if not row or col == '#2':
            return
        if col == '#6':
            h = self.tree.set(row, 'hash')
            if h and h != '-':
                self.root.clipboard_clear()
                self.root.clipboard_append(h)
                self.status.configure(text=f'Copied commit {h} to the clipboard.')
            return
        self.open_path(self.cfg['repos'][int(row)]['path'])

    def add_repo(self):
        folder = filedialog.askdirectory(parent=self.root, title='Pick the repository folder (or a project folder to turn into a Git repository)')
        if not folder:
            return
        url = ''
        code, top = core.git(folder, 'rev-parse', '--show-toplevel')
        if code == 0:
            repo = top
        else:
            if not self.ask(f"{folder} is not a Git repository yet.\n\nMake it one now? CommitOwl will run 'git init' "
                            "and add a .gitignore for electronics projects."):
                return
            code, out = core.git(folder, 'init', '-b', 'main')
            if code != 0:
                code, out = core.git(folder, 'init')
                if code == 0:
                    core.git(folder, 'symbolic-ref', 'HEAD', 'refs/heads/main')
            if code != 0:
                messagebox.showerror('CommitOwl', 'git init failed: ' + out, parent=self.root)
                return
            self.write_ignore(folder)
            url = simpledialog.askstring('CommitOwl', f'Remote URL to push to (for example https://github.com/you/{os.path.basename(folder)}.git).\n\n'
                                         'Create an empty repository on GitHub/GitLab first. Leave empty to add it later.',
                                         parent=self.root) or ''
            if url.strip():
                core.git(folder, 'remote', 'add', 'origin', url.strip())
            repo = folder
        if any(os.path.abspath(r['path']) == os.path.abspath(repo) for r in self.cfg['repos']):
            self.info('That repository is already in the list.')
            return
        remotes = core.lines(core.git(repo, 'remote')[1])
        remote = 'origin' if 'origin' in remotes or not remotes else remotes[0]
        self.cfg['repos'].append({'path': repo, 'remote': remote, 'branch': '', 'enabled': True, 'pausedUntil': ''})
        core.save_config(self.cfg)
        self.check_identity(repo)
        self.refresh_repos()
        if not remotes and not url.strip():
            self.warn('Added. This repository has no remote yet, so commits are kept on this PC only.\n\n'
                      'Add one with your Git client, or run:  git remote add origin <url>')
        if not os.path.exists(os.path.join(repo, '.gitignore')):
            if self.ask('This repository has no .gitignore. Add one for electronics projects (KiCad, Altium, Eagle, PlatformIO, STM32)?'):
                self.write_ignore(repo)

    def check_identity(self, repo):
        if core.git(repo, 'config', 'user.name')[0] == 0 and core.git(repo, 'config', 'user.email')[0] == 0:
            return
        self.info('Git needs your name and email to sign commits. You will be asked for them now (saved in your global Git settings).')
        name = simpledialog.askstring('CommitOwl', 'Your name for Git commits:', initialvalue=os.environ.get('USER', ''), parent=self.root)
        email = simpledialog.askstring('CommitOwl', 'Your email for Git commits:', parent=self.root)
        if name:
            core.git(repo, 'config', '--global', 'user.name', name)
        if email:
            core.git(repo, 'config', '--global', 'user.email', email)

    def remove_repo(self):
        r = self.selected()
        if r and self.ask(f"Remove {r['path']} from CommitOwl?\n\nThe repository itself is not touched."):
            self.cfg['repos'].remove(r)
            core.save_config(self.cfg)
            self.tree.selection_set(())
            self.refresh_repos()

    def write_ignore(self, repo):
        """Returns -1 if a new file was written, else the number of rules added."""
        target = os.path.join(repo, '.gitignore')
        with open(core.IGNORE_TEMPLATE, encoding='utf-8') as f:
            template = f.read().splitlines()
        if not os.path.exists(target):
            shutil.copyfile(core.IGNORE_TEMPLATE, target)
            return -1
        with open(target, encoding='utf-8', errors='replace') as f:
            have = {l.strip() for l in f}
        add = [l for l in template if l.strip() and not l.startswith('#') and l.strip() not in have]
        if add:
            with open(target, 'a', encoding='utf-8') as f:
                f.write('\n# ---- Added by CommitOwl ----\n' + '\n'.join(add) + '\n')
        return len(add)

    def add_ignore(self):
        r = self.selected()
        if not r:
            return
        n = self.write_ignore(r['path'])
        if n < 0:
            self.info('Added a .gitignore for electronics projects.')
        elif n == 0:
            self.info('The .gitignore already has every CommitOwl rule.')
        else:
            self.info(f'Added {n} rule(s) to the existing .gitignore.\n\nFiles Git already tracks stay tracked; '
                      'untrack them with:  git rm --cached <file>')

    def open_repo(self):
        r = self.selected()
        if r:
            self.open_path(r['path'])

    def run_one(self):
        r = self.selected()
        if not r:
            return
        until = core.get_pause(r)
        if until and not self.ask(f"{os.path.basename(r['path'])} is paused ({core.format_pause(until)}).\n\n"
                                  'Commit and push it now anyway? It stays paused for the daily run.'):
            return
        self.start_run(r['path'])

    def run_all(self):
        if not self.counts()[0]:
            self.info('All repositories are paused.')
            return
        self.start_run(None)

    def start_run(self, repo_path):
        if self.proc:
            return
        args = [sys.executable, os.path.join(core.HERE, 'commitowl.py'), 'run', '--manual']
        if repo_path:
            args += ['--repo', repo_path]
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        for b in self.btns[:5]:
            b.state(['disabled'])
        self.root.configure(cursor='watch')
        self.status.configure(text=(f'Committing and pushing {os.path.basename(repo_path)}...' if repo_path
                                    else 'Committing and pushing all active repositories...'))
        self.root.after(500, self.poll_run)

    def poll_run(self):
        code = self.proc.poll()
        if code is None:
            self.root.after(500, self.poll_run)
            return
        self.proc = None
        for b in self.btns:
            b.state(['!disabled'])
        self.root.configure(cursor='')
        self.refresh_repos()
        self.refresh_log()
        self.status.configure(text='Commit and push finished.' if code == 0 else
                              'Commit and push finished with problems. See the Result column and the log.')
        if code == 3:
            st = core.load_state()
            names = [os.path.basename(r['path']) for r in self.cfg['repos']
                     if st.get(r['path'], {}).get('result') == 'conflict']
            self.warn('Auto commit stopped: conflict with the remote in ' + ', '.join(names) + '.\n\n'
                      'The remote has changes to the same files. Nothing was pushed, and your work is committed locally.\n\n'
                      'Pull and resolve the conflict in your Git client (git pull). The next run pushes it.')

    # ------------------------------------------------------------------ Commit message tab
    def build_message(self):
        f = ttk.Frame(self.tabs, padding=8)
        self.tabs.add(f, text='Commit message')
        f.columnconfigure(0, weight=1)
        f.rowconfigure(3, weight=1)
        f.rowconfigure(6, weight=1)
        mono = ('DejaVu Sans Mono', 10)

        ttk.Label(f, text='Every automatic commit starts with this header line. It is added for you and cannot be changed:').grid(row=0, column=0, sticky='w')
        hdr = ttk.Entry(f, font=mono)
        hdr.insert(0, 'Auto-commit YYYY-MM-DD HH:mm (N files)')
        hdr.state(['readonly'])
        hdr.grid(row=1, column=0, sticky='ew', pady=(2, 8))

        ttk.Label(f, text='Your message, added below the header (leave empty for the default line):').grid(row=2, column=0, sticky='w')
        self.msg = tk.Text(f, height=6, font=mono, wrap='word', undo=True, foreground='black', background='white')
        self.msg.grid(row=3, column=0, sticky='nsew', pady=(2, 6))
        self.msg.bind('<<Modified>>', self.on_msg_change)

        self.list_files = tk.BooleanVar(value=True)
        ttk.Checkbutton(f, text='Add the list of changed files at the end', variable=self.list_files,
                        command=self.update_preview).grid(row=4, column=0, sticky='w', pady=(0, 6))

        ttk.Label(f, text='Preview').grid(row=5, column=0, sticky='w')
        self.preview = tk.Text(f, height=8, font=mono, wrap='word', foreground='black', background='#f6f6f6')
        self.preview.grid(row=6, column=0, sticky='nsew', pady=(2, 6))

        bar = ttk.Frame(f)
        bar.grid(row=7, column=0, sticky='w')
        ttk.Button(bar, text='Save message', command=self.save_message).pack(side='left', padx=(0, 6))
        ttk.Button(bar, text='Use default', command=self.default_message).pack(side='left', padx=(0, 10))
        self.msg_state = ttk.Label(bar, style='Grey.TLabel')
        self.msg_state.pack(side='left')

    def msg_text(self):
        return self.msg.get('1.0', 'end').strip()

    def on_msg_change(self, _ev=None):
        if self.msg.edit_modified():
            self.update_preview()
            self.msg.edit_modified(False)

    def update_preview(self):
        tmp = {'commitMessage': self.msg_text(), 'listFiles': self.list_files.get()}
        sample = ['M\tboard.kicad_sch', 'M\tboard.kicad_pcb', 'A\tfirmware/src/main.c']
        text = core.build_commit_message(dt.datetime.now().strftime('%Y-%m-%d %H:%M'), sample, tmp)
        self.preview.configure(state='normal')
        self.preview.delete('1.0', 'end')
        self.preview.insert('1.0', text)
        self.preview.configure(state='disabled')
        dirty = (self.msg_text() != (self.cfg.get('commitMessage') or '').strip()
                 or self.list_files.get() != bool(self.cfg.get('listFiles', True)))
        self.msg_state.configure(text='Not saved yet.' if dirty else 'Saved. Used for every automatic and Commit & Push commit.')

    def load_message(self):
        self.msg.delete('1.0', 'end')
        self.msg.insert('1.0', self.cfg.get('commitMessage') or '')
        self.msg.edit_modified(False)
        self.list_files.set(bool(self.cfg.get('listFiles', True)))
        self.update_preview()

    def save_message(self):
        self.cfg['commitMessage'] = self.msg_text()
        self.cfg['listFiles'] = self.list_files.get()
        core.save_config(self.cfg)
        self.update_preview()

    def default_message(self):
        self.msg.delete('1.0', 'end')
        self.list_files.set(True)
        self.update_preview()

    # ------------------------------------------------------------------ Schedule & log tab
    def build_schedule(self):
        f = ttk.Frame(self.tabs, padding=8)
        self.tabs.add(f, text='Schedule & log')
        grp = ttk.LabelFrame(f, text='Daily commit and push', padding=10)
        grp.pack(fill='x')

        r1 = ttk.Frame(grp)
        r1.pack(fill='x', pady=(0, 6))
        self.daily = tk.BooleanVar()
        ttk.Checkbutton(r1, text='Commit and push every day at', variable=self.daily).pack(side='left')
        self.hour = tk.StringVar(value='21')
        self.minute = tk.StringVar(value='00')
        ttk.Spinbox(r1, from_=0, to=23, width=3, format='%02.0f', wrap=True, textvariable=self.hour).pack(side='left', padx=(6, 0))
        ttk.Label(r1, text=':').pack(side='left')
        ttk.Spinbox(r1, from_=0, to=59, width=3, format='%02.0f', wrap=True, textvariable=self.minute).pack(side='left')
        ttk.Label(r1, text='   If the PC is off or asleep then, it runs as soon as you are back.', style='Grey.TLabel').pack(side='left')

        r2 = ttk.Frame(grp)
        r2.pack(fill='x', pady=(0, 6))
        ttk.Label(r2, text='Notify me').pack(side='left')
        self.notify = ttk.Combobox(r2, state='readonly', width=34, values=[t for _, t in NOTIFY])
        self.notify.pack(side='left', padx=(6, 20))
        ttk.Label(r2, text='Skip files larger than (MB)').pack(side='left')
        self.maxmb = tk.StringVar()
        ttk.Spinbox(r2, from_=1, to=2000, width=6, textvariable=self.maxmb).pack(side='left', padx=(6, 0))

        r3 = ttk.Frame(grp)
        r3.pack(fill='x')
        ttk.Button(r3, text='Save schedule', command=self.save_schedule).pack(side='left')
        self.sched_state = ttk.Label(r3, style='Grey.TLabel')
        self.sched_state.pack(side='left', padx=(10, 0))

        ttk.Label(f, text=f'Log ({core.LOG_FILE})').pack(anchor='w', pady=(10, 2))
        box = ttk.Frame(f)
        box.pack(fill='both', expand=True)
        self.log = tk.Text(box, height=10, font=('DejaVu Sans Mono', 9), wrap='none', foreground='black', background='white')
        sy = ttk.Scrollbar(box, orient='vertical', command=self.log.yview)
        self.log.configure(yscrollcommand=sy.set)
        self.log.pack(side='left', fill='both', expand=True)
        sy.pack(side='right', fill='y')

        bar = ttk.Frame(f)
        bar.pack(fill='x', pady=(6, 0))
        ttk.Button(bar, text='Refresh', command=lambda: (self.refresh_log(), self.refresh_schedule(), self.refresh_repos())).pack(side='left', padx=(0, 6))
        ttk.Button(bar, text='Open log', command=lambda: self.open_path(core.LOG_FILE) if os.path.exists(core.LOG_FILE) else self.info('No log yet.')).pack(side='left')

    def refresh_schedule(self):
        self.notify.set(dict(NOTIFY).get(self.cfg['notify'], NOTIFY[0][1]))
        self.maxmb.set(str(self.cfg['maxFileMB']))
        try:
            s = core.get_schedule()
        except Exception:
            s = {'enabled': False, 'time': '', 'backend': ''}
        self.daily.set(s['enabled'])
        if s.get('time'):
            self.hour.set(s['time'][:2])
            self.minute.set(s['time'][3:5])
        if not s['enabled']:
            self.sched_state.configure(text='No schedule yet. Tick the box, pick a time and click Save schedule.'
                                       if not s.get('backend') else 'Schedule is off.')
        elif s['backend'] == 'systemd':
            res = {'0': 'OK', '1': 'needs attention, see log', '3': 'stopped: conflict'}.get(s.get('result', ''), '')
            self.sched_state.configure(text=f"Next push: {s['next']}     Last: {s['last']}" + (f' ({res})' if res and s['last'] != '-' else ''))
        else:
            self.sched_state.configure(text=f"Every day at {s['time']} (cron).")

    def save_schedule(self):
        try:
            mb = max(1, min(2000, int(self.maxmb.get())))
        except ValueError:
            mb = 50
        self.cfg['maxFileMB'] = mb
        self.cfg['notify'] = {t: k for k, t in NOTIFY}.get(self.notify.get(), 'problems')
        core.save_config(self.cfg)
        try:
            when = None
            if self.daily.get():
                when = f'{int(self.hour.get()) % 24:02d}:{int(self.minute.get()) % 60:02d}'
            self.info(core.set_schedule(when))
        except Exception as e:
            messagebox.showerror('CommitOwl', f'Could not save the schedule: {e}', parent=self.root)
        self.refresh_schedule()

    def refresh_log(self):
        self.log.configure(state='normal')
        self.log.delete('1.0', 'end')
        try:
            with open(core.LOG_FILE, encoding='utf-8', errors='replace') as f:
                self.log.insert('1.0', ''.join(f.readlines()[-400:]))
        except FileNotFoundError:
            self.log.insert('1.0', 'Nothing has been pushed yet.')
        self.log.see('end')
        self.log.configure(state='disabled')

    def on_tab(self, _ev=None):
        if self.tabs.index('current') == 2:
            self.refresh_log()
            self.refresh_schedule()

    # ------------------------------------------------------------------ About tab
    def build_about(self):
        f = ttk.Frame(self.tabs, padding=20)
        self.tabs.add(f, text='About')
        if os.path.exists(core.ICON_PNG):
            self.logo = tk.PhotoImage(file=core.ICON_PNG).subsample(2)
            ttk.Label(f, image=self.logo).grid(row=0, column=0, rowspan=2, sticky='n', padx=(0, 20))
        ttk.Label(f, text='CommitOwl', font=('TkDefaultFont', 22, 'bold')).grid(row=0, column=1, sticky='w')
        ttk.Label(f, justify='left', text=(
            'Daily auto commit and push for electronics projects.\n\n'
            f'Version:  {core.APP_VERSION} (Linux)\n'
            f'Developed by:  {core.APP_VENDOR}\n'
            f'Build date:  {core.APP_BUILD_DATE}\n\n'
            'Every day CommitOwl commits all changes in your design repositories and pushes them,\n'
            'so schematics, layouts and firmware are backed up even when you forget to commit.\n'
            'It works with git and any Git client you already use.\n\n'
            'Free and open source under the MIT License.\n'
            f'Copyright (c) 2026 {core.APP_VENDOR}\n\n'
            'Git is a trademark of its respective owner. CommitOwl is an independent tool\n'
            'and is not affiliated with or endorsed by the Git project.')).grid(row=1, column=1, sticky='nw')


def main():
    if not core.GIT:
        r = tk.Tk()
        r.withdraw()
        messagebox.showerror('CommitOwl', 'git was not found.\n\nInstall it with your package manager, for example:\n  sudo apt install git')
        return 1
    root = tk.Tk(className='commitowl')
    App(root)
    root.mainloop()
    return 0


if __name__ == '__main__':
    sys.exit(main())
