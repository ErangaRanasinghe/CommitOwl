# =====================================================================
#  CommitOwl - commit and push worker
#  Commits every change in each watched repository, then pushes it.
#  Run by the daily schedule, and by "Commit & Push" in the window.
#
#    commitowl-run.ps1                    all active (not paused) repositories
#    commitowl-run.ps1 -RepoPath C:\pcb   one repository
#
#  Developed by: EMR Industries
#  Version 1.3 - Built 2026.11.06
# =====================================================================
param(
    [string]$RepoPath = '',
    [switch]$Manual
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'commitowl-common.ps1')
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }

# One run at a time (a manual run and the schedule could overlap)
$mutex = New-Object Threading.Mutex($false, 'Local\CommitOwlSnapshot')
if (-not $mutex.WaitOne(0)) {
    Write-OwlLog '[SKIP] Another commit and push is already running.'
    exit 0
}

function Invoke-CommitPush($Repo, $Config) {
    $path   = $Repo.path
    $remote = $Repo.remote
    $tag    = '[' + (Split-Path -Leaf $path) + ']'
    $log    = { param($m) Write-OwlLog "$tag $m" }

    if (-not (Test-Path -LiteralPath $path)) {
        & $log '[ERROR] Folder not found. Is the drive connected?'
        return @('error', 'Folder not found')
    }
    $top = Invoke-Git $path @('rev-parse', '--show-toplevel')
    if ($top.ExitCode -ne 0) {
        & $log '[ERROR] Not a Git repository.'
        return @('error', 'Not a Git repository')
    }

    # Do not touch a repository that is in the middle of something
    $gd = Invoke-Git $path @('rev-parse', '--absolute-git-dir')
    $gitDir = (Get-GitText $gd)
    foreach ($busy in @('MERGE_HEAD', 'rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG')) {
        if (Test-Path -LiteralPath (Join-Path $gitDir $busy)) {
            & $log "[SKIP] A merge, rebase or similar is in progress ($busy). Finish it in your Git client first."
            return @('skipped', 'Merge or rebase in progress')
        }
    }
    if (Test-Path -LiteralPath (Join-Path $gitDir 'index.lock')) {
        & $log '[SKIP] Git is busy (index.lock exists). If no Git window is open, delete .git\index.lock.'
        return @('skipped', 'Git is busy (index.lock)')
    }

    $cur = Get-GitText (Invoke-Git $path @('symbolic-ref', '--quiet', '--short', 'HEAD'))
    if (-not $cur) {
        & $log '[SKIP] Detached HEAD (no branch checked out).'
        return @('skipped', 'No branch checked out')
    }
    $branch = $(if ($Repo.branch) { $Repo.branch } else { $cur })
    if ($branch -ne $cur) {
        & $log "[SKIP] Branch '$cur' is checked out, but this repository is set to '$branch'. CommitOwl never switches branches."
        return @('skipped', "On '$cur', set to '$branch'")
    }

    # ---------------- 1. Commit ----------------
    $committed = 0
    $notes = @()
    $add = Invoke-Git $path @('add', '-A')
    if ($add.ExitCode -ne 0) {
        & $log ('[ERROR] git add failed: ' + (Get-GitText $add))
        return @('error', 'git add failed')
    }

    $staged = @((Invoke-Git $path @('diff', '--cached', '--name-only', '--diff-filter=ACMR')).Output | Where-Object { $_ })
    $limit = [int64]$Config.maxFileMB * 1MB
    foreach ($f in $staged) {
        $why = $null
        if (Test-OwlMatch $f $script:SecretPatterns)   { $why = 'looks like a secret or key' }
        elseif (Test-OwlMatch $f $script:JunkPatterns) { $why = 'lock or temporary file' }
        else {
            $full = Join-Path $path $f
            if ((Test-Path -LiteralPath $full) -and ((Get-Item -LiteralPath $full).Length -gt $limit) -and
                ((Get-GitText (Invoke-Git $path @('check-attr', 'filter', '--', $f))) -notmatch 'filter: lfs$')) {
                $why = ('over {0} MB, use Git LFS' -f $Config.maxFileMB)
            }
        }
        if ($why) {
            Invoke-Git $path @('reset', '-q', '--', $f) | Out-Null
            $notes += "$f ($why)"
        }
    }
    if ($notes) {
        & $log ('[GUARD] Left out ' + $notes.Count + ' file(s): ' + ($notes -join ', ') + '. Add them to .gitignore to silence this.')
        $notes = @('left out ' + $notes.Count + ' file(s)')
    }

    $changes = @((Invoke-Git $path @('diff', '--cached', '--name-status')).Output | Where-Object { $_ })
    if ($changes.Count -gt 0) {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        $files = $(if ($changes.Count -eq 1) { '1 file' } else { "$($changes.Count) files" })
        $msg = New-OwlCommitMessage $stamp $changes $Config ([bool]$Manual)
        $msgFile = Join-Path $env:TEMP ('commitowl-msg-' + [guid]::NewGuid().ToString('N') + '.txt')
        [IO.File]::WriteAllText($msgFile, $msg + "`n", (New-Object Text.UTF8Encoding $false))
        $c = Invoke-Git $path @('commit', '-q', '-F', $msgFile)
        Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
        if ($c.ExitCode -ne 0) {
            $t = Get-GitText $c
            if ($t -match 'user\.name|user\.email|Please tell me who you are') {
                & $log '[ERROR] Git does not know your name and email. Run once:  git config --global user.name "Your Name"  and  git config --global user.email "you@example.com"'
            } else {
                & $log "[ERROR] Commit failed: $t"
            }
            return @('error', 'Commit failed')
        }
        $committed = $changes.Count
        & $log "Committed $files."
    } else {
        & $log 'No changes to commit.'
    }

    # ---------------- 2. Push ----------------
    $remotes = @((Invoke-Git $path @('remote')).Output | Where-Object { $_ })
    if ($remotes -notcontains $remote) {
        & $log "[WARN] No remote named '$remote'. The commit is saved locally only. Add a remote to back it up."
        return @($(if ($committed) { 'local' } else { 'ok' }), "No remote '$remote'")
    }

    $fetch = Invoke-Git $path @('fetch', '--quiet', $remote, $branch)
    $remoteRef = "refs/remotes/$remote/$branch"
    $remoteHas = $false
    if ($fetch.ExitCode -ne 0) {
        $t = Get-GitText $fetch
        if ($t -match "couldn't find remote ref|could not find remote ref") {
            $remoteHas = $false   # branch does not exist on the remote yet
        } else {
            & $log ('[WARN] Could not reach the remote, will try again next run: ' + ($t -split "`n")[0])
            return @('local', 'Offline - committed locally')
        }
    } else {
        $remoteHas = ((Invoke-Git $path @('rev-parse', '--verify', '--quiet', $remoteRef)).ExitCode -eq 0)
    }

    if ($remoteHas) {
        $behind = [int](Get-GitText (Invoke-Git $path @('rev-list', '--count', "HEAD..$remoteRef")))
        if ($behind -gt 0) {
            & $log "Remote has $behind new commit(s). Rebasing on top of them..."
            $rb = Invoke-Git $path @('rebase', '--autostash', $remoteRef)
            if ($rb.ExitCode -ne 0) {
                Invoke-Git $path @('rebase', '--abort') | Out-Null
                & $log '[ERROR] Your changes conflict with the remote. Nothing was pushed and your commit is safe. Pull and resolve it in your Git client (git pull).'
                return @('conflict', 'Conflict with remote - push stopped')
            }
        }
        $ahead = [int](Get-GitText (Invoke-Git $path @('rev-list', '--count', "$remoteRef..HEAD")))
        if ($ahead -eq 0) {
            & $log 'Remote is already up to date.'
            return @('ok', $(if ($notes) { $notes -join '; ' } else { 'Up to date' }))
        }
    }

    $pushArgs = @('push', '--porcelain')
    $up = Invoke-Git $path @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
    if ($up.ExitCode -ne 0 -or -not $remoteHas) {
        $pushArgs += '-u'
    }
    $pushArgs += @($remote, "HEAD:refs/heads/$branch")
    $p = Invoke-Git $path $pushArgs
    if ($p.ExitCode -ne 0) {
        $t = Get-GitText $p
        if ($t -match 'Authentication failed|could not read Username|terminal prompts disabled|Permission denied|403') {
            & $log '[ERROR] Push needs a login. Push once by hand (git push) so your login is saved, then CommitOwl can push on its own.'
        } elseif ($t -match 'rejected') {
            & $log '[ERROR] Remote rejected the push (it changed again). Will retry next run.'
        } elseif ($t -match 'Access is denied|blocked') {
            & $log '[ERROR] Git was blocked, possibly by Windows Defender Controlled Folder Access. Allow git.exe and ssh.exe in Windows Security.'
        } else {
            & $log "[ERROR] Push failed: $t"
        }
        return @('local', 'Push failed - committed locally')
    }
    & $log "Pushed to $remote/$branch."
    $detail = $(if ($committed) { "$committed file(s) committed and pushed" } else { 'Pushed earlier commits' })
    if ($notes) { $detail += '; ' + ($notes -join '; ') }
    return @('ok', $detail)
}

