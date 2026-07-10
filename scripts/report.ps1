# report.ps1 - build a session-bound, read-only C Drive Savior report.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SessionId,
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions",
    [switch]$OpenReport
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $skillRoot 'modules\CDriveSavior.Core.psm1') -Force

function Assert-SessionArtifact([string]$Path, [string]$Root, [string]$Name) {
    if (-not (Test-CdsPathWithin -Path $Path -AllowedRoot $Root)) {
        throw "$Name artifact is outside the session root."
    }
}

function New-InvalidAction([int]$LineNumber, [string]$Message) {
    return [pscustomobject][ordered]@{
        schema_version=2; session_id=$SessionId; tool='clean.ps1'; item_id=("invalid-action-line-{0}" -f $LineNumber)
        action='validate-action'; status='failed'; started_at=(Get-Date).ToUniversalTime().ToString('o'); finished_at=(Get-Date).ToUniversalTime().ToString('o')
        before_bytes=$null; after_bytes=$null; freed_bytes=[long]0; source=$null; destination=$null
        error_code='invalid-action'; error_message=$Message
        undo=[pscustomobject]@{kind='none';steps=@()}
    }
}

function Test-ActionRecord($Action) {
    $required=@('schema_version','session_id','tool','item_id','action','status','started_at','finished_at','before_bytes','after_bytes','freed_bytes','source','destination','error_code','error_message','undo')
    foreach($name in $required){if(-not $Action.PSObject.Properties[$name]){return "missing field: $name"}}
    if($Action.schema_version -ne 2){return 'schema_version is not 2'}
    if($Action.session_id -ne $SessionId){return 'session_id mismatch'}
    if($Action.tool -notin @('clean.ps1','migrate.ps1')){return 'invalid tool'}
    if($Action.status -notin @('planned','completed','partial','failed','skipped','not-found')){return 'invalid status'}
    if(-not $Action.undo -or -not $Action.undo.PSObject.Properties['kind'] -or -not $Action.undo.PSObject.Properties['steps']){return 'invalid undo object'}
    return $null
}

$session = Get-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
$expectedRoot = Join-Path ([IO.Path]::GetFullPath($SessionRoot)) $SessionId
if (-not [string]::Equals([IO.Path]::GetFullPath($session.root), [IO.Path]::GetFullPath($expectedRoot), [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Session root does not match the requested session.'
}
foreach($artifact in @('scan','decisions','actions','panel','report')){
    Assert-SessionArtifact -Path $session.artifacts.$artifact -Root $session.root -Name $artifact
}

$scan = Read-CdsJson -Path $session.artifacts.scan
if($scan.schema_version -ne 2 -or $scan.session_id -ne $SessionId){throw 'Scan artifact does not match this v2 session.'}
$decisions = Read-CdsJson -Path $session.artifacts.decisions
if($decisions.schema_version -ne 2 -or $decisions.session_id -ne $SessionId){throw 'Decision artifact does not match this v2 session.'}

$actions = New-Object System.Collections.Generic.List[object]
if(Test-Path -LiteralPath $session.artifacts.actions -PathType Leaf){
    $lineNumber=0
    foreach($line in [IO.File]::ReadLines($session.artifacts.actions)){
        $lineNumber++
        if([string]::IsNullOrWhiteSpace($line)){continue}
        try{
            $action=$line | ConvertFrom-Json -ErrorAction Stop
            $validationError=Test-ActionRecord $action
            if($validationError){$actions.Add((New-InvalidAction $lineNumber $validationError))}
            else{$actions.Add($action)}
        }catch{
            $actions.Add((New-InvalidAction $lineNumber $_.Exception.Message))
        }
    }
}

$cDrive=@($scan.drives | Where-Object letter -eq 'C:')
if($cDrive.Count -ne 1){throw 'Scan must contain exactly one C: drive record.'}
$current=Get-PSDrive -Name C -ErrorAction Stop
[long]$baselineFree=$cDrive[0].free_bytes
[long]$currentFree=$current.Free
[long]$netFreed=$currentFree-$baselineFree
[long]$attributable=0
foreach($action in @($actions | Where-Object status -in @('completed','partial'))){
    if($null -ne $action.freed_bytes){$attributable += [long]$action.freed_bytes}
}
[long]$difference=$netFreed-$attributable
$summary=[pscustomobject][ordered]@{
    session_id=$SessionId
    generated_at=(Get-Date).ToUniversalTime().ToString('o')
    baseline_free_bytes=$baselineFree
    current_free_bytes=$currentFree
    net_freed_bytes=$netFreed
    attributable_freed_bytes=$attributable
    difference_bytes=$difference
    completed_count=@($actions | Where-Object status -eq 'completed').Count
    partial_count=@($actions | Where-Object status -eq 'partial').Count
    failed_count=@($actions | Where-Object status -eq 'failed').Count
    skipped_count=@($actions | Where-Object status -in @('skipped','not-found')).Count
}
$payload=[pscustomobject][ordered]@{
    view='report';session_id=$SessionId;generated_at=$summary.generated_at
    scan=$scan;decisions=$decisions;actions=@($actions | ForEach-Object{$_});summary=$summary
}

$template=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'assets\report_template.html')
$script=Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $skillRoot 'assets\report_script.js')
$encoded=[Net.WebUtility]::HtmlEncode(($payload | ConvertTo-Json -Depth 100 -Compress))
$html=$template.Replace('__REPORT_DATA__',$encoded).Replace('__REPORT_SCRIPT__',$script)
[IO.File]::WriteAllText($session.artifacts.report,$html,(New-Object Text.UTF8Encoding $false))

Write-Host ("Report: {0}" -f $session.artifacts.report)
Write-Host ("Net freed: {0:N2} GB; attributable: {1:N2} GB" -f ($netFreed/1GB),($attributable/1GB))
if($OpenReport){Start-Process $session.artifacts.report}
return $summary
