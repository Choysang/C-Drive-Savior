# decide.ps1 - record one complete cleanup/migration decision for a scan session.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionId,
    [string[]]$ApproveClean = @(),
    [string[]]$ApproveMove = @(),
    [string[]]$Protect = @(),
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions"
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'modules\CDriveSavior.Core.psm1') -Force

function Get-NormalizedValues([string[]]$Values) {
    return @($Values | Where-Object { $_ } | Sort-Object -Unique)
}

function Test-SameValues($Left, $Right) {
    $leftValues = @(Get-NormalizedValues @($Left))
    $rightValues = @(Get-NormalizedValues @($Right))
    if ($leftValues.Count -ne $rightValues.Count) { return $false }
    for ($index = 0; $index -lt $leftValues.Count; $index++) {
        if (-not [string]::Equals($leftValues[$index], $rightValues[$index], [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

$session = Get-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
$scan = Read-CdsJson -Path $session.artifacts.scan
if ($scan.session_id -ne $SessionId) { throw 'Scan session ID does not match the requested session.' }
$classification = Read-CdsJson -Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\classification.json')

$rowsById = @{}
foreach ($row in @($scan.rows)) {
    if ($rowsById.ContainsKey([string]$row.id)) { throw "Duplicate item ID in scan: $($row.id)" }
    $rowsById[[string]$row.id] = $row
}

$approvedClean = @(Get-NormalizedValues $ApproveClean)
$approvedMove = @(Get-NormalizedValues $ApproveMove)
foreach ($itemId in $approvedClean) {
    $matchingRows = @($scan.rows | Where-Object { $_.action_id -eq $itemId -or (-not $_.PSObject.Properties['action_id'] -and $_.id -eq $itemId) })
    if ($matchingRows.Count -lt 1) { throw "Item is not present in scan: $itemId" }
    $catalogItems = @($classification.cleanup_items | Where-Object id -eq $itemId)
    if ($catalogItems.Count -ne 1 -or $catalogItems[0].tier -ne 'GREEN') { throw "Item is not GREEN and cannot be approved for clean: $itemId" }
}
foreach ($itemId in $approvedMove) {
    if (-not $rowsById.ContainsKey($itemId)) { throw "Item is not present in scan: $itemId" }
    if ($rowsById[$itemId].tier -ne 'MOVE') { throw "Item is not MOVE and cannot be approved for migration: $itemId" }
}

$protectedPaths = @(Get-NormalizedValues @($Protect | ForEach-Object { [IO.Path]::GetFullPath($_) }))
$decision = [pscustomobject][ordered]@{
    schema_version = 2
    session_id = $SessionId
    approved_at = (Get-Date).ToUniversalTime().ToString('o')
    approved_clean_ids = $approvedClean
    approved_move_ids = $approvedMove
    protected_paths = $protectedPaths
}

$decisionPath = $session.artifacts.decisions
if (Test-Path -LiteralPath $decisionPath -PathType Leaf) {
    $existing = Read-CdsJson -Path $decisionPath
    $identical = $existing.schema_version -eq 2 -and
        $existing.session_id -eq $SessionId -and
        (Test-SameValues $existing.approved_clean_ids $decision.approved_clean_ids) -and
        (Test-SameValues $existing.approved_move_ids $decision.approved_move_ids) -and
        (Test-SameValues $existing.protected_paths $decision.protected_paths)
    if (-not $identical) {
        throw 'A conflicting decision already exists. Create a new explicit decision instead of overwriting it.'
    }
    if ($session.state -eq 'awaiting-decision') {
        $session = Set-CdsSessionState -Session $session -NextState 'approved'
        Write-CdsJsonAtomic -Path (Join-Path $session.root 'session.json') -InputObject $session
    }
    return $existing
}

if ($session.state -ne 'awaiting-decision') {
    throw "Session must be awaiting-decision before approval; current state: $($session.state)"
}

Write-CdsJsonAtomic -Path $decisionPath -InputObject $decision
$session = Set-CdsSessionState -Session $session -NextState 'approved'
Write-CdsJsonAtomic -Path (Join-Path $session.root 'session.json') -InputObject $session
return $decision
