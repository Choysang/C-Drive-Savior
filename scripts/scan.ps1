# scan.ps1 - canonical read-only C Drive Savior scanner (PowerShell 5.1 / 7).
[CmdletBinding()]
param(
    [double]$ThresholdGB = 1.0,
    [int]$MaxReportDepth = 4,
    [string]$ScanRoot = "$env:SystemDrive\",
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions",
    [switch]$AnalyzeWinSxS,
    [switch]$OpenReport,
    [switch]$NoHtml
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $skillRoot 'modules\CDriveSavior.Core.psm1') -Force

$classification = Read-CdsJson -Path (Join-Path $skillRoot 'config\classification.json')
$greenNames = @{}; foreach ($name in $classification.green_names) { $greenNames[$name] = $true }
$yellowNames = @{}; foreach ($name in $classification.yellow_names) { $yellowNames[$name] = $true }
$moveNames = @{}; foreach ($name in $classification.move_names) { $moveNames[$name] = $true }
$protectedPrefixes = @($classification.protected_prefixes | ForEach-Object {
    (Join-Path $env:SystemDrive ($_.Replace('/', [IO.Path]::DirectorySeparatorChar))).ToLowerInvariant()
})
$actionIdsByPath = @{}
foreach ($item in @($classification.cleanup_items)) {
    foreach ($resolver in @($item.resolvers)) {
        try {
            $spec = Resolve-CdsCatalogSpec $resolver
            foreach ($path in @(Expand-CdsCatalogSpec $spec)) {
                $key = [IO.Path]::GetFullPath($path).TrimEnd('\').ToLowerInvariant()
                if (-not $actionIdsByPath.ContainsKey($key)) { $actionIdsByPath[$key] = [string]$item.id }
            }
        } catch { continue }
    }
}

function Get-StableId([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 20).ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Get-ScanTier([string]$Path) {
    $lower = $Path.ToLowerInvariant()
    $name = [IO.Path]::GetFileName($Path).ToLowerInvariant()
    foreach ($prefix in $protectedPrefixes) {
        if ($lower -eq $prefix -or $lower.StartsWith($prefix + '\')) {
            return @('RED', 'System/install area. Use official tools or an uninstaller; never hand-delete.')
        }
    }
    foreach ($case in @($classification.special_cases)) {
        if (@($case.names) -contains $name) { return @($case.tier, $case.note) }
    }
    if ($moveNames.ContainsKey($name)) { return @('MOVE', 'User data candidate for confirmed migration.') }
    if ($greenNames.ContainsKey($name)) { return @('GREEN', 'Rebuildable cache or temporary data.') }
    if ($yellowNames.ContainsKey($name) -or $name.StartsWith('$winreagent')) {
        return @('YELLOW', 'Requires a user decision; may contain user, repair, rollback, or uninstall data.')
    }
    if ($name -like '*cache*' -or $name -like '*temp*') { return @('GREEN', 'Cache-like name; verify ownership before cleanup.') }
    return @('YELLOW', 'Large item requiring a human decision.')
}

$identitySource = Join-Path $skillRoot 'native\FileIdentity.cs'
if (-not ('FileIdentity' -as [type])) { Add-Type -Path $identitySource }

$root = [IO.Path]::GetFullPath($ScanRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Scan root was not found: $root" }
$threshold = [long]($ThresholdGB * 1GB)
$timer = [Diagnostics.Stopwatch]::StartNew()
$session = New-CdsSession -SessionRoot $SessionRoot

$states = @{}
$rows = New-Object System.Collections.Generic.List[object]
$denied = New-Object System.Collections.Generic.List[object]
$reparse = New-Object System.Collections.Generic.List[object]
$identities = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$stack = New-Object 'System.Collections.Generic.Stack[object]'
$rootId = Get-StableId $root
$states[$root] = [pscustomobject]@{ path=$root; id=$rootId; parent=$null; parent_id=$null; depth=0; logical=[long]0; unique=[long]0; direct_unique=[long]0 }
$stack.Push([pscustomobject]@{ path=$root; visited=$false })
$scanComplete = $true
$allocationAccurate = $true

while ($stack.Count -gt 0) {
    $work = $stack.Pop()
    $state = $states[$work.path]
    if ($work.visited) {
        if ($state.parent) {
            $states[$state.parent].logical += $state.logical
            $states[$state.parent].unique += $state.unique
        }
        $actionKey = [IO.Path]::GetFullPath($state.path).TrimEnd('\').ToLowerInvariant()
        $actionId = if($actionIdsByPath.ContainsKey($actionKey)){$actionIdsByPath[$actionKey]}else{$null}
        if (($state.depth -le $MaxReportDepth -and ($state.path -eq $root -or $state.unique -ge $threshold)) -or $actionId) {
            $tier = Get-ScanTier $state.path
            $rows.Add([pscustomobject][ordered]@{
                id=$state.id; parent_id=$state.parent_id; action_id=$actionId; path=$state.path; depth=[int]$state.depth
                logical_bytes=[long]$state.logical; unique_bytes=[long]$state.unique
                exclusive_bytes=[long]$state.direct_unique
                size_accuracy=if($allocationAccurate){'file-id-deduplicated'}else{'logical'}
                tier=$tier[0]; note=$tier[1]
            })
        }
        continue
    }

    $stack.Push([pscustomobject]@{ path=$work.path; visited=$true })
    try {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($work.path)) {
            try {
                $attributes = [IO.File]::GetAttributes($entry)
                if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $reparse.Add([pscustomobject][ordered]@{ path=$entry; kind='reparse-point'; target=$null })
                    continue
                }
                if ($attributes -band [IO.FileAttributes]::Directory) {
                    $childId = Get-StableId $entry
                    $states[$entry] = [pscustomobject]@{ path=$entry; id=$childId; parent=$state.path; parent_id=$state.id; depth=($state.depth+1); logical=[long]0; unique=[long]0; direct_unique=[long]0 }
                    $stack.Push([pscustomobject]@{ path=$entry; visited=$false })
                    continue
                }
                $info = [FileIdentity]::Read($entry)
                $state.logical += [long]$info.LogicalBytes
                $key = '{0}:{1}' -f $info.VolumeSerialNumber,$info.FileIndex
                if ($identities.Add($key)) {
                    $state.unique += [long]$info.LogicalBytes
                    $state.direct_unique += [long]$info.LogicalBytes
                }
                if (-not $info.AllocatedBytesAccurate) { $allocationAccurate = $false }
            } catch {
                $scanComplete = $false
                $denied.Add([pscustomobject][ordered]@{ path=$entry; error_code=$_.Exception.GetType().Name; error_message=$_.Exception.Message })
            }
        }
    } catch {
        $scanComplete = $false
        $denied.Add([pscustomobject][ordered]@{ path=$work.path; error_code=$_.Exception.GetType().Name; error_message=$_.Exception.Message })
    }
}

$timer.Stop()
$driveRoot = [IO.Path]::GetPathRoot($root)
$drive = New-Object IO.DriveInfo $driveRoot
$totalBytes = [long]$drive.TotalSize
$freeBytes = [long]$drive.AvailableFreeSpace
$usedBytes = [long]($totalBytes - $freeBytes)
$visibleUnique = [long]$states[$root].unique
$hidden = New-Object System.Collections.Generic.List[object]
$duplicateHidden = [long]0
if ([string]::Equals($root, $driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
    foreach ($spec in @(
        @{ id='pagefile'; label='pagefile.sys (virtual memory)'; path=(Join-Path $root 'pagefile.sys') },
        @{ id='hiberfil'; label='hiberfil.sys (hibernation)'; path=(Join-Path $root 'hiberfil.sys') },
        @{ id='swapfile'; label='swapfile.sys'; path=(Join-Path $root 'swapfile.sys') },
        @{ id='memdump'; label='MEMORY.DMP (crash dump)'; path=(Join-Path $env:SystemRoot 'MEMORY.DMP') }
    )) {
        if (Test-Path -LiteralPath $spec.path -PathType Leaf) {
            try {
                $hiddenInfo = [FileIdentity]::Read($spec.path)
                $hiddenBytes = [long]$hiddenInfo.LogicalBytes
                $duplicateHidden += $hiddenBytes
                $hidden.Add([pscustomobject][ordered]@{
                    id=$spec.id; label=$spec.label; bytes=$hiddenBytes; size_accuracy='logical'
                    requires_admin=$false; overlaps_visible_scan=$true
                    note='Already included in the visible root total; shown separately for diagnosis.'; error=$null
                })
            } catch {
                $hidden.Add([pscustomobject][ordered]@{
                    id=$spec.id; label=$spec.label; bytes=$null; size_accuracy='logical'
                    requires_admin=$true; overlaps_visible_scan=$true; note='Could not measure this protected file.'
                    error=$_.Exception.Message
                })
            }
        }
    }
}
$systemOther = [long]($usedBytes - $visibleUnique)
if ($systemOther -lt 0) { $systemOther = [long]0 }
$report = [pscustomobject][ordered]@{
    schema_version=2; session_id=$session.session_id; generated_at=(Get-Date).ToUniversalTime().ToString('o')
    source_engine='powershell'; engine_version=$PSVersionTable.PSVersion.ToString()
    scan_complete=[bool]$scanComplete; scan_seconds=[math]::Round($timer.Elapsed.TotalSeconds,3)
    drives=@([pscustomobject][ordered]@{ letter=$driveRoot.TrimEnd('\'); filesystem=$drive.DriveFormat; total_bytes=$totalBytes; used_bytes=$usedBytes; free_bytes=$freeBytes })
    rows=@($rows | Sort-Object path); hidden=@($hidden | ForEach-Object { $_ })
    denied_paths=@($denied | ForEach-Object { $_ })
    skipped_reparse_points=@($reparse | ForEach-Object { $_ })
    accounting=[pscustomobject][ordered]@{ visible_unique_bytes=$visibleUnique; hidden_unique_bytes=[long]0; duplicate_hidden_bytes=$duplicateHidden; reconciliation_is_estimate=(-not $allocationAccurate) }
    system_and_other_bytes=$systemOther
}

Write-CdsJsonAtomic -Path $session.artifacts.scan -InputObject $report
$session = Set-CdsSessionState -Session $session -NextState 'awaiting-decision'
Write-CdsJsonAtomic -Path (Join-Path $session.root 'session.json') -InputObject $session
if (-not $NoHtml) {
    $payload = [pscustomobject][ordered]@{
        view='scan'; session_id=$session.session_id; generated_at=$report.generated_at
        scan=$report; decisions=$null; actions=@(); summary=$null
    }
    $template = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'assets\report_template.html')
    $sharedScript = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'assets\report_script.js')
    $encoded = [Net.WebUtility]::HtmlEncode(($payload | ConvertTo-Json -Depth 100 -Compress))
    $panel = $template.Replace('__REPORT_DATA__',$encoded).Replace('__REPORT_SCRIPT__',$sharedScript)
    [IO.File]::WriteAllText($session.artifacts.panel,$panel,(New-Object Text.UTF8Encoding $false))
}

Write-Host ("Session: {0}" -f $session.session_id)
Write-Host ("Scan: {0}" -f $session.artifacts.scan)
if (-not $NoHtml) { Write-Host ("Panel: {0}" -f $session.artifacts.panel) }
Write-Host ("Visible unique: {0:N2} GB; complete={1}; elapsed={2:N2}s" -f ($visibleUnique / 1GB), $scanComplete, $timer.Elapsed.TotalSeconds)
if ($OpenReport -and -not $NoHtml) { Start-Process $session.artifacts.panel }
