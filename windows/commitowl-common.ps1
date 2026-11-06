# =====================================================================
#  CommitOwl - shared settings and Git helpers
#  Used by CommitOwl.ps1 (window) and commitowl-run.ps1 (commit and push worker)
#
#  Developed by: EMR Industries
#  Version 1.3 - Built 2026.11.06
# =====================================================================

$script:AppName      = 'CommitOwl'
$script:AppVersion   = '1.3'
$script:AppBuildDate = '2026.11.06'
$script:AppVendor    = 'EMR Industries'

$script:DataDir    = Join-Path $env:APPDATA 'CommitOwl'
$script:ConfigFile = Join-Path $script:DataDir 'config.json'
$script:StateFile  = Join-Path $script:DataDir 'state.json'
$script:LogFile    = Join-Path $env:USERPROFILE 'commitowl.log'
$script:LogMaxBytes = 2MB

$script:TaskPath = '\CommitOwl\'
$script:TaskName = 'Daily commit and push'
$script:LegacyTaskName = 'Daily snapshot'   # name used by version 1.0 and 1.1

# Files never committed automatically: secrets and keys
$script:SecretPatterns = @(
    '.env', '.env.*', '*.pem', '*.key', '*.p12', '*.pfx', '*.ppk', '*.keystore', '*.jks',
    'id_rsa', 'id_rsa*', 'id_dsa*', 'id_ecdsa*', 'id_ed25519*',
    'credentials', 'credentials.*', '*.secret', 'secrets.*', 'secrets_*.h', 'wifi_secrets.h'
)

# Files never committed automatically: lock files and editor scratch files
$script:JunkPatterns = @(
    '*.lck', '~*.lck', '~$*', '*.tmp', '*.swp', '_autosave-*', '#auto_saved_files#',
    'fp-info-cache', 'Thumbs.db', 'desktop.ini', '.DS_Store'
)

# Shared files (icon, .gitignore template) sit next to the scripts in a
# release download, and one folder up when run from the source repository.
function Find-OwlFile([string]$Relative) {
    foreach ($base in @($PSScriptRoot, (Split-Path -Parent $PSScriptRoot))) {
        $p = Join-Path $base $Relative
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return (Join-Path $PSScriptRoot $Relative)
}

# ---------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------
function New-OwlConfig {
    [pscustomobject]@{
        repos       = @()
        notify      = 'problems'   # always | problems | never
        maxFileMB   = 50           # files bigger than this are not committed
        commitMessage = ''         # your text under the fixed "Auto-commit ..." header; empty = default line
        listFiles   = $true        # add the list of changed files at the end of the message
    }
}

function Get-OwlConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) { return New-OwlConfig }
    try {
        $c = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-OwlLog "[WARN] Settings file could not be read, starting with defaults: $($_.Exception.Message)"
        return New-OwlConfig
    }
    $d = New-OwlConfig
    if ($null -eq $c.notify)    { $c | Add-Member -NotePropertyName notify    -NotePropertyValue $d.notify -Force }
    if ($null -eq $c.maxFileMB) { $c | Add-Member -NotePropertyName maxFileMB -NotePropertyValue $d.maxFileMB -Force }
    if ($null -eq $c.commitMessage) { $c | Add-Member -NotePropertyName commitMessage -NotePropertyValue $d.commitMessage -Force }
    if ($null -eq $c.listFiles) { $c | Add-Member -NotePropertyName listFiles -NotePropertyValue $d.listFiles -Force }
    $list = @()
    foreach ($r in @($c.repos)) {
        if ($null -eq $r -or -not $r.path) { continue }
        $list += [pscustomobject]@{
            path    = [string]$r.path
            remote  = $(if ($r.remote) { [string]$r.remote } else { 'origin' })
            branch  = $(if ($r.branch) { [string]$r.branch } else { '' })
            enabled = $(if ($null -eq $r.enabled) { $true } else { [bool]$r.enabled })
            pausedUntil = $(if ($r.pausedUntil) { [string]$r.pausedUntil } else { '' })
        }
    }
    $c | Add-Member -NotePropertyName repos -NotePropertyValue $list -Force
    return $c
}

function Save-OwlConfig($Config) {
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $out = [pscustomobject]@{
        repos     = @($Config.repos)
        notify    = $Config.notify
        maxFileMB = [int]$Config.maxFileMB
        commitMessage = [string]$Config.commitMessage
        listFiles = [bool]$Config.listFiles
    }
    $json = ConvertTo-Json -InputObject $out -Depth 5
    [IO.File]::WriteAllText($script:ConfigFile, $json, (New-Object Text.UTF8Encoding $false))
}

