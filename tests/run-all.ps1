[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$pester = Invoke-Pester -Path (Join-Path $PSScriptRoot 'powershell') -Output Detailed -PassThru
if ($pester.FailedCount -gt 0) {
    throw "Pester failed: $($pester.FailedCount) test(s)."
}

python -m unittest discover -s (Join-Path $PSScriptRoot 'python') -v
if ($LASTEXITCODE -ne 0) {
    throw "Python tests failed with exit code $LASTEXITCODE."
}

Get-ChildItem (Join-Path $PSScriptRoot '..\scripts\*.ps1'),(Join-Path $PSScriptRoot '..\benchmarks\*.ps1') | ForEach-Object {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $_.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count) {
        throw "$($_.Name): $($errors -join '; ')"
    }
}

Write-Host 'All PowerShell, Python, schema, contract, and parse checks passed.'
