# End-to-end tests for AnySnap on Windows (run by GitHub Actions on a real Windows desktop).
# Windows PowerShell 5.1 (STA, for clipboard checks):  powershell -File e2e.ps1 -Exe path\AnySnap.exe -Out results
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = 'Continue'
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$work = Join-Path $env:RUNNER_TEMP 'anysnap-e2e'
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:ANYSNAP_HOME = Join-Path $work 'snapshots'

Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class W {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static void Front(IntPtr h) {
        keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero);
        ShowWindow(h, 9); SetForegroundWindow(h);
    }
    public static void LeftRightCtrl() {
        keybd_event(0xA2, 0x1D, 0, UIntPtr.Zero);        // left ctrl down
        keybd_event(0xA3, 0x1D, 1, UIntPtr.Zero);        // right ctrl down (extended)
        System.Threading.Thread.Sleep(80);
        keybd_event(0xA3, 0x1D, 1 | 2, UIntPtr.Zero);
        keybd_event(0xA2, 0x1D, 2, UIntPtr.Zero);
    }
    public static uint ForegroundPid() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; }
}
"@

$results = New-Object System.Collections.ArrayList
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $status = if ($ok) { 'PASS' } else { 'FAIL' }
    [void]$results.Add("$status  $name  $detail")
    Write-Host "$status  $name  $detail"
}

function Invoke-Mcp([object[]]$requests, [string]$tag) {
    $in = Join-Path $work "$tag.in.jsonl"
    $outFile = Join-Path $work "$tag.out.jsonl"
    $err = Join-Path $work "$tag.err.txt"
    $lines = $requests | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }
    [System.IO.File]::WriteAllLines($in, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    $p = Start-Process -FilePath $Exe -ArgumentList 'mcp' -RedirectStandardInput $in -RedirectStandardOutput $outFile `
        -RedirectStandardError $err -NoNewWindow -PassThru
    if (-not $p.WaitForExit(90000)) { $p.Kill(); Write-Host "MCP $tag timed out" }
    Copy-Item $outFile (Join-Path $Out "$tag.mcp-output.jsonl") -ErrorAction SilentlyContinue
    $text = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
    $resp = @{}
    foreach ($l in ($text -split "`n")) {
        if ($l.Trim().Length -eq 0) { continue }
        try { $o = $l | ConvertFrom-Json; $resp[[int]$o.id] = $o } catch { Write-Host "bad json line: $l" }
    }
    return $resp
}

$init = @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'e2e'; version = '1' } } }
$initialized = @{ jsonrpc = '2.0'; method = 'notifications/initialized' }

function Capture-Mcp([string]$app, [string]$tag) {
    $call = @{ jsonrpc = '2.0'; id = 2; method = 'tools/call'; params = @{ name = 'capture_window'; arguments = @{ app = $app; max_chars = 200000 } } }
    $r = Invoke-Mcp @($init, $initialized, $call) $tag
    $res = $r[2]
    $text = ''
    if ($res -and $res.result) {
        foreach ($c in $res.result.content) {
            if ($c.type -eq 'text') { $text = $c.text }
            if ($c.type -eq 'image') { [System.IO.File]::WriteAllBytes((Join-Path $Out "$tag.jpg"), [Convert]::FromBase64String($c.data)) }
        }
    } elseif ($res) { $text = ($res | ConvertTo-Json -Depth 5) }
    [System.IO.File]::WriteAllText((Join-Path $Out "$tag.context.md"), $text, (New-Object System.Text.UTF8Encoding($false)))
    return $text
}

function Wait-Window([string]$processName, [int]$seconds = 20) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        $p = Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { return $p }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

Write-Host "OS: $([Environment]::OSVersion.VersionString)  user interactive: $([Environment]::UserInteractive)"

# 1. MCP introspection
$r = Invoke-Mcp @($init, $initialized, @{ jsonrpc = '2.0'; id = 2; method = 'tools/list' }) 'introspection'
Check 'mcp initialize' ($r[1].result.serverInfo.name -eq 'anysnap') ($r[1].result.serverInfo | ConvertTo-Json -Compress)
$names = @($r[2].result.tools | ForEach-Object { $_.name })
Check 'mcp tools/list' ($names.Count -eq 4) ($names -join ',')

# 2. Notepad: long file, the last line is scrolled out of view
$txt = Join-Path $work 'anysnap-notepad-test.txt'
$body = (1..400 | ForEach-Object { 'line {0:D3} alpha beta gamma' -f $_ }) -join "`r`n"
[System.IO.File]::WriteAllText($txt, "FIRST-LINE-MARKER`r`n$body`r`nEND-OF-FILE-MARKER`r`n")
Start-Process notepad.exe -ArgumentList "`"$txt`""
$np = Wait-Window 'notepad'
Start-Sleep -Seconds 3
Check 'notepad started' ($np -ne $null) ($np.MainWindowTitle)
$t = Capture-Mcp 'notepad' 'notepad'
Check 'notepad: first line' ($t -match 'FIRST-LINE-MARKER')
Check 'notepad: off-screen last line' ($t -match 'END-OF-FILE-MARKER') ("chars=" + $t.Length)
Check 'notepad: screenshot' (Test-Path (Join-Path $Out 'notepad.jpg'))

# 3. File Explorer with a selected file
$folder = Join-Path $work 'Explorer Test Folder'
New-Item -ItemType Directory -Force -Path $folder | Out-Null
'a' | Set-Content (Join-Path $folder 'alpha.txt')
'b' | Set-Content (Join-Path $folder 'selected-file.txt')
'c' | Set-Content (Join-Path $folder 'zeta.txt')
Start-Process explorer.exe -ArgumentList "/select,`"$(Join-Path $folder 'selected-file.txt')`""
Start-Sleep -Seconds 6
try {
    $shell = New-Object -ComObject Shell.Application
    foreach ($w in @($shell.Windows())) {
        try {
            if ($w.Document.Folder.Self.Path -eq $folder) {
                $item = $w.Document.Folder.ParseName('selected-file.txt')
                $w.Document.SelectItem($item, 1 + 4 + 8 + 16)   # select, deselect others, ensure visible, focus
                Write-Host "selected via Shell: $($item.Path)"
            }
        } catch { }
    }
} catch { Write-Host "shell select failed: $_" }
Start-Sleep -Seconds 1
$t = Capture-Mcp 'explorer' 'explorer'
Check 'explorer: folder path' ($t.Contains($folder))
Check 'explorer: selected file path' ($t.Contains((Join-Path $folder 'selected-file.txt')))
Check 'explorer: file list text' ($t -match 'zeta')