function Get-OwlState {
    $h = @{}
    if (Test-Path -LiteralPath $script:StateFile) {
        try {
            $s = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $s.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch { }
    }
    return $h
}

function Set-OwlState([string]$RepoPath, [string]$Result, [string]$Detail, [string]$Hash = '') {
    $h = Get-OwlState
    $h[$RepoPath.ToLowerInvariant()] = [pscustomobject]@{
        time   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
        hash   = $Hash
        result = $Result
        detail = $Detail
    }
    if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject ([pscustomobject]$h) -Depth 4
    [IO.File]::WriteAllText($script:StateFile, $json, (New-Object Text.UTF8Encoding $false))
}

# Pause state of a repository:
#   $null              -> active
#   [datetime]::MaxValue -> paused until resumed by hand
#   a date             -> paused until that date (it runs again from 00:00 that day)
function Get-OwlPause($Repo) {
    if (-not $Repo.enabled) { return [datetime]::MaxValue }
    if ($Repo.pausedUntil) {
        try {
            $d = [datetime]::ParseExact($Repo.pausedUntil, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
            if ((Get-Date) -lt $d) { return $d }
        } catch { }
    }
    return $null
}

function Format-OwlPause($Until) {
    if ($Until -eq [datetime]::MaxValue) { return 'Paused until I resume' }
    return 'Paused until ' + $Until.ToString('ddd d MMM', [Globalization.CultureInfo]::InvariantCulture)
}

# Builds the commit message: a fixed header line, then your message, then the changed files.
function New-OwlCommitMessage([string]$Stamp, [string[]]$Changes, $Config, [bool]$Manual) {
    $n = @($Changes).Count
    $files = $(if ($n -eq 1) { '1 file' } else { "$n files" })
    $msg = "Auto-commit $Stamp ($files)"
    $body = ([string]$Config.commitMessage).Trim()
    if (-not $body) {
        $body = $(if ($Manual) { 'Committed with the Commit & Push button in CommitOwl.' } else { 'Daily automatic commit by CommitOwl.' })
    }
    $msg += "`n`n" + ($body -replace "`r`n", "`n")
    if ($Config.listFiles -and $n) {
        $msg += "`n`n" + ((@($Changes) | Select-Object -First 60) -join "`n")
        if ($n -gt 60) { $msg += "`n... and $($n - 60) more" }
    }
    return $msg
}

# ---------------------------------------------------------------------
# Log
# ---------------------------------------------------------------------
function Write-OwlLog([string]$Message) {
    try {
        if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt $script:LogMaxBytes)) {
            $old = $script:LogFile + '.old'
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
            Rename-Item -LiteralPath $script:LogFile -NewName ([IO.Path]::GetFileName($old))
        }
        $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
        [IO.File]::AppendAllText($script:LogFile, $line + "`r`n", (New-Object Text.UTF8Encoding $false))
    } catch { }
    Write-Host $Message
}

# ---------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------
function Find-Git {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command git -ErrorAction SilentlyContinue }
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\Git\cmd\git.exe", "${env:ProgramFiles(x86)}\Git\cmd\git.exe", "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

# Call as: Invoke-Git $repo @('status','--porcelain')
# Runs git and never stops to ask for a password. Returns ExitCode and Output (array of lines).
function Invoke-Git {
    param([string]$Repo, [string[]]$GitArgs)
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE     = 'never'
    $env:GIT_ASKPASS         = ''
    $env:SSH_ASKPASS         = ''
    if (-not $env:GIT_SSH_COMMAND) { $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=yes' }
    $all = @('-C', $Repo, '-c', 'core.quotepath=off', '-c', 'color.ui=false') + $GitArgs
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $script:Git @all 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } catch {
        $out = @("$($_.Exception.Message)")
        $code = 1
    } finally {
        $ErrorActionPreference = $prev
    }
    [pscustomobject]@{ ExitCode = $code; Output = @($out) }
}

function Get-GitText($Result) { (@($Result.Output) -join "`n").Trim() }

function Test-OwlMatch([string]$File, [string[]]$Patterns) {
    $name = [IO.Path]::GetFileName($File)
    foreach ($p in $Patterns) {
        if ($name -like $p) { return $true }
    }
    return $false
}

$script:Git = Find-Git
