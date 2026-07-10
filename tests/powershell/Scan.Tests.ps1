BeforeAll {
    . "$PSScriptRoot\..\helpers\New-TestFixture.ps1"
    $ScanScript = Join-Path $PSScriptRoot '..\..\scripts\scan.ps1'
    $FixtureRoot = Join-Path $TestDrive 'fixture'
    $Fixture = New-TestFixture -Root $FixtureRoot
    $SessionRoot = Join-Path $TestDrive 'sessions'

    & $ScanScript -ScanRoot $Fixture.Root -ThresholdGB 0 -MaxReportDepth 8 `
        -SessionRoot $SessionRoot -NoHtml | Out-Null
    $sessionDirectory = Get-ChildItem -LiteralPath $SessionRoot -Directory | Select-Object -First 1
    $scan = Get-Content -Raw -LiteralPath (Join-Path $sessionDirectory.FullName 'scan.json') | ConvertFrom-Json
}

AfterAll {
    if ($Fixture.JunctionCreated -and (Test-Path -LiteralPath $Fixture.LinkPath)) {
        Remove-Item -LiteralPath $Fixture.LinkPath -Force -ErrorAction SilentlyContinue
    }
}

Describe 'scan.ps1 v2 contract' {
    It 'visits each physical file identity once' {
        if (-not $Fixture.HardLinksCreated) { Set-ItResult -Skipped -Because 'hard links are unavailable'; return }
        $rootRow = $scan.rows | Where-Object path -eq $Fixture.Root
        $rootRow.logical_bytes | Should -Be 7680
        $rootRow.unique_bytes | Should -Be 3584
    }

    It 'records and does not recurse into junctions' {
        if (-not $Fixture.JunctionCreated) { Set-ItResult -Skipped -Because 'junctions are unavailable'; return }
        $scan.skipped_reparse_points.path | Should -Contain $Fixture.LinkPath
    }

    It 'uses raw byte fields and a nonnegative system-and-other value' {
        $scan.drives[0].free_bytes | Should -BeOfType ([long])
        $scan.system_and_other_bytes | Should -BeGreaterOrEqual 0
    }

    It 'does not subtract a hidden path twice' {
        $scan.accounting.duplicate_hidden_bytes | Should -Be 0
    }
}
