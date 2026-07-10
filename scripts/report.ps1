# report.ps1 - C Drive Savior cleanup report: baseline scan vs now + all action logs.
# PowerShell 5.1 / 7. Read-only. Produces console summary + HTML report.
[CmdletBinding()]
param(
    [string]$Baseline,                 # scan-*.json from scan.ps1; default: oldest in LogDir
    [string]$LogDir = "$env:USERPROFILE\c-drive-savior",
    [switch]$OpenReport
)

$ErrorActionPreference = 'SilentlyContinue'
function Format-GB([long]$b) { [math]::Round($b / 1GB, 2) }

if (-not $Baseline) {
    $Baseline = (Get-ChildItem -LiteralPath $LogDir -Filter 'scan-*.json' -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -First 1).FullName
}
if (-not $Baseline -or -not (Test-Path -LiteralPath $Baseline)) {
    Write-Host 'ERROR: no baseline scan JSON found. Run scan.ps1 first.'; exit 2
}
$base = Get-Content -LiteralPath $Baseline -Raw -Encoding UTF8 | ConvertFrom-Json
$cBase = $base.drives | Where-Object letter -eq 'C'

$logs = @(Get-ChildItem -LiteralPath $LogDir -Filter 'actions-*.json' -ErrorAction SilentlyContinue | Sort-Object Name)
$actions = New-Object System.Collections.Generic.List[object]
foreach ($lf in $logs) {
    $j = Get-Content -LiteralPath $lf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.mode -ne 'execute') { continue }   # dry-runs are plans, not results
    foreach ($it in $j.items) {
        $actions.Add([pscustomobject]@{
            tool = $j.tool; id = $it.id; label = $it.label
            freed_gb = Format-GB ([long]$it.freed_bytes)
            status = $it.status; detail = ('' + $it.detail + $it.undo)
            source = $it.source; dest = $it.dest
        })
    }
}

$cNow = Get-PSDrive C
$nowFree = Format-GB $cNow.Free
$nowUsed = Format-GB $cNow.Used
$total = [double]$cBase.total_gb
$deltaFree = [math]::Round($nowFree - [double]$cBase.free_gb, 2)
$sumFreed = [math]::Round((($actions | Where-Object { $_.status -notlike 'skipped*' } | Measure-Object -Property freed_gb -Sum).Sum), 2)
if (-not $sumFreed) { $sumFreed = 0 }
$done    = @($actions | Where-Object { $_.status -in 'cleaned','moved','moved+junction' })
$partial = @($actions | Where-Object { $_.status -like 'partial*' -or $_.status -like 'copied*' })
$skipped = @($actions | Where-Object { $_.status -like 'skipped*' -or $_.status -like '*failed*' })

# --- console -----------------------------------------------------------------
Write-Host ''
Write-Host '=== C Drive Savior cleanup report ==='
Write-Host ("baseline: {0} (C: free {1} GB)" -f $base.generated_at, $cBase.free_gb)
Write-Host ("now     : C: free {0} GB  => net freed {1} GB (disk-level)" -f $nowFree, $deltaFree)
Write-Host ("actions : {0} done, {1} partial, {2} skipped/failed; per-item measured freed {3} GB" -f $done.Count, $partial.Count, $skipped.Count, $sumFreed)
foreach ($a in ($actions | Sort-Object freed_gb -Descending | Select-Object -First 20)) {
    Write-Host ("  {0,-9} {1,8} GB  {2,-24} {3}" -f $a.status, $a.freed_gb, $a.id, $a.label)
}

