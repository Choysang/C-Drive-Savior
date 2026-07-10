BeforeAll {
    Import-Module "$PSScriptRoot\..\..\modules\CDriveSavior.Core.psm1" -Force
}

Describe 'Resolve-CdsSafePath' {
    It 'rejects a drive root' {
        { Resolve-CdsSafePath -Path 'C:\' -AllowedRoot 'C:\Users\demo\AppData\Local\Temp' } |
            Should -Throw '*root*'
    }

    It 'rejects sibling prefix confusion' {
        { Resolve-CdsSafePath -Path 'C:\Users\demo\Documents2' -AllowedRoot 'C:\Users\demo\Documents' } |
            Should -Throw '*outside*'
    }

    It 'rejects a descendant reparse point' -Skip:($env:OS -ne 'Windows_NT') {
        $root = Join-Path $TestDrive 'cache'
        $target = Join-Path $TestDrive 'documents'
        New-Item -ItemType Directory -Path $root,$target | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $root 'link') -Target $target | Out-Null
        { Resolve-CdsSafePath -Path (Join-Path $root 'link') -AllowedRoot $root } |
            Should -Throw '*reparse*'
    }
}

Describe 'Set-CdsSessionState' {
    It 'rejects approved to scanned regression' {
        $session = [pscustomobject]@{ state = 'approved' }
        { Set-CdsSessionState -Session $session -NextState 'scanned' } |
            Should -Throw '*transition*'
    }
}

Describe 'Write-CdsJsonAtomic' {
    It 'replaces an existing JSON file' {
        $path = Join-Path $TestDrive 'state.json'
        Write-CdsJsonAtomic -Path $path -InputObject ([pscustomobject]@{ value = 1 })
        Write-CdsJsonAtomic -Path $path -InputObject ([pscustomobject]@{ value = 2 })
        (Read-CdsJson -Path $path).value | Should -Be 2
    }
}
