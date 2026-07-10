# scan.ps1 - C Drive Savior read-only scanner + panel (PowerShell 5.1 / 7 compatible)
# Read-only: sizes, lists, metadata. Never deletes/moves anything.
# Outputs: console panel, JSON baseline, HTML dashboard.
# ponytail: single-threaded walk; parallelize only if this proves too slow in practice.
[CmdletBinding()]
param(
    [double]$ThresholdGB = 1.0,
    [int]$MaxDepth = 4,
    [string]$OutDir = "$env:USERPROFILE\c-drive-savior",
    [switch]$AnalyzeWinSxS,   # runs DISM AnalyzeComponentStore (admin, ~1 min)
    [switch]$OpenReport,
    [switch]$NoHtml
)

$ErrorActionPreference = 'SilentlyContinue'
$script:Threshold = [long]($ThresholdGB * 1GB)
$script:Rows = New-Object System.Collections.Generic.List[object]
$script:WalkErrors = 0

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-GB([long]$Bytes) { [math]::Round($Bytes / 1GB, 2) }

# --- classification ---------------------------------------------------------
$SkillRoot = Split-Path $PSScriptRoot -Parent
$ClassificationPath = Join-Path $SkillRoot 'config\classification.json'
$Classification = Get-Content -Raw -LiteralPath $ClassificationPath | ConvertFrom-Json
$RedPrefixes = @($Classification.protected_prefixes | ForEach-Object {
    (Join-Path $env:SystemDrive ($_.Replace('/', [IO.Path]::DirectorySeparatorChar))).ToLowerInvariant()
})
$GreenNames = @{}
foreach ($n in $Classification.green_names) { $GreenNames[$n] = $true }
$YellowNames = @{}
foreach ($n in $Classification.yellow_names) { $YellowNames[$n] = $true }
$MoveNames = @{}
foreach ($n in $Classification.move_names) { $MoveNames[$n] = $true }
$SpecialCases = @($Classification.special_cases)

function Get-Tier([string]$Path) {
    $lower = $Path.ToLowerInvariant()
    $name  = [IO.Path]::GetFileName($Path).ToLowerInvariant()
    foreach ($p in $RedPrefixes) {
        if ($lower.StartsWith($p)) { return @('RED', 'System/install area. Official tools or uninstaller only; never hand-delete.') }
    }
    foreach ($case in $SpecialCases) {
        if (@($case.names) -contains $name) { return @($case.tier, $case.note) }
    }
    if ($MoveNames.ContainsKey($name)) { return @('MOVE', 'User folder. Good candidate to relocate to D: (relocation-guide).') }
    if ($GreenNames.ContainsKey($name)) { return @('GREEN', 'Rebuildable cache/temp. Deletable after closing the owning app.') }
    if ($YellowNames.ContainsKey($name) -or $name.StartsWith('$winreagent')) {
        return @('YELLOW', 'Needs confirmation: may affect repair/uninstall/rollback or contains user data.')
    }
    if ($name -like '*cache*' -or $name -like '*temp*') { return @('GREEN', 'Cache-like name; verify owning app, then deletable.') }
    if ($lower -like '*\appdata\*' -or $lower -like 'c:\programdata\*') {
        return @('YELLOW', 'App data area: inspect subfolders; delete caches only, never account data/DBs.')
    }
    return @('YELLOW', 'Large item; needs a human decision.')
}

# --- single-pass sizing walk -------------------------------------------------
$SkipRoots = @('c:\windows\winsxs', 'c:\$recycle.bin', 'c:\system volume information', 'c:\windows\servicing')

function Walk([string]$Path, [int]$Depth) {
    # returns tree size in bytes; records rows >= threshold up to MaxDepth
    [long]$sum = 0
    $dirs = $null; $files = $null
    try { $dirs = [IO.Directory]::GetDirectories($Path) } catch { $script:WalkErrors++; return 0 }
    try { $files = [IO.Directory]::GetFiles($Path) } catch { $files = @(); $script:WalkErrors++ }
    foreach ($f in $files) {
        try {
            $fi = New-Object IO.FileInfo $f
            if (-not ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $sum += $fi.Length }
        } catch { $script:WalkErrors++ }
    }
    foreach ($d in $dirs) {
        $dl = $d.ToLowerInvariant()
        if ($SkipRoots -contains $dl) { continue }
        try {
            $attr = [IO.File]::GetAttributes($d)
            if ($attr -band [IO.FileAttributes]::ReparsePoint) { continue }
        } catch { $script:WalkErrors++; continue }
        $childSize = Walk $d ($Depth + 1)
        if ($childSize -ge $script:Threshold -and ($Depth + 1) -le $MaxDepth) {
            $tier = Get-Tier $d
            $script:Rows.Add([pscustomobject]@{
                path = $d; bytes = $childSize; gb = Format-GB $childSize
                tier = $tier[0]; note = $tier[1]; depth = $Depth + 1
            })
        }
        $sum += $childSize
    }
    return $sum
}