# --- HTML ---------------------------------------------------------------------
function Pct([double]$gb) { if ($total -le 0) { return 0 } [math]::Round($gb / $total * 100, 2) }
$beforeUsedPct = Pct ([double]$cBase.used_gb)
$nowUsedPct = Pct ([double]$nowUsed)
$rowsHtml = New-Object Text.StringBuilder
foreach ($a in ($actions | Sort-Object freed_gb -Descending)) {
    $cls = 'ok'
    if ($a.status -like 'skipped*' -or $a.status -like '*failed*' -or $a.status -like '*mismatch*') { $cls = 'warn' }
    $extra = ''
    if ($a.source) { $extra = ('{0} -> {1}' -f $a.source, $a.dest) }
    [void]$rowsHtml.AppendFormat('<tr><td><span class="st {0}">{1}</span></td><td class="num">{2:N2}</td><td>{3}</td><td class="note">{4} {5}</td></tr>',
        $cls, $a.status, $a.freed_gb, [Net.WebUtility]::HtmlEncode('' + $a.label),
        [Net.WebUtility]::HtmlEncode('' + $extra), [Net.WebUtility]::HtmlEncode('' + $a.detail))
}
$genAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$html = @"
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>C Drive Savior - cleanup report</title>
<style>
:root{--bg:#f6f8fa;--card:#fff;--ink:#1f2328;--muted:#59636e;--line:#d0d7de;
--green:#1a7f37;--yellow:#9a6700;--used:#6e7781;--track:#eaeef2;--accent:#0969da}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--card:#161b22;--ink:#e6edf3;--muted:#8b949e;--line:#30363d;
--green:#2ea043;--yellow:#bb8009;--used:#6e7681;--track:#21262d;--accent:#4493f8}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.5 "Segoe UI","Microsoft YaHei",sans-serif}
main{max-width:980px;margin:0 auto;padding:24px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--muted);margin-bottom:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;margin-bottom:14px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:10px}
.tile{border:1px solid var(--line);border-radius:8px;padding:10px 12px}
.tile .k{color:var(--muted);font-size:12px}.tile .v{font-size:26px;font-weight:600}.tile .u{font-size:13px;color:var(--muted)}
.tile.hero{border-color:var(--green)}.tile.hero .v{color:var(--green)}
.cmp{margin:10px 0 4px;font-size:12px;color:var(--muted)}
.bar{display:flex;height:12px;border-radius:6px;overflow:hidden;background:var(--track);margin:4px 0 10px}
.bar .u{background:var(--used)}.bar .f{background:var(--green)}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{border-bottom:1px solid var(--line);padding:7px 8px;text-align:left;vertical-align:top}
th{color:var(--muted);font-weight:600}.num{white-space:nowrap;text-align:right;font-variant-numeric:tabular-nums}
.note{color:var(--muted);word-break:break-all}
.st{display:inline-block;border-radius:999px;padding:2px 8px;color:#fff;font-size:11px;font-weight:700}
.st.ok{background:var(--green)}.st.warn{background:var(--yellow)}
.wrap{overflow-x:auto}
ul{margin:6px 0 0 18px;padding:0}li{margin:4px 0}
</style></head><body><main>
<h1>C Drive Savior · 清理报告</h1>
<div class="sub">生成于 $genAt · 基线扫描 $($base.generated_at)</div>
<section class="card">
  <div class="tiles">
    <div class="tile hero"><div class="k">本次共释放（磁盘净变化）</div><div class="v">$deltaFree <span class="u">GB</span></div></div>
    <div class="tile"><div class="k">清理前 C: 可用</div><div class="v">$($cBase.free_gb) <span class="u">GB</span></div></div>
    <div class="tile"><div class="k">清理后 C: 可用</div><div class="v">$nowFree <span class="u">GB</span></div></div>
    <div class="tile"><div class="k">逐项实测释放合计</div><div class="v">$sumFreed <span class="u">GB</span></div></div>
  </div>
  <div class="cmp">清理前（已用 $($cBase.used_gb) / $total GB）</div>
  <div class="bar"><div class="u" style="width:$beforeUsedPct%"></div><div style="flex:1"></div></div>
  <div class="cmp">清理后（已用 $nowUsed / $total GB）</div>
  <div class="bar"><div class="u" style="width:$nowUsedPct%"></div><div class="f" style="width:$([math]::Round($beforeUsedPct-$nowUsedPct,2))%"></div><div style="flex:1"></div></div>
  <div class="cmp">绿色段 = 本次释放出来的空间。磁盘净变化与逐项合计可能有差异（硬链接 / 期间系统写入），以磁盘净变化为准。</div>
</section>
<section class="card"><h3 style="margin-top:0">动作明细（$($done.Count) 完成 · $($partial.Count) 部分 · $($skipped.Count) 跳过/失败）</h3>
<div class="wrap"><table><thead><tr><th>状态</th><th class="num">释放 GB</th><th>项目</th><th>说明 / 撤销方式</th></tr></thead>
<tbody>$($rowsHtml.ToString())</tbody></table></div></section>
<section class="card"><h3 style="margin-top:0">保持干净的建议</h3>
<ul>
<li>开启存储感知：设置 → 系统 → 存储 → 存储感知（自动清临时文件与回收站）。</li>
<li>大文件优先放 D 盘：下载目录、聊天文件、游戏库、开发缓存的迁移方法见 references/relocation-guide.md。</li>
<li>浏览器 / 微信 / 开发工具缓存会重新增长，隔几个月重跑一次扫描即可。</li>
<li>迁移过的目录先保留 D 盘副本一段时间，确认软件正常后再删 C 盘残留。</li>
</ul></section>
</main></body></html>
"@
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$htmlPath = Join-Path $LogDir ("report-{0}.html" -f $stamp)
[IO.File]::WriteAllText($htmlPath, $html, (New-Object Text.UTF8Encoding $true))
Write-Host ("HTML report: {0}" -f $htmlPath)
if ($OpenReport) { Start-Process $htmlPath }
