BeforeAll {
    $Clean = Join-Path $PSScriptRoot '..\..\scripts\clean.ps1'
    $Decide = Join-Path $PSScriptRoot '..\..\scripts\decide.ps1'
    Import-Module "$PSScriptRoot\..\..\modules\CDriveSavior.Core.psm1" -Force
    if (-not ('CdsTestNative' -as [type])) {
        Add-Type @'
using System.Runtime.InteropServices;
public static class CdsTestNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool RemoveDirectory(string path);
}
'@
    }
}

Describe 'clean.ps1 execution guards' {
    BeforeEach {
        $OldEnvironment = @{
            TEMP = $env:TEMP
            TMP = $env:TMP
            LOCALAPPDATA = $env:LOCALAPPDATA
            USERPROFILE = $env:USERPROFILE
        }
        $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $LocalAppData = Join-Path $Root 'LocalAppData'
        $TempPath = Join-Path $LocalAppData 'Temp'
        $Documents = Join-Path $Root 'Documents'
        New-Item -ItemType Directory -Path $TempPath,$Documents -Force | Out-Null
        $ProtectedFile = Join-Path $Documents 'keep.txt'
        [IO.File]::WriteAllText($ProtectedFile, 'keep')
        [IO.File]::WriteAllText((Join-Path $TempPath 'delete.tmp'), 'delete')
        $Fixture = [pscustomobject]@{
            Documents = $Documents
            ProtectedFile = $ProtectedFile
            TempPath = $TempPath
            Junction = Join-Path $TempPath 'protected-link'
        }
        $env:LOCALAPPDATA = $LocalAppData
        $env:TEMP = $TempPath
        $env:TMP = $TempPath
        $env:USERPROFILE = Join-Path $Root 'Profile'

        $SessionRoot = Join-Path $Root 'sessions'
        $SessionId = 'clean-test-12345678'
        $session = New-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
        $session = Set-CdsSessionState -Session $session -NextState 'awaiting-decision'
        Write-CdsJsonAtomic -Path (Join-Path $session.root 'session.json') -InputObject $session
        Write-CdsJsonAtomic -Path $session.artifacts.scan -InputObject ([pscustomobject]@{
            schema_version = 2
            session_id = $SessionId
            rows = @(
                [pscustomobject]@{ id='temp-user'; tier='GREEN'; path=$TempPath },
                [pscustomobject]@{ id='thumbcache'; tier='GREEN'; path=(Join-Path $LocalAppData 'Microsoft\Windows\Explorer') },
                [pscustomobject]@{ id='wu-cache'; tier='GREEN'; path=$Root }
            )
        })
        & $Decide -SessionId $SessionId -ApproveClean temp-user,thumbcache,wu-cache `
            -Protect $Documents -SessionRoot $SessionRoot | Out-Null
    }

    AfterEach {
        if ($Fixture -and (Test-Path -LiteralPath $Fixture.Junction)) {
            [void][CdsTestNative]::RemoveDirectory($Fixture.Junction)
        }
        $env:TEMP = $OldEnvironment.TEMP
        $env:TMP = $OldEnvironment.TMP
        $env:LOCALAPPDATA = $OldEnvironment.LOCALAPPDATA
        $env:USERPROFILE = $OldEnvironment.USERPROFILE
    }

    It 'refuses Execute without SessionId' {
        { & $Clean -Execute -Include temp-user -SessionRoot $SessionRoot } |
            Should -Throw '*SessionId*'
    }

    It 'refuses TEMP redirected to Documents' {
        $old = $env:TEMP
        try {
            $env:TEMP = $Fixture.Documents
            { & $Clean -Execute -SessionId $SessionId -Include temp-user -SessionRoot $SessionRoot } |
                Should -Throw '*outside*allowed root*'
            $action = Get-Content -LiteralPath (Join-Path $SessionRoot "$SessionId\actions.jsonl") | ConvertFrom-Json
            $action.status | Should -Be 'skipped'
        } finally { $env:TEMP = $old }
    }

    It 'refuses TEMP and LOCALAPPDATA redirected together outside the scan baseline' {
        $alternateRoot = Join-Path $Root 'alternate-sessions'
        $alternateId = 'clean-alt-12345678'
        $alternate = New-CdsSession -SessionId $alternateId -SessionRoot $alternateRoot
        $alternate = Set-CdsSessionState -Session $alternate -NextState 'awaiting-decision'
        Write-CdsJsonAtomic -Path (Join-Path $alternate.root 'session.json') -InputObject $alternate
        Write-CdsJsonAtomic -Path $alternate.artifacts.scan -InputObject ([pscustomobject]@{
            schema_version=2; session_id=$alternateId
            rows=@([pscustomobject]@{ id='temp-user'; tier='GREEN'; path=$Fixture.TempPath })
        })
        & $Decide -SessionId $alternateId -ApproveClean temp-user -SessionRoot $alternateRoot | Out-Null

        $redirected = Join-Path $Fixture.Documents 'RedirectedTemp'
        New-Item -ItemType Directory -Path $redirected -Force | Out-Null
        $sentinel = Join-Path $redirected 'must-stay.txt'
        [IO.File]::WriteAllText($sentinel, 'keep')
        $oldTemp = $env:TEMP
        $oldLocal = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $Fixture.Documents
            $env:TEMP = $redirected
            { & $Clean -Execute -SessionId $alternateId -Include temp-user -SessionRoot $alternateRoot } |
                Should -Throw '*scan baseline*'
            Test-Path -LiteralPath $sentinel | Should -BeTrue
        } finally {
            $env:TEMP = $oldTemp
            $env:LOCALAPPDATA = $oldLocal
        }
    }

    It 'skips a target containing a junction to protected data' {
        New-Item -ItemType Junction -Path $Fixture.Junction -Target $Fixture.Documents | Out-Null
        $result = & $Clean -Execute -SessionId $SessionId -Include temp-user -SessionRoot $SessionRoot
        $result.status | Should -Be 'skipped'
        Test-Path $Fixture.ProtectedFile | Should -BeTrue
    }

    It 'reports completed and keeps the catalog directory' {
        $result = & $Clean -Execute -SessionId $SessionId -Include temp-user -SessionRoot $SessionRoot
        $result.status | Should -Be 'completed'
        Test-Path -LiteralPath $Fixture.TempPath -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Fixture.TempPath 'delete.tmp') | Should -BeFalse
        $action = Get-Content -LiteralPath (Join-Path $SessionRoot "$SessionId\actions.jsonl") | ConvertFrom-Json
        $action.status | Should -Be 'completed'
        $action.schema_version | Should -Be 2
    }

    It 'reports not-found when the catalog target does not exist' {
        Remove-Item -LiteralPath $Fixture.TempPath -Recurse -Force
        $result = & $Clean -Execute -SessionId $SessionId -Include temp-user -SessionRoot $SessionRoot
        $result.status | Should -Be 'not-found'
    }

    It 'deletes only thumbnail and icon cache files' {
        $explorer = Join-Path $LocalAppData 'Microsoft\Windows\Explorer'
        New-Item -ItemType Directory -Path $explorer -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $explorer 'thumbcache_32.db'), 'cache')
        [IO.File]::WriteAllText((Join-Path $explorer 'iconcache_32.db'), 'cache')
        [IO.File]::WriteAllText((Join-Path $explorer 'keep.db'), 'keep')
        $result = & $Clean -Execute -SessionId $SessionId -Include thumbcache -SessionRoot $SessionRoot
        $result.status | Should -Be 'completed'
        Test-Path -LiteralPath (Join-Path $explorer 'keep.db') | Should -BeTrue
    }

    It 'reports partial when one file is locked and another is removed' {
        $locked = Join-Path $Fixture.TempPath 'locked.tmp'
        [IO.File]::WriteAllText($locked, 'locked')
        $stream = New-Object IO.FileStream($locked, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            $result = & $Clean -Execute -SessionId $SessionId -Include temp-user -SessionRoot $SessionRoot
            $result.status | Should -Be 'partial'
            $result.freed_bytes | Should -BeGreaterThan 0
            Test-Path -LiteralPath $locked | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $Fixture.TempPath 'delete.tmp') | Should -BeFalse
        } finally { $stream.Dispose() }
    }

    It 'restores a service stopped before another service state check fails' {
        $oldSystemRoot = $env:SystemRoot
        $env:SystemRoot = Join-Path $Root 'Windows'
        $download = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
        New-Item -ItemType Directory -Path $download -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $download 'update.bin'), 'cache')
        Mock Test-CdsElevated { $true }
        Mock Get-Service {
            if ($Name -eq 'wuauserv') { return [pscustomobject]@{ Status='Running' } }
            throw 'bits unavailable'
        }
        Mock Stop-Service {}
        Mock Start-Service {}
        Mock Get-CimInstance { [pscustomobject]@{ StartMode='Auto' } }

        try {
            $result = & $Clean -Execute -SessionId $SessionId -Include wu-cache -SessionRoot $SessionRoot
        } finally { $env:SystemRoot = $oldSystemRoot }

        $result.status | Should -Be 'failed'
        Should -Invoke Start-Service -Times 1 -ParameterFilter { $Name -eq 'wuauserv' }
    }

    It 'writes a failed action and throws when service restoration fails' {
        $oldSystemRoot = $env:SystemRoot
        $env:SystemRoot = Join-Path $Root 'Windows'
        $download = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
        New-Item -ItemType Directory -Path $download -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $download 'update.bin'), 'cache')
        Mock Test-CdsElevated { $true }
        Mock Get-Service {
            if ($Name -eq 'wuauserv') { return [pscustomobject]@{ Status='Running' } }
            return [pscustomobject]@{ Status='Stopped' }
        }
        Mock Get-CimInstance { [pscustomobject]@{ StartMode='Auto' } }
        Mock Stop-Service {}
        Mock Start-Service { throw 'restore denied' }
        try {
            { & $Clean -Execute -SessionId $SessionId -Include wu-cache -SessionRoot $SessionRoot } |
                Should -Throw '*restore*'
        } finally { $env:SystemRoot = $oldSystemRoot }

        $action = Get-Content -LiteralPath (Join-Path $SessionRoot "$SessionId\actions.jsonl") | ConvertFrom-Json
        $action.status | Should -Be 'failed'
    }
}