# --- hidden consumers --------------------------------------------------------
function Get-HiddenConsumers([bool]$Elevated) {
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($spec in @(
            @{id='pagefile';  label='pagefile.sys (virtual memory)';  path="$env:SystemDrive\pagefile.sys"},
            @{id='hiberfil';  label='hiberfil.sys (hibernation)';     path="$env:SystemDrive\hiberfil.sys"},
            @{id='swapfile';  label='swapfile.sys';                   path="$env:SystemDrive\swapfile.sys"},
            @{id='memdump';   label='MEMORY.DMP (crash dump)';        path="$env:SystemRoot\MEMORY.DMP"})) {
        $fi = Get-Item -LiteralPath $spec.path -Force -ErrorAction SilentlyContinue
        if ($fi) { $items.Add([pscustomobject]@{id=$spec.id; label=$spec.label; bytes=[long]$fi.Length; note=''}) }
    }
    $rb = [long]0
    Get-ChildItem -LiteralPath "$env:SystemDrive\`$Recycle.Bin" -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { if (-not $_.PSIsContainer) { $rb += $_.Length } }
    $items.Add([pscustomobject]@{id='recyclebin'; label='Recycle Bin'; bytes=$rb; note='Clear-RecycleBin frees it'})

    $sd = [long]0
    Get-ChildItem -LiteralPath "$env:SystemRoot\SoftwareDistribution\Download" -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { if (-not $_.PSIsContainer) { $sd += $_.Length } }
    $items.Add([pscustomobject]@{id='wucache'; label='Windows Update cache'; bytes=$sd; note='stop wuauserv+bits before cleaning'})

    if ($Elevated) {
        $vss = Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue
        if ($vss) {
            $used = ($vss | Measure-Object -Property UsedSpace -Sum).Sum
            $items.Add([pscustomobject]@{id='vss'; label='System Restore / VSS'; bytes=[long]$used; note='vssadmin resize shadowstorage to cap'})
        }
        if ($AnalyzeWinSxS) {
            $dism = & Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>$null
            $line = ($dism | Select-String 'Actual Size of Component Store|组件存储的实际大小' | Select-Object -First 1)
            if ($line) { $items.Add([pscustomobject]@{id='winsxs'; label='WinSxS (true size, DISM)'; bytes=0; note=($line.ToString().Trim())}) }
        }
    } else {
        $items.Add([pscustomobject]@{id='vss'; label='System Restore / VSS'; bytes=-1; note='needs admin to measure (vssadmin/CIM)'})
    }
    $edb = Get-Item -LiteralPath "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb" -Force -ErrorAction SilentlyContinue
    if ($edb) { $items.Add([pscustomobject]@{id='searchindex'; label='Search index (Windows.edb)'; bytes=[long]$edb.Length; note=''}) }
    return $items
}

# --- main --------------------------------------------------------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
$elevated = Test-Elevated
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Write-Host ''
Write-Host '=== C Drive Savior scan (read-only) ==='
if (-not $elevated) { Write-Host '[i] not elevated: VSS/WinSxS numbers unavailable; some dirs will be skipped (counted as errors).' }

$drives = @()
foreach ($d in Get-PSDrive -PSProvider FileSystem) {
    if ($null -ne $d.Free -and ($d.Used + $d.Free) -gt 0 -and $d.Name.Length -eq 1) {
        $drives += [pscustomobject]@{
            letter = $d.Name; total_gb = Format-GB ($d.Used + $d.Free)
            used_gb = Format-GB $d.Used; free_gb = Format-GB $d.Free
            used_pct = [math]::Round($d.Used / ($d.Used + $d.Free) * 100, 1)
        }
    }
}
$c = $drives | Where-Object letter -eq 'C'

