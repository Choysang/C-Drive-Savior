# clean.ps1 - C Drive Savior tier-1 (GREEN) cache cleaner. PowerShell 5.1 / 7.
# Default is DRY-RUN (measures, deletes nothing). Add -Execute to actually clean.
# Writes a JSON action log that report.ps1 consumes.
# ASCII-only source on purpose (survives any PS host encoding).
[CmdletBinding()]
param(
    [switch]$Execute,                 # without this: dry-run
    [string[]]$Include,               # only these item ids
    [string[]]$Exclude,               # skip these item ids
    [switch]$SkipProcessCheck,        # clean even if owning processes run (not recommended)
    [string]$LogDir = "$env:USERPROFILE\c-drive-savior"
)

$ErrorActionPreference = 'SilentlyContinue'

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Format-GB([long]$b) { [math]::Round($b / 1GB, 2) }
function Get-TreeBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    [long]$t = 0
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { if (-not $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $t += $_.Length } }
    return $t
}
function Expand-Glob([string]$Pattern) {
    # supports * segments (e.g. Chrome profiles). Returns existing literal paths.
    if ($Pattern -notlike '*[*]*') { if (Test-Path -LiteralPath $Pattern) { return @($Pattern) } else { return @() } }
    $out = @()
    Resolve-Path -Path $Pattern -ErrorAction SilentlyContinue | ForEach-Object { $out += $_.Path }
    return $out
}

# --- catalog -----------------------------------------------------------------
$LOCAL = $env:LOCALAPPDATA
$Catalog = @(
    @{id='temp-user';    admin=$false; procs=@();                    label='User temp (%TEMP%)';                 paths=@("$env:TEMP")}
    @{id='crashdumps';   admin=$false; procs=@();                    label='App crash dumps';                    paths=@("$LOCAL\CrashDumps")}
    @{id='dxcache';      admin=$false; procs=@();                    label='DirectX shader cache';               paths=@("$LOCAL\D3DSCache")}
    @{id='thumbcache';   admin=$false; procs=@();                    label='Explorer thumbnail cache';           paths=@("$LOCAL\Microsoft\Windows\Explorer")}
    @{id='chrome-cache'; admin=$false; procs=@('chrome');            label='Chrome caches';                      paths=@(
        "$LOCAL\Google\Chrome\User Data\*\Cache", "$LOCAL\Google\Chrome\User Data\*\Code Cache",
        "$LOCAL\Google\Chrome\User Data\*\GPUCache", "$LOCAL\Google\Chrome\User Data\optimization_guide_model_store",
        "$LOCAL\Google\Chrome\User Data\*\Service Worker\CacheStorage")}
    @{id='edge-cache';   admin=$false; procs=@('msedge');            label='Edge caches';                        paths=@(
        "$LOCAL\Microsoft\Edge\User Data\*\Cache", "$LOCAL\Microsoft\Edge\User Data\*\Code Cache",
        "$LOCAL\Microsoft\Edge\User Data\*\GPUCache")}
    @{id='firefox-cache';admin=$false; procs=@('firefox');           label='Firefox cache2';                     paths=@("$LOCAL\Mozilla\Firefox\Profiles\*\cache2")}
    @{id='npm';          admin=$false; procs=@('node');              label='npm cache';                          paths=@("$LOCAL\npm-cache")}
    @{id='pnpm';         admin=$false; procs=@('node');              label='pnpm cache';                         paths=@("$LOCAL\pnpm-cache")}
    @{id='yarn';         admin=$false; procs=@('node');              label='Yarn cache';                         paths=@("$LOCAL\Yarn\Cache")}
    @{id='pip';          admin=$false; procs=@();                    label='pip cache';                          paths=@("$LOCAL\pip\Cache")}
    @{id='uv';           admin=$false; procs=@();                    label='uv cache';                           paths=@("$LOCAL\uv")}
    @{id='playwright';   admin=$false; procs=@('chrome','msedge');   label='Playwright browsers';                paths=@("$LOCAL\ms-playwright")}
    @{id='puppeteer';    admin=$false; procs=@();                    label='Puppeteer browsers';                 paths=@("$LOCAL\puppeteer", "$env:USERPROFILE\.cache\puppeteer")}
    @{id='node-gyp';     admin=$false; procs=@();                    label='node-gyp headers';                   paths=@("$LOCAL\node-gyp")}
    @{id='go-build';     admin=$false; procs=@();                    label='Go build cache';                     paths=@("$LOCAL\go-build")}
    @{id='nuget';        admin=$false; procs=@();                    label='NuGet package cache';                paths=@("$env:USERPROFILE\.nuget\packages")}
    @{id='gradle';       admin=$false; procs=@('java');              label='Gradle caches';                      paths=@("$env:USERPROFILE\.gradle\caches")}
    @{id='squirrel';     admin=$false; procs=@();                    label='Squirrel updater temp';              paths=@("$LOCAL\SquirrelTemp")}
    @{id='wer-user';     admin=$false; procs=@();                    label='Error reports (user)';               paths=@("$LOCAL\Microsoft\Windows\WER")}
    # ---- admin items ----
    @{id='temp-windows'; admin=$true;  procs=@();                    label='Windows temp';                       paths=@("$env:SystemRoot\Temp")}
    @{id='wu-cache';     admin=$true;  procs=@();                    label='Windows Update download cache';      paths=@("$env:SystemRoot\SoftwareDistribution\Download")}
    @{id='delivery-opt'; admin=$true;  procs=@();                    label='Delivery Optimization cache';        paths=@()}
    @{id='minidump';     admin=$true;  procs=@();                    label='Kernel minidumps';                   paths=@("$env:SystemRoot\Minidump")}
    @{id='memdump';      admin=$true;  procs=@();                    label='MEMORY.DMP';                         paths=@("$env:SystemRoot\MEMORY.DMP")}
    @{id='wer-system';   admin=$true;  procs=@();                    label='Error reports (system)';             paths=@("$env:ProgramData\Microsoft\Windows\WER\ReportQueue", "$env:ProgramData\Microsoft\Windows\WER\ReportArchive")}
    @{id='recyclebin';   admin=$true;  procs=@();                    label='Recycle Bin';                        paths=@()}
)
# NOT in catalog by design: WinSxS/DISM (health gate, pitfalls.md #6), Package Cache /
# Windows Installer (YELLOW), $WINDOWS.~BT (rollback consent), whole browser profiles.