function Show-OwlBalloon([string]$Title, [string]$Text, [bool]$Problem) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $n = New-Object System.Windows.Forms.NotifyIcon
        $ico = Find-OwlFile 'assets\commitowl.ico'
        $n.Icon = $(if (Test-Path -LiteralPath $ico) { New-Object System.Drawing.Icon $ico } else { [System.Drawing.SystemIcons]::Information })
        $n.BalloonTipTitle = $Title
        $n.BalloonTipText  = $Text
        $n.BalloonTipIcon  = $(if ($Problem) { 'Warning' } else { 'Info' })
        $n.Visible = $true
        $n.ShowBalloonTip(8000)
        Start-Sleep -Seconds 8
        $n.Dispose()
    } catch { }
}

# ---------------- main ----------------
$exit = 0
try {
    if (-not $script:Git) {
        Write-OwlLog '[ERROR] git.exe not found. Install Git for Windows from https://git-scm.com/download/win'
        exit 2
    }
    $cfg = Get-OwlConfig
    if ($RepoPath) {
        $repos = @($cfg.repos | Where-Object { $_.path -eq $RepoPath })
        if (-not $repos) { $repos = @([pscustomobject]@{ path = $RepoPath; remote = 'origin'; branch = ''; enabled = $true }) }
    } else {
        $repos = @()
        foreach ($r in @($cfg.repos)) {
            $until = Get-OwlPause $r
            if ($until) { Write-OwlLog ('[' + (Split-Path -Leaf $r.path) + '] [PAUSED] ' + (Format-OwlPause $until) + '. Skipped.') }
            else { $repos += $r }
        }
    }

    Write-OwlLog ('===== Commit and push started' + $(if ($Manual) { ' (manual)' } else { ' (scheduled)' }) + " - $($repos.Count) repositor$(if ($repos.Count -eq 1) {'y'} else {'ies'}) =====")
    $summary = @(); $problems = 0; $conflicts = @()
    foreach ($r in $repos) {
        try {
            $res = Invoke-CommitPush $r $cfg
        } catch {
            Write-OwlLog ('[' + (Split-Path -Leaf $r.path) + '] [ERROR] ' + $_.Exception.Message)
            $res = @('error', $_.Exception.Message)
        }
        $hash = ''
        if (Test-Path -LiteralPath $r.path) {
            $hr = Invoke-Git $r.path @('rev-parse', '--short', 'HEAD')
            if ($hr.ExitCode -eq 0) { $hash = Get-GitText $hr }
        }
        Set-OwlState $r.path $res[0] $res[1] $hash
        if ($res[0] -in @('error', 'local', 'conflict')) { $problems++ }
        if ($res[0] -eq 'conflict') { $conflicts += (Split-Path -Leaf $r.path) }
        $summary += ('{0}: {1}' -f (Split-Path -Leaf $r.path), $res[1])
    }
    Write-OwlLog ("===== Commit and push finished - $problems problem(s) =====")
    if ($problems) { $exit = 1 }
    if ($conflicts) { $exit = 3 }

    if ($cfg.notify -ne 'never' -and $conflicts) {
        # Always tell about a conflict (unless notifications are off), also for manual runs
        $text = ($conflicts -join ', ') + ": the remote has changes that conflict with yours. Nothing was pushed; your work is committed locally. Pull and resolve it, and the next run pushes it."
        try { Show-OwlBalloon 'CommitOwl: auto commit stopped - conflict' $text $true } catch { }
    } elseif ($repos.Count -and -not $Manual -and ($cfg.notify -eq 'always' -or ($cfg.notify -eq 'problems' -and $problems))) {
        $title = $(if ($problems -eq 1) { 'CommitOwl: 1 repository needs attention' } elseif ($problems) { "CommitOwl: $problems repositories need attention" } else { 'CommitOwl: commit and push done' })
        try { Show-OwlBalloon $title (($summary | Select-Object -First 4) -join "`n") ([bool]$problems) } catch { }
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
exit $exit