Write-Host ("scanning {0} (threshold {1} GB, depth {2}) ... this can take minutes" -f $env:SystemDrive, $ThresholdGB, $MaxDepth)
$rootFiles = [long]0
Get-ChildItem -LiteralPath "$env:SystemDrive\" -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $rootFiles += $_.Length }
[long]$scanned = $rootFiles
foreach ($top in [IO.Directory]::GetDirectories("$env:SystemDrive\")) {
    $tl = $top.ToLowerInvariant()
    if ($SkipRoots -contains $tl) { continue }
    try { $attr = [IO.File]::GetAttributes($top); if ($attr -band [IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
    Write-Host ("  sizing {0} ..." -f $top)
    $sz = Walk $top 1
    if ($sz -ge $script:Threshold) {
        $tier = Get-Tier $top
        $script:Rows.Add([pscustomobject]@{ path=$top; bytes=$sz; gb=Format-GB $sz; tier=$tier[0]; note=$tier[1]; depth=1 })
    }
    $scanned += $sz
}
$hidden = Get-HiddenConsumers $elevated
$hiddenSum = ($hidden | Where-Object { $_.bytes -gt 0 } | Measure-Object -Property bytes -Sum).Sum
if (-not $hiddenSum) { $hiddenSum = [long]0 }
$usedBytes = [long]($c.used_gb * 1GB)
$unaccounted = $usedBytes - $scanned - $hiddenSum
if ($unaccounted -lt 0) { $unaccounted = [long]0 }

$rows = $script:Rows | Sort-Object bytes -Descending
# Exclusive attribution: subtract each row from its nearest ancestor row, then bucket
# exclusive bytes by tier - segments become mutually exclusive (no nested double count).
$byPath = @{}
foreach ($r in $rows) {
    $r | Add-Member -NotePropertyName exclusive_bytes -NotePropertyValue ([long]$r.bytes)
    $byPath[$r.path.ToLowerInvariant()] = $r
}
foreach ($r in $rows) {
    $p = [IO.Path]::GetDirectoryName($r.path)
    while ($p -and $p.Length -gt 3) {
        $k = $p.ToLowerInvariant()
        if ($byPath.ContainsKey($k)) { $byPath[$k].exclusive_bytes -= $r.bytes; break }
        $p = [IO.Path]::GetDirectoryName($p)
    }
}
$tierSums = @{}
foreach ($t in 'GREEN','YELLOW','RED','MOVE') {
    [long]$s = 0
    foreach ($r in $rows) { if ($r.tier -eq $t -and $r.exclusive_bytes -gt 0) { $s += $r.exclusive_bytes } }
    $tierSums[$t] = $s
}
$topRow = $rows | Select-Object -First 1
$insight = 'No item exceeded the threshold.'
if ($topRow) {
    $insight = ("Top consumer: {0} ({1} GB). Identified: cleanable caches (GREEN) ~{2} GB, movable to D: (MOVE) ~{3} GB, confirm-first (YELLOW) ~{4} GB; hidden system files {5} GB." -f `
        $topRow.path, $topRow.gb, (Format-GB $tierSums['GREEN']), (Format-GB $tierSums['MOVE']), (Format-GB $tierSums['YELLOW']), (Format-GB $hiddenSum))
}

# --- console panel -----------------------------------------------------------
Write-Host ''
Write-Host ('C: used {0}/{1} GB ({2}%)   free {3} GB' -f $c.used_gb, $c.total_gb, $c.used_pct, $c.free_gb)
$dDrive = $drives | Where-Object letter -eq 'D'
if ($dDrive) { Write-Host ('D: free {0}/{1} GB' -f $dDrive.free_gb, $dDrive.total_gb) }
$barLen = 40; $fill = [int]($c.used_pct / 100 * $barLen)
Write-Host ('[{0}{1}] {2}%' -f ('#' * $fill), ('-' * ($barLen - $fill)), $c.used_pct)
Write-Host ('Insight: ' + $insight)
Write-Host ''
Write-Host 'Hidden consumers (not visible to folder scans):'
foreach ($h in $hidden) {
    if ($h.bytes -ge 0) { Write-Host ('  {0,-34} {1,8} GB  {2}' -f $h.label, (Format-GB $h.bytes), $h.note) }
    else { Write-Host ('  {0,-34} {1,8}     {2}' -f $h.label, 'n/a', $h.note) }
}
Write-Host ('  {0,-34} {1,8} GB  scan gap (small files/ACL-denied/compression)' -f 'unaccounted', (Format-GB $unaccounted))
Write-Host ''
Write-Host ('{0,-6} {1,10}  {2}' -f 'TIER', 'SIZE(GB)', 'PATH')
foreach ($r in ($rows | Select-Object -First 45)) {
    Write-Host ('{0,-6} {1,10}  {2}{3}' -f $r.tier, $r.gb, ('  ' * ($r.depth - 1)), $r.path)
}
if ($rows.Count -gt 45) { Write-Host ("  ... {0} more rows in JSON/HTML" -f ($rows.Count - 45)) }

# --- JSON --------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$report = [pscustomobject]@{
    schema = 1
    generated_at = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    elevated = $elevated
    threshold_gb = $ThresholdGB
    scan_seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    walk_errors = $script:WalkErrors
    drives = $drives
    hidden = $hidden
    tier_sums_gb = [pscustomobject]@{
        GREEN = Format-GB $tierSums['GREEN']; YELLOW = Format-GB $tierSums['YELLOW']
        RED = Format-GB $tierSums['RED']; MOVE = Format-GB $tierSums['MOVE']
    }
    scanned_bytes = $scanned
    unaccounted_bytes = $unaccounted
    insight = $insight
    rows = $rows
}
$jsonPath = Join-Path $OutDir ("scan-{0}.json" -f $stamp)
[IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $true))

# --- HTML panel ---------------------------------------------------------------
$htmlPath = $null
if (-not $NoHtml) {
    $tierColor = @{ GREEN='var(--green)'; YELLOW='var(--yellow)'; RED='var(--red)'; MOVE='var(--move)' }
    $rowsHtml = New-Object Text.StringBuilder
    foreach ($r in $rows) {
        $indent = 14 * ($r.depth - 1)
        [void]$rowsHtml.AppendFormat('<tr><td><span class="pill" style="background:{0}">{1}</span></td><td class="num">{2:N2}</td><td style="padding-left:{3}px"><code>{4}</code></td><td class="note">{5}</td></tr>',
            $tierColor[$r.tier], $r.tier, $r.gb, $indent, [Net.WebUtility]::HtmlEncode($r.path), [Net.WebUtility]::HtmlEncode($r.note))
    }
    $hiddenHtml = New-Object Text.StringBuilder
    foreach ($h in $hidden) {
        $v = 'n/a'; if ($h.bytes -ge 0) { $v = ('{0:N2} GB' -f (Format-GB $h.bytes)) }
        [void]$hiddenHtml.AppendFormat('<tr><td>{0}</td><td class="num">{1}</td><td class="note">{2}</td></tr>',
            [Net.WebUtility]::HtmlEncode($h.label), $v, [Net.WebUtility]::HtmlEncode($h.note))
    }
    $totalUsed = [double]$c.used_gb
    function Seg([double]$gb, [double]$total) { if ($total -le 0) { return 0 } [math]::Round($gb / $total * 100, 2) }
    $segG = Seg (Format-GB $tierSums['GREEN'])  $totalUsed
    $segY = Seg (Format-GB $tierSums['YELLOW']) $totalUsed
    $segR = Seg (Format-GB $tierSums['RED'])    $totalUsed
    $segM = Seg (Format-GB $tierSums['MOVE'])   $totalUsed
    $freePct = [math]::Round(100 - $c.used_pct, 1)
    $dLine = ''
    if ($dDrive) { $dLine = ('<div class="tile"><div class="k">D: free</div><div class="v">{0:N1} <span class="u">GB</span></div></div>' -f $dDrive.free_gb) }

    $html = @"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>C Drive Savior - scan panel</title>
<style>
:root{--bg:#f6f8fa;--card:#fff;--ink:#1f2328;--muted:#59636e;--line:#d0d7de;
--green:#1a7f37;--yellow:#9a6700;--red:#cf222e;--move:#0969da;--other:#6e7781;--track:#eaeef2}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--ink:#e6edf3;--muted:#8b949e;--line:#30363d;
--green:#2ea043;--yellow:#bb8009;--red:#f85149;--move:#4493f8;--other:#6e7681;--track:#21262d}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);
font:14px/1.5 "Segoe UI","Microsoft YaHei",sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--muted);margin-bottom:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin-bottom:14px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.tile{border:1px solid var(--line);border-radius:8px;padding:10px 12px}
.tile .k{color:var(--muted);font-size:12px}.tile .v{font-size:24px;font-weight:600}.tile .u{font-size:13px;color:var(--muted)}
.bar{display:flex;height:14px;border-radius:7px;overflow:hidden;background:var(--track);margin:14px 0 6px;gap:2px}
.bar div{height:100%}
.legend{display:flex;flex-wrap:wrap;gap:14px;color:var(--muted);font-size:12px}
.dot{display:inline-block;width:9px;height:9px;border-radius:3px;margin-right:5px;vertical-align:-1px}
.insight{border-left:3px solid var(--move);padding:8px 12px;background:var(--track);border-radius:6px;margin-top:10px}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{border-bottom:1px solid var(--line);padding:7px 8px;text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:600}.num{white-space:nowrap;font-variant-numeric:tabular-nums;text-align:right}
.note{color:var(--muted)}code{word-break:break-all;font-size:12px}
.pill{display:inline-block;min-width:56px;text-align:center;border-radius:999px;padding:2px 8px;color:#fff;font-size:11px;font-weight:700}
.wrap{overflow-x:auto}
</style></head><body><main>
<h1>C Drive Savior · 扫描面板</h1>
<div class="sub">只读扫描 · $($report.generated_at) · 阈值 $ThresholdGB GB · 用时 $($report.scan_seconds)s · 扫描错误 $($report.walk_errors)（无权限目录）</div>
<section class="card">
  <div class="tiles">
    <div class="tile"><div class="k">C: 已用</div><div class="v">$($c.used_gb) <span class="u">/ $($c.total_gb) GB</span></div></div>
    <div class="tile"><div class="k">C: 可用</div><div class="v">$($c.free_gb) <span class="u">GB</span></div></div>
    <div class="tile"><div class="k">占用率</div><div class="v">$($c.used_pct)<span class="u">%</span></div></div>
    $dLine
  </div>
  <div class="bar" role="img" aria-label="C盘占用分段">
    <div style="width:$segG%;background:var(--green)"></div>
    <div style="width:$segY%;background:var(--yellow)"></div>
    <div style="width:$segR%;background:var(--red)"></div>
    <div style="width:$segM%;background:var(--move)"></div>
    <div style="flex:1;background:var(--other)"></div>
  </div>
  <div class="legend">
    <span><i class="dot" style="background:var(--green)"></i>GREEN 可自动清理 $($report.tier_sums_gb.GREEN) GB</span>
    <span><i class="dot" style="background:var(--yellow)"></i>YELLOW 需确认 $($report.tier_sums_gb.YELLOW) GB</span>
    <span><i class="dot" style="background:var(--red)"></i>RED 勿手删 $($report.tier_sums_gb.RED) GB</span>
    <span><i class="dot" style="background:var(--move)"></i>MOVE 可迁D盘 $($report.tier_sums_gb.MOVE) GB</span>
    <span><i class="dot" style="background:var(--other)"></i>系统及其他（含隐藏占用）</span>
    <span>可用 $($c.free_gb) GB（$freePct%）</span>
  </div>
  <div class="insight">$([Net.WebUtility]::HtmlEncode($insight))</div>
</section>
<section class="card"><h3 style="margin-top:0">隐藏占用（普通扫描看不到）</h3>
<div class="wrap"><table><thead><tr><th>项目</th><th class="num">大小</th><th>说明</th></tr></thead>
<tbody>$($hiddenHtml.ToString())
<tr><td>未归账空间</td><td class="num">$(Format-GB $unaccounted) GB</td><td class="note">零散小文件 / 无权限目录 / 压缩差额</td></tr>
</tbody></table></div></section>
<section class="card"><h3 style="margin-top:0">超过阈值的目录（同级从大到小）</h3>
<div class="wrap"><table><thead><tr><th>级别</th><th class="num">GB</th><th>路径</th><th>建议</th></tr></thead>
<tbody>$($rowsHtml.ToString())</tbody></table></div></section>
<div class="sub">GREEN=可重建缓存 · YELLOW=需人工确认 · RED=只能官方工具 · MOVE=适合迁移到D盘 · 本面板为只读扫描结果</div>
</main></body></html>
"@
    $htmlPath = Join-Path $OutDir ("panel-{0}.html" -f $stamp)
    [IO.File]::WriteAllText($htmlPath, $html, (New-Object Text.UTF8Encoding $true))
}

Write-Host ''
Write-Host ("JSON: {0}" -f $jsonPath)
if ($htmlPath) { Write-Host ("HTML: {0}" -f $htmlPath) }
Write-Host ("elapsed: {0}s, walk errors: {1}" -f $report.scan_seconds, $report.walk_errors)
if ($OpenReport -and $htmlPath) { Start-Process $htmlPath }