$elevated = Test-Elevated
$mode = 'dry-run'; if ($Execute) { $mode = 'execute' }
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$cBefore = (Get-PSDrive C).Free

Write-Host ''
Write-Host ("=== C Drive Savior clean ({0}) elevated={1} ===" -f $mode, $elevated)
if (-not $Execute) { Write-Host '[i] DRY-RUN: measuring only. Re-run with -Execute to clean.' }

$results = New-Object System.Collections.Generic.List[object]
foreach ($item in $Catalog) {
    if ($Include -and ($Include -notcontains $item.id)) { continue }
    if ($Exclude -and ($Exclude -contains $item.id))   { continue }

    $entry = [ordered]@{
        id = $item.id; label = $item.label; action = 'clean'
        freed_bytes = [long]0; status = ''; detail = ''
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    }

    if ($item.admin -and -not $elevated) {
        $entry.status = 'skipped-needs-admin'
        $results.Add([pscustomobject]$entry); continue
    }
    $running = @()
    foreach ($p in $item.procs) { if (Get-Process -Name $p -ErrorAction SilentlyContinue) { $running += $p } }
    if ($running.Count -gt 0 -and -not $SkipProcessCheck -and $Execute) {
        $entry.status = 'skipped-process-running'; $entry.detail = ($running -join ',')
        $results.Add([pscustomobject]$entry)
        Write-Host ("  SKIP {0,-18} process running: {1}" -f $item.id, $entry.detail)
        continue
    }

    # measure
    $paths = @()
    foreach ($p in $item.paths) { $paths += Expand-Glob $p }
    [long]$before = 0
    foreach ($p in $paths) { $before += Get-TreeBytes $p }
    if ($item.id -eq 'recyclebin') { $before = Get-TreeBytes "$env:SystemDrive\`$Recycle.Bin" }

    if (-not $Execute) {
        $entry.status = 'dry-run'; $entry.freed_bytes = $before
        if ($running.Count -gt 0) { $entry.detail = ('process running: {0}' -f ($running -join ',')) }
        $results.Add([pscustomobject]$entry)
        Write-Host ("  PLAN {0,-18} {1,9} GB  {2} {3}" -f $item.id, (Format-GB $before), $item.label, $entry.detail)
        continue
    }

    # execute
    switch ($item.id) {
        'wu-cache' {
            Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
            foreach ($p in $paths) { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
            Start-Service wuauserv, bits -ErrorAction SilentlyContinue
        }
        'delivery-opt' {
            if (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue) { Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue }
        }
        'recyclebin' { Clear-RecycleBin -Force -ErrorAction SilentlyContinue }
        'thumbcache' {
            Get-ChildItem -LiteralPath "$LOCAL\Microsoft\Windows\Explorer" -Filter 'thumbcache_*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath "$LOCAL\Microsoft\Windows\Explorer" -Filter 'iconcache_*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        'memdump' { Remove-Item -LiteralPath "$env:SystemRoot\MEMORY.DMP" -Force -ErrorAction SilentlyContinue }
        default {
            foreach ($p in $paths) {
                if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
                else { Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
    }

    [long]$after = 0
    foreach ($p in $paths) { $after += Get-TreeBytes $p }
    if ($item.id -eq 'recyclebin') { $after = Get-TreeBytes "$env:SystemDrive\`$Recycle.Bin" }
    $freed = $before - $after; if ($freed -lt 0) { $freed = [long]0 }
    $entry.freed_bytes = $freed
    $entry.status = 'cleaned'
    if ($after -gt 1MB) { $entry.status = 'partial'; $entry.detail = ('{0:N2} GB locked/remaining' -f (Format-GB $after)) }
    $results.Add([pscustomobject]$entry)
    Write-Host ("  {0,-7} {1,-18} freed {2,9} GB  {3}" -f $entry.status.ToUpper(), $item.id, (Format-GB $freed), $entry.detail)
}

$cAfter = (Get-PSDrive C).Free
$totalFreed = ($results | Where-Object { $_.status -in 'cleaned','partial' } | Measure-Object -Property freed_bytes -Sum).Sum
if (-not $totalFreed) { $totalFreed = [long]0 }
$planned = ($results | Where-Object status -eq 'dry-run' | Measure-Object -Property freed_bytes -Sum).Sum
if (-not $planned) { $planned = [long]0 }

Write-Host ''
if ($Execute) {
    Write-Host ("TOTAL freed (per-item measured): {0} GB" -f (Format-GB $totalFreed))
    Write-Host ("C: free {0} GB -> {1} GB (disk-level delta {2} GB)" -f (Format-GB $cBefore), (Format-GB $cAfter), (Format-GB ($cAfter - $cBefore)))
} else {
    Write-Host ("PLANNED reclaim if executed: ~{0} GB across {1} items" -f (Format-GB $planned), (@($results | Where-Object status -eq 'dry-run').Count))
}
$skippedAdmin = @($results | Where-Object status -eq 'skipped-needs-admin')
if ($skippedAdmin.Count -gt 0) {
    Write-Host ("[i] {0} admin items skipped. Run them elevated:" -f $skippedAdmin.Count)
    Write-Host ("    Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy','Bypass','-File','{0}','-Execute','-Include','{1}'" -f $PSCommandPath, (($skippedAdmin | ForEach-Object { $_.id }) -join ','))
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = [pscustomobject]@{
    schema = 1; tool = 'clean.ps1'; mode = $mode
    started = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'); elevated = $elevated
    c_free_before_gb = Format-GB $cBefore; c_free_after_gb = Format-GB $cAfter
    total_freed_bytes = [long]$totalFreed; planned_bytes = [long]$planned
    items = $results
}
$logPath = Join-Path $LogDir ("actions-clean-{0}-{1}.json" -f $mode, $stamp)
[IO.File]::WriteAllText($logPath, ($log | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $true))
Write-Host ("log: {0}" -f $logPath)
