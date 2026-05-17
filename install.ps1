#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ReleaseUrl = 'https://api.github.com/repos/offe81/mcpbus-releases/releases/latest'
$InstallDir = Join-Path $env:LOCALAPPDATA 'mcpbus'
$ExePath    = Join-Path $InstallDir 'mcpbus.exe'

Clear-Host
Write-Host ''
Write-Host 'mcpbus' -ForegroundColor White -NoNewline

# ── Fetch latest release ──────────────────────────────────────────────────────

try {
    $headers = @{ 'User-Agent' = 'mcpbus-installer' }
    $release = Invoke-RestMethod -Uri $ReleaseUrl -Headers $headers -UseBasicParsing
    $version = $release.tag_name -replace '^v', ''
    $asset   = $release.assets | Where-Object { $_.name -eq 'mcpbus.exe' } | Select-Object -First 1
    if (-not $asset) { throw 'mcpbus.exe not found in latest release.' }
    Write-Host " $version" -ForegroundColor DarkGray
    Write-Host ''
} catch {
    Write-Host ''
    Write-Host "FAIL  Could not fetch release: $_" -ForegroundColor Red
    exit 1
}

# ── Download ──────────────────────────────────────────────────────────────────

Write-Host 'Downloading...' -ForegroundColor DarkGray
try {
    $null = New-Item -ItemType Directory -Force -Path $InstallDir
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $ExePath -UseBasicParsing -Headers $headers
} catch {
    Write-Host "FAIL  Download failed: $_" -ForegroundColor Red
    exit 1
}
Write-Host 'Download complete.' -ForegroundColor Green
Write-Host ''

# ── Detect installed Claude clients ───────────────────────────────────────────

Write-Host 'Detecting Claude clients...' -ForegroundColor DarkGray

$claudeDesktopFound = (Test-Path (Join-Path $env:LOCALAPPDATA 'AnthropicClaude')) -or
                      (Test-Path (Join-Path $env:APPDATA 'Claude'))
$claudeCodeFound    = $null -ne (Get-Command 'claude' -ErrorAction SilentlyContinue)

if ($claudeDesktopFound) { Write-Host '  Claude Desktop  found' -ForegroundColor Green }
else                     { Write-Host '  Claude Desktop  not installed' -ForegroundColor DarkGray }
if ($claudeCodeFound)    { Write-Host '  Claude Code     found' -ForegroundColor Green }
else                     { Write-Host '  Claude Code     not installed' -ForegroundColor DarkGray }
Write-Host ''

if (-not $claudeDesktopFound -and -not $claudeCodeFound) {
    Write-Host 'WARN  No Claude client found.' -ForegroundColor Yellow
    Write-Host '      Install Claude Desktop or Claude Code first, then re-run.' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

# ── Register ──────────────────────────────────────────────────────────────────

Write-Host 'Registering...' -ForegroundColor DarkGray

$installArgs = '--install'
if (-not $claudeDesktopFound) { $installArgs += ' --no-claude-desktop' }
if (-not $claudeCodeFound)    { $installArgs += ' --no-claude-code'    }

$psi                       = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName              = $ExePath
$psi.Arguments             = $installArgs
$psi.UseShellExecute       = $false
$psi.CreateNoWindow        = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$p = [System.Diagnostics.Process]::Start($psi)
$stdoutTask = $p.StandardOutput.ReadToEndAsync()
$stderrTask = $p.StandardError.ReadToEndAsync()
$p.WaitForExit()
$null = $stdoutTask.Result
$null = $stderrTask.Result

if ($p.ExitCode -ne 0) {
    Write-Host "FAIL  Registration failed (exit $($p.ExitCode))." -ForegroundColor Red
    Write-Host '      Run mcpbus --install manually for details.' -ForegroundColor DarkGray
    exit 1
}

if ($claudeDesktopFound) { Write-Host '  Claude Desktop  done' -ForegroundColor Green }
if ($claudeCodeFound)    { Write-Host '  Claude Code     done' -ForegroundColor Green }

Write-Host ''
Write-Host 'Done. Restart Claude to activate mcpbus.' -ForegroundColor Green
Write-Host ''
