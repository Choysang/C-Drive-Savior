BeforeAll {
    $Migrate = Join-Path $PSScriptRoot '..\..\scripts\migrate.ps1'
    $Decide = Join-Path $PSScriptRoot '..\..\scripts\decide.ps1'
    Import-Module "$PSScriptRoot\..\..\modules\CDriveSavior.Core.psm1" -Force
    function Get-CdsVolumeInfo { param([string]$Path) throw 'test stub was not mocked' }
    function Invoke-CdsRobocopy {
        param([string]$SourcePath, [string]$Destination)
        throw 'test stub was not mocked'
    }
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

Describe 'migrate.ps1 staged migration' {
    BeforeEach {
        $Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $Source = Join-Path $Root 'source'
        $Dest = Join-Path $Root 'destination'
        New-Item -ItemType Directory -Path (Join-Path $Source 'nested') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $Source 'one.txt'), 'one')
        [IO.File]::WriteAllText((Join-Path $Source 'nested\two.txt'), 'two')

        $SessionRoot = Join-Path $Root 'sessions'
        $SessionId = 'migrate-test-12345678'
        $session = New-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
        $session = Set-CdsSessionState -Session $session -NextState 'awaiting-decision'
        Write-CdsJsonAtomic -Path (Join-Path $session.root 'session.json') -InputObject $session
        Write-CdsJsonAtomic -Path $session.artifacts.scan -InputObject ([pscustomobject]@{
            schema_version=2; session_id=$SessionId
            rows=@([pscustomobject]@{ id='documents'; tier='MOVE'; path=$Source })
        })
        & $Decide -SessionId $SessionId -ApproveMove documents -SessionRoot $SessionRoot | Out-Null

        Mock Get-CdsVolumeInfo {
            if ([string]::Equals([IO.Path]::GetFullPath($Path), [IO.Path]::GetFullPath($Source), [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Root='C:\'; IsSystem=$true; IsFixed=$true; FreeBytes=[long]10GB }
            }
            return [pscustomobject]@{ Root='D:\'; IsSystem=$false; IsFixed=$true; FreeBytes=[long]10GB }
        }
        Mock Invoke-CdsRobocopy {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            Get-ChildItem -LiteralPath $SourcePath -Force | Copy-Item -Destination $Destination -Recurse -Force
            Get-ChildItem -LiteralPath $SourcePath -Recurse -Force | ForEach-Object {
                $relative = $_.FullName.Substring($SourcePath.Length).TrimStart('\')
                $copy = Get-Item -LiteralPath (Join-Path $Destination $relative) -Force
                $copy.LastWriteTimeUtc = $_.LastWriteTimeUtc
                $copy.Attributes = $_.Attributes
                Set-Acl -LiteralPath $copy.FullName -AclObject (Get-Acl -LiteralPath $_.FullName)
            }
            return 1
        }
    }

    It 'rejects identical source and destination' {
        { & $Migrate -Stage -Source $Source -Dest $Source -SessionId $SessionId -SessionRoot $SessionRoot } |
            Should -Throw '*same path*'
    }

    It 'rejects destination inside source' {
        { & $Migrate -Stage -Source $Source -Dest (Join-Path $Source 'copy') `
            -SessionId $SessionId -SessionRoot $SessionRoot } | Should -Throw '*nested*'
    }

    It 'rejects a OneDrive-managed destination' {
        $cloudDest = Join-Path $Root 'OneDrive\destination'
        { & $Migrate -Stage -Source $Source -Dest $cloudDest -SessionId $SessionId -SessionRoot $SessionRoot } |
            Should -Throw '*OneDrive*'
    }

    It 'stages a verified copy without deleting source' {
        $result = & $Migrate -Stage -Source $Source -Dest $Dest -SessionId $SessionId -SessionRoot $SessionRoot
        $result.status | Should -Be 'completed'
        Test-Path -LiteralPath $Source -PathType Container | Should -BeTrue
        Test-Path -LiteralPath $Dest -PathType Container | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $SessionRoot "$SessionId\migration-manifest.json") | Should -BeTrue
    }

    It 'does not finalize when destination contains masking extra files' {
        & $Migrate -Stage -Source $Source -Dest $Dest -SessionId $SessionId -SessionRoot $SessionRoot | Out-Null
        New-Item -ItemType File -Path (Join-Path $Dest 'extra.bin') | Out-Null
        { & $Migrate -Finalize -Source $Source -Dest $Dest -DeleteSource `
            -SessionId $SessionId -SessionRoot $SessionRoot } | Should -Throw '*manifest mismatch*'
        Test-Path $Source | Should -BeTrue
    }

    It 'does not finalize after source changes' {
        & $Migrate -Stage -Source $Source -Dest $Dest -SessionId $SessionId -SessionRoot $SessionRoot | Out-Null
        Add-Content -LiteralPath (Join-Path $Source 'changed.txt') -Value 'changed'
        { & $Migrate -Finalize -Source $Source -Dest $Dest -DeleteSource `
            -SessionId $SessionId -SessionRoot $SessionRoot } | Should -Throw '*source changed*'
        Test-Path $Source | Should -BeTrue
    }

    It 'deletes source only after fresh manifests and hashes match' {
        & $Migrate -Stage -Source $Source -Dest $Dest -SessionId $SessionId -SessionRoot $SessionRoot | Out-Null
        $result = & $Migrate -Finalize -Source $Source -Dest $Dest -DeleteSource `
            -SessionId $SessionId -SessionRoot $SessionRoot
        $result.status | Should -Be 'completed'
        Test-Path $Source | Should -BeFalse
        Test-Path (Join-Path $Dest 'one.txt') | Should -BeTrue
        $result.undo.kind | Should -Be 'copy-back'
    }

    It 'detects same-size destination content changes with hashes' {
        & $Migrate -Stage -Source $Source -Dest $Dest -SessionId $SessionId -SessionRoot $SessionRoot | Out-Null
        $sourceFile = Get-Item -LiteralPath (Join-Path $Source 'one.txt')
        [IO.File]::WriteAllText((Join-Path $Dest 'one.txt'), 'eno')
        (Get-Item -LiteralPath (Join-Path $Dest 'one.txt')).LastWriteTimeUtc = $sourceFile.LastWriteTimeUtc
        { & $Migrate -Finalize -Source $Source -Dest $Dest -DeleteSource `
            -SessionId $SessionId -SessionRoot $SessionRoot } | Should -Throw '*hash mismatch*'
        Test-Path $Source | Should -BeTrue
    }

    It 'records a failed finalize when source deletion is blocked' {
        & $Migrate -Stage -Source $Source -Dest $Dest -SessionId $SessionId -SessionRoot $SessionRoot | Out-Null
        Mock Remove-Item { throw 'source locked' } -ParameterFilter { $LiteralPath -eq $Source -and $Recurse }
        { & $Migrate -Finalize -Source $Source -Dest $Dest -DeleteSource `
            -SessionId $SessionId -SessionRoot $SessionRoot } | Should -Throw '*source deletion*'
        Test-Path $Source | Should -BeTrue
        Test-Path $Dest | Should -BeTrue
        $actions = @(Get-Content -LiteralPath (Join-Path $SessionRoot "$SessionId\actions.jsonl") | ConvertFrom-Json)
        $actions[-1].status | Should -Be 'failed'
    }

    It 'creates and validates a junction with structured undo steps' {
        & $Migrate -Stage -Source $Source -Dest $Dest -SessionId $SessionId -SessionRoot $SessionRoot | Out-Null
        try {
            $result = & $Migrate -Finalize -Source $Source -Dest $Dest -Junction `
                -SessionId $SessionId -SessionRoot $SessionRoot
            $result.status | Should -Be 'completed'
            (Get-Item -LiteralPath $Source -Force).LinkType | Should -Be 'Junction'
            $result.undo.kind | Should -Be 'junction-migration'
            $result.undo.steps.action | Should -Contain 'remove-junction'
            $result.undo.steps.action | Should -Contain 'copy-back'
        } finally {
            if (Test-Path -LiteralPath $Source) { [void][CdsTestNative]::RemoveDirectory($Source) }
        }
    }
}
