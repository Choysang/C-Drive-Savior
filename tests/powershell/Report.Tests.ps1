BeforeAll {
    $ReportScript = Join-Path $PSScriptRoot '..\..\scripts\report.ps1'
    Import-Module "$PSScriptRoot\..\..\modules\CDriveSavior.Core.psm1" -Force
    $Root = Join-Path $TestDrive 'sessions'
    $SessionA = 'session-a-12345678'
    $SessionB = 'session-b-12345678'

    foreach ($sessionId in @($SessionA,$SessionB)) {
        $session = New-CdsSession -SessionId $sessionId -SessionRoot $Root
        $rowId = if ($sessionId -eq $SessionA) { 'session-a-item' } else { 'session-b-item' }
        $note = if ($sessionId -eq $SessionA) { '<script>alert(1)</script>' } else { 'other session' }
        Write-CdsJsonAtomic -Path $session.artifacts.scan -InputObject ([pscustomobject][ordered]@{
            schema_version=2; session_id=$sessionId; generated_at=(Get-Date).ToUniversalTime().ToString('o')
            source_engine='powershell'; engine_version='test'; scan_complete=$true; scan_seconds=1
            drives=@([pscustomobject]@{letter='C:';filesystem='NTFS';total_bytes=[long]100GB;used_bytes=[long]90GB;free_bytes=[long]10GB})
            rows=@([pscustomobject]@{id=$rowId;parent_id=$null;action_id=$null;path="C:\$rowId";depth=0;logical_bytes=[long]2GB;unique_bytes=[long]2GB;exclusive_bytes=[long]2GB;size_accuracy='logical';tier='GREEN';note=$note})
            hidden=@(); denied_paths=@(); skipped_reparse_points=@()
            accounting=[pscustomobject]@{visible_unique_bytes=[long]2GB;hidden_unique_bytes=[long]0;duplicate_hidden_bytes=[long]0;reconciliation_is_estimate=$true}
            system_and_other_bytes=[long]88GB
        })
        Write-CdsJsonAtomic -Path $session.artifacts.decisions -InputObject ([pscustomobject]@{
            schema_version=2;session_id=$sessionId;approved_at=(Get-Date).ToUniversalTime().ToString('o')
            approved_clean_ids=@($rowId);approved_move_ids=@();protected_paths=@()
        })
        $action = [pscustomobject][ordered]@{
            schema_version=2;session_id=$sessionId;tool='clean.ps1';item_id=$rowId;action='clean';status='completed'
            started_at=(Get-Date).ToUniversalTime().ToString('o');finished_at=(Get-Date).ToUniversalTime().ToString('o')
            before_bytes=[long]1GB;after_bytes=[long]512MB;freed_bytes=[long]512MB
            source=$note;destination=$null;error_code=$null;error_message=$null
            undo=[pscustomobject]@{kind='none';steps=@()}
        }
        Write-CdsAction -SessionId $sessionId -SessionRoot $Root -ActionRecord $action
    }
}

Describe 'report.ps1 session report' {
    BeforeEach {
        Mock Get-PSDrive { [pscustomobject]@{Name='C';Free=[long]11GB;Used=[long]89GB} } -ParameterFilter { $Name -eq 'C' }
    }

    It 'includes only actions from the requested session' {
        & $ReportScript -SessionId $SessionA -SessionRoot $Root | Out-Null
        $html = Get-Content -Raw -Encoding UTF8 "$Root\$SessionA\report.html"
        $html | Should -Match 'session-a-item'
        $html | Should -Not -Match 'session-b-item'
    }

    It 'escapes every untrusted field' {
        & $ReportScript -SessionId $SessionA -SessionRoot $Root | Out-Null
        $html = Get-Content -Raw -Encoding UTF8 "$Root\$SessionA\report.html"
        $html | Should -Not -Match '<script>alert\(1\)</script>'
        $html | Should -Match '(&lt;script&gt;alert\(1\)&lt;/script&gt;|\\u003cscript\\u003ealert\(1\)\\u003c/script\\u003e)'
    }

    It 'computes free-space delta from raw bytes' {
        $report = & $ReportScript -SessionId $SessionA -SessionRoot $Root
        $report.net_freed_bytes | Should -Be 1073741824
        $report.attributable_freed_bytes | Should -Be 536870912
    }

    It 'renders malformed action lines as visible failures' {
        Add-Content -LiteralPath "$Root\$SessionA\actions.jsonl" -Value '{not-json'
        & $ReportScript -SessionId $SessionA -SessionRoot $Root | Out-Null
        $html = Get-Content -Raw -Encoding UTF8 "$Root\$SessionA\report.html"
        $html | Should -Match 'invalid-action-line'
        $html | Should -Match 'failed'
    }

    It 'contains no destructive endpoint or delete control' {
        & $ReportScript -SessionId $SessionA -SessionRoot $Root | Out-Null
        $html = Get-Content -Raw -Encoding UTF8 "$Root\$SessionA\report.html"
        $html | Should -Not -Match '/delete|fetch\(|Remove-Item|直接删除'
    }
}
