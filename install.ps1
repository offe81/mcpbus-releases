#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ReleaseUrl = 'https://api.github.com/repos/offe81/mcpbus-releases/releases/latest'
$InstallDir = Join-Path (Join-Path $env:LOCALAPPDATA 'mcpbus') 'bin'
$ExePath    = Join-Path $InstallDir 'mcpbus.exe'

Clear-Host
Write-Host ''
Write-Host 'Mcpbus' -ForegroundColor White -NoNewline

# Fetch latest release

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

# Download

Write-Host 'Downloading...' -ForegroundColor DarkGray
try {
    $null = New-Item -ItemType Directory -Force -Path $InstallDir
    Add-Type -AssemblyName System.Net.Http

    # Stream the download ourselves so we can draw a real percent bar. PowerShell's built-in
    # Invoke-WebRequest progress is also why it felt slow - its rendering throttles the
    # transfer. This loop is both quieter and faster.
    $client = New-Object System.Net.Http.HttpClient
    $client.DefaultRequestHeaders.Add('User-Agent', 'mcpbus-installer')
    $resp = $client.GetAsync($asset.browser_download_url,
        [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    $resp.EnsureSuccessStatusCode() | Out-Null

    $total     = $resp.Content.Headers.ContentLength
    $stream    = $resp.Content.ReadAsStreamAsync().Result
    $out       = [System.IO.File]::Create($ExePath)
    $buffer    = New-Object byte[] 81920
    $totalRead = 0
    $lastPct   = -1
    # Build the bar glyphs at runtime from code points. The script is fetched via irm|iex and
    # decoded as Latin1 (the host serves it as octet-stream), so literal block characters in the
    # source would arrive mangled. U+2588/U+2591 also exist in the legacy OEM code page, so they
    # render in both classic conhost and modern UTF-8 terminals.
    $cFull     = [string][char]0x2588
    $cLight    = [string][char]0x2591
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $out.Write($buffer, 0, $read)
            $totalRead += $read
            if ($total) {
                $pct = [int](($totalRead / $total) * 100)
                if ($pct -ne $lastPct) {
                    $lastPct = $pct
                    $filled  = [int]($pct / 5)
                    $bar     = ($cFull * $filled) + ($cLight * (20 - $filled))
                    $mb      = '{0:N1} / {1:N1} MB' -f ($totalRead / 1MB), ($total / 1MB)
                    Write-Host ("`r  [{0}] {1,3}%   {2}" -f $bar, $pct, $mb) -NoNewline -ForegroundColor DarkGray
                }
            } else {
                Write-Host ("`r  {0:N1} MB downloaded" -f ($totalRead / 1MB)) -NoNewline -ForegroundColor DarkGray
            }
        }
    } finally {
        $out.Dispose(); $stream.Dispose(); $resp.Dispose(); $client.Dispose()
    }
    Write-Host ''
} catch {
    Write-Host ''
    Write-Host "FAIL  Download failed: $_" -ForegroundColor Red
    exit 1
}
Write-Host 'Download complete.' -ForegroundColor Green
Write-Host ''

# Detect installed Claude clients

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

# Register

Write-Host 'Registering...' -ForegroundColor DarkGray

$installArgs = '--setup --chained'
if (-not $claudeDesktopFound) { $installArgs += ' --no-claude-desktop' }
if (-not $claudeCodeFound)    { $installArgs += ' --no-claude-code'    }

$psi                        = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = $ExePath
$psi.Arguments              = $installArgs
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
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
    Write-Host '      Run mcpbus --setup manually for details.' -ForegroundColor DarkGray
    exit 1
}

if ($claudeDesktopFound) { Write-Host '  Claude Desktop  done' -ForegroundColor Green }
if ($claudeCodeFound)    { Write-Host '  Claude Code     done' -ForegroundColor Green }

# Activate (device-code). Runs interactively: shows the code, opens the browser, polls.
# Skips itself if a valid license already exists (mcpbus --activate handles that). A non-zero
# exit (user abandoned) does not stop the script - setup already succeeded and the wall in
# Claude is the backstop.
Write-Host ''
Write-Host 'Activating...' -ForegroundColor DarkGray
# mcpbus.exe is a GUI-subsystem binary, so PowerShell's call operator (&) does NOT wait for it -
# the script would race ahead to the config prompt mid-activation. -NoNewWindow keeps the
# device-code flow inline in this console; -Wait blocks until the exe exits.
Start-Process -FilePath $ExePath -ArgumentList '--activate' -NoNewWindow -Wait

# Offer the config UI. Same prompt as the double-click menu; Enter = yes.
Write-Host ''
$ans = Read-Host 'Open config UI now? [Y/n]'
if ($ans -eq '' -or $ans -match '^(y|yes)$') {
    Start-Process -FilePath $ExePath -ArgumentList '--config'
}

Write-Host ''
Write-Host 'Done. If Claude is running, run /mcp to reconnect (or restart Claude).' -ForegroundColor Green
Write-Host ''