# 4. Browsers: long page, marker at the bottom
$html = Join-Path $work 'anysnap-browser-test.html'
$rows = (1..300 | ForEach-Object { "<p>Paragraph $_ of the AnySnap browser test page.</p>" }) -join "`n"
[System.IO.File]::WriteAllText($html, "<!doctype html><html><head><meta charset='utf-8'><title>AnySnap Browser Test</title></head><body><h1>TOP-OF-PAGE-MARKER</h1>$rows<footer>BOTTOM-OF-PAGE-MARKER</footer></body></html>")
$url = ([Uri]$html).AbsoluteUri
$browsers = @(
    @{ name = 'msedge'; exe = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" },
    @{ name = 'chrome'; exe = "$env:ProgramFiles\Google\Chrome\Application\chrome.exe" }
)
foreach ($b in $browsers) {
    if (-not (Test-Path $b.exe)) { Check "$($b.name): installed" $false $b.exe; continue }
    $profileDir = Join-Path $work "$($b.name)-profile"
    Start-Process $b.exe -ArgumentList @("--user-data-dir=`"$profileDir`"", '--no-first-run', '--no-default-browser-check', '--new-window', $url, 'about:blank')
    Start-Sleep -Seconds 10
    $p = Wait-Window $b.name
    if ($p) { [W]::Front($p.MainWindowHandle); Start-Sleep -Seconds 2 }
    $t = Capture-Mcp $b.name $b.name
    Check "$($b.name): top of page" ($t -match 'TOP-OF-PAGE-MARKER')
    Check "$($b.name): off-screen bottom of page" ($t -match 'BOTTOM-OF-PAGE-MARKER') ("chars=" + $t.Length)
    Check "$($b.name): URL" ($t -match 'anysnap-browser-test\.html')
    Check "$($b.name): tabs listed" ($t -match 'Tabs in this browser window')
    Get-Process -Name $b.name -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}

# 5. Tray app + hotkey (left Ctrl + right Ctrl) on Notepad
$trayHome = Join-Path $work 'tray-snapshots'
$env:ANYSNAP_HOME = $trayHome
Start-Process -FilePath $Exe
Start-Sleep -Seconds 4
$tray = Get-Process -Name 'AnySnap' -ErrorAction SilentlyContinue
Check 'tray app running' ($tray -ne $null)
$np = Wait-Window 'notepad'
if ($np) { [W]::Front($np.MainWindowHandle); Start-Sleep -Seconds 1 }
Check 'notepad in front before hotkey' ([W]::ForegroundPid() -eq $np.Id) ("fg pid=" + [W]::ForegroundPid())
[System.Windows.Forms.Clipboard]::Clear()
[W]::LeftRightCtrl()
Start-Sleep -Seconds 8
$snaps = @(Get-ChildItem $trayHome -Directory -ErrorAction SilentlyContinue)
Check 'hotkey: snapshot written' ($snaps.Count -ge 1) ("count=" + $snaps.Count)
if ($snaps.Count -ge 1) {
    $ctx = Get-Content -Raw -Encoding UTF8 (Join-Path $snaps[0].FullName 'context.md')
    Copy-Item (Join-Path $snaps[0].FullName 'context.md') (Join-Path $Out 'hotkey.context.md')
    Copy-Item (Join-Path $snaps[0].FullName 'screenshot.png') (Join-Path $Out 'hotkey.png') -ErrorAction SilentlyContinue
    Check 'hotkey: captured notepad text' ($ctx -match 'END-OF-FILE-MARKER')
}
Check 'hotkey: screenshot on clipboard (Claude not running -> copied)' ([System.Windows.Forms.Clipboard]::ContainsImage())

# 6. CLI
$list = & $Exe list 5 | Out-String
Check 'cli list' ($list.Length -gt 0) ($list.Trim() -split "`n" | Select-Object -First 1)

# 7. Desktop screenshot for a visual check of the tray icon / state
try {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bmp.Save((Join-Path $Out 'desktop.png'), [System.Drawing.Imaging.ImageFormat]::Png)
} catch { Write-Host "desktop screenshot failed: $_" }

Get-Process -Name 'AnySnap' -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name 'notepad' -ErrorAction SilentlyContinue | Stop-Process -Force

$results | Set-Content -Encoding UTF8 (Join-Path $Out 'summary.txt')
$failed = @($results | Where-Object { $_ -like 'FAIL*' }).Count
Write-Host "`n$($results.Count - $failed) passed, $failed failed"
exit $failed
