BeforeAll {
    $Decide = Join-Path $PSScriptRoot '..\..\scripts\decide.ps1'
    Import-Module "$PSScriptRoot\..\..\modules\CDriveSavior.Core.psm1" -Force
}

Describe 'decide.ps1' {
    BeforeEach {
        $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $SessionId = 'decision-12345678'
        $session = New-CdsSession -SessionId $SessionId -SessionRoot $Root
        $session = Set-CdsSessionState -Session $session -NextState 'awaiting-decision'
        Write-CdsJsonAtomic -Path (Join-Path $session.root 'session.json') -InputObject $session

        $rows = @(
            [pscustomobject]@{ id = 'temp-user'; tier = 'GREEN'; path = 'C:\Users\demo\AppData\Local\Temp' },
            [pscustomobject]@{ id = 'package-cache'; tier = 'YELLOW'; path = 'C:\ProgramData\Package Cache' },
            [pscustomobject]@{ id = 'documents'; tier = 'MOVE'; path = 'C:\Users\demo\Documents' }
        )
        Write-CdsJsonAtomic -Path $session.artifacts.scan -InputObject ([pscustomobject]@{
            schema_version = 2
            session_id = $SessionId
            rows = $rows
        })
    }

    It 'rejects an item id absent from the scan' {
        { & $Decide -SessionId $SessionId -ApproveClean 'made-up-id' -SessionRoot $Root } |
            Should -Throw '*not present in scan*'
    }

    It 'records one approved clean id and one protected path' {
        & $Decide -SessionId $SessionId -ApproveClean 'temp-user' `
            -Protect 'C:\Users\demo\Documents' -SessionRoot $Root
        $decision = Get-Content -Raw "$Root\$SessionId\decisions.json" | ConvertFrom-Json
        $decision.approved_clean_ids | Should -Contain 'temp-user'
        $decision.protected_paths | Should -Contain 'C:\Users\demo\Documents'
    }

    It 'does not approve yellow items through ApproveClean' {
        { & $Decide -SessionId $SessionId -ApproveClean 'package-cache' -SessionRoot $Root } |
            Should -Throw '*not GREEN*'
    }

    It 'records a MOVE item separately' {
        & $Decide -SessionId $SessionId -ApproveMove 'documents' -SessionRoot $Root
        $decision = Read-CdsJson -Path "$Root\$SessionId\decisions.json"
        $decision.approved_move_ids | Should -Contain 'documents'
    }

    It 'allows an identical second decision' {
        & $Decide -SessionId $SessionId -ApproveClean 'temp-user' -SessionRoot $Root
        { & $Decide -SessionId $SessionId -ApproveClean 'temp-user' -SessionRoot $Root } |
            Should -Not -Throw
    }

    It 'rejects a conflicting second decision' {
        & $Decide -SessionId $SessionId -ApproveClean 'temp-user' -SessionRoot $Root
        { & $Decide -SessionId $SessionId -ApproveMove 'documents' -SessionRoot $Root } |
            Should -Throw '*conflicting*'
    }

    It 'allows only an explicitly approved item' {
        & $Decide -SessionId $SessionId -ApproveClean 'temp-user' -SessionRoot $Root
        Assert-CdsApprovedItem -SessionId $SessionId -ItemId 'temp-user' `
            -Action clean -SessionRoot $Root | Should -BeTrue
        { Assert-CdsApprovedItem -SessionId $SessionId -ItemId 'package-cache' `
            -Action clean -SessionRoot $Root } | Should -Throw '*not approved*'
    }

    It 'rejects an approved action under a protected path' {
        & $Decide -SessionId $SessionId -ApproveClean 'temp-user' `
            -Protect 'C:\Users\demo\Documents' -SessionRoot $Root
        { Assert-CdsApprovedItem -SessionId $SessionId -ItemId 'temp-user' -Action clean `
            -TargetPath 'C:\Users\demo\Documents\cache' -SessionRoot $Root } |
            Should -Throw '*protected path*'
    }
}
