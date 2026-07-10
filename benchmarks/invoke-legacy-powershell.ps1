[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Scanner,
    [Parameter(Mandatory)][string]$ScanRoot,
    [Parameter(Mandatory)][string]$Output
)

$ErrorActionPreference = 'Stop'
$source = Get-Content -Raw -Encoding UTF8 -LiteralPath $Scanner
$needle = '$hidden = Get-HiddenConsumers $elevated'
if (-not $source.Contains($needle)) { throw 'Legacy hidden-consumer hook was not found.' }
$instrumented = $source.Replace($needle, '$hidden = @()')
$scriptPath = Join-Path $Output 'instrumented-legacy-scan.ps1'
[IO.File]::WriteAllText($scriptPath,$instrumented,(New-Object Text.UTF8Encoding $false))
$previousSystemDrive = $env:SystemDrive
try {
    $env:SystemDrive = $ScanRoot.TrimEnd('\')
    & $scriptPath -ThresholdGB 0 -MaxDepth 8 -OutDir $Output -NoHtml
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    $env:SystemDrive = $previousSystemDrive
}
