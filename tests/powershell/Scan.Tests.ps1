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

    It 'links a catalog cleanup id to its scanned path' {
        $catalogSessions = Join-Path $TestDrive 'catalog-sessions'
        $oldTemp = $env:TEMP
        $oldLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $Fixture.Root
            $env:TEMP = Join-Path $Fixture.Root 'cache-a'
            & $ScanScript -ScanRoot $Fixture.Root -ThresholdGB 100 -MaxReportDepth 0 `
                -SessionRoot $catalogSessions -NoHtml | Out-Null
            $catalogScan = Get-Content -Raw -Encoding UTF8 `
                (Get-ChildItem -LiteralPath $catalogSessions -Filter scan.json -Recurse | Select-Object -First 1).FullName | ConvertFrom-Json
            ($catalogScan.rows | Where-Object path -eq $env:TEMP).action_id | Should -Be 'temp-user'
        } finally {
            $env:TEMP = $oldTemp
            $env:LOCALAPPDATA = $oldLocalAppData
        }
    }

    It 'renders the shared static assets when HTML is enabled' {
        $htmlSessions = Join-Path $TestDrive 'html-sessions'
        & $ScanScript -ScanRoot $Fixture.Root -ThresholdGB 0 -MaxReportDepth 8 `
            -SessionRoot $htmlSessions | Out-Null
        $panel = Get-ChildItem -LiteralPath $htmlSessions -Filter panel.html -Recurse | Select-Object -First 1
        $html = Get-Content -Raw -Encoding UTF8 -LiteralPath $panel.FullName
        $sharedScript = Get-Content -Raw -Encoding UTF8 -LiteralPath "$PSScriptRoot\..\..\assets\report_script.js"
        $html.Contains($sharedScript) | Should -BeTrue
        $html | Should -Not -Match '__REPORT_DATA__|__REPORT_SCRIPT__'
    }
}
