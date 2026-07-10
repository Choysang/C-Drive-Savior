$script:SessionTransitions = @{
    'scanned'           = @('awaiting-decision', 'failed')
    'awaiting-decision' = @('approved', 'failed')
    'approved'          = @('executing', 'failed')
    'executing'         = @('approved', 'reported', 'failed')
    'reported'          = @()
    'failed'            = @('awaiting-decision', 'approved')
}

function Test-CdsPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot
    )

    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ([string]::Equals($candidate, $root, [StringComparison]::OrdinalIgnoreCase)) { return $true }

    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-CdsSafePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot
    )

    if ($Path.StartsWith('\') -or $AllowedRoot.StartsWith('\')) {
        throw 'UNC and device paths are not allowed.'
    }

    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $driveRoot = [IO.Path]::GetPathRoot($candidate).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)

    if ([string]::Equals($candidate, $driveRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'A drive root cannot be used as an operation target.'
    }
    if (-not (Test-CdsPathWithin -Path $candidate -AllowedRoot $root)) {
        throw "Path is outside the allowed root: $root"
    }
    if ([string]::Equals($candidate, $root, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The catalog root itself cannot be used as an operation target.'
    }

    $current = $candidate
    while ($current -and (Test-CdsPathWithin -Path $current -AllowedRoot $root)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Path crosses a reparse point: $current"
            }
        }
        if ([string]::Equals($current, $root, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = [IO.Path]::GetDirectoryName($current)
    }

    return $candidate
}

function Read-CdsJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file was not found: $Path"
    }
    return Get-Content -Raw -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Write-CdsJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$InputObject
    )

    $json = $InputObject | ConvertTo-Json -Depth 100 -ErrorAction Stop
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }

    $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($fullPath), [guid]::NewGuid().ToString('N'))
    $backup = Join-Path $directory ('.{0}.{1}.bak' -f [IO.Path]::GetFileName($fullPath), [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding $false))
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            [IO.File]::Replace($temporary, $fullPath, $backup)
        } else {
            [IO.File]::Move($temporary, $fullPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backup) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-CdsSession {
    [CmdletBinding()]
    param(
        [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions",
        [string]$SessionId = ('{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 8))
    )

    if ($SessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$') {
        throw 'Session ID has an invalid format.'
    }
    $root = [IO.Path]::GetFullPath($SessionRoot)
    $sessionPath = Join-Path $root $SessionId
    if (Test-Path -LiteralPath $sessionPath) { throw "Session already exists: $SessionId" }
    New-Item -ItemType Directory -Path $sessionPath -Force -ErrorAction Stop | Out-Null

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $session = [pscustomobject][ordered]@{
        schema_version = 2
        session_id = $SessionId
        state = 'scanned'
        created_at = $now
        updated_at = $now
        root = $sessionPath
        artifacts = [pscustomobject][ordered]@{
            scan = (Join-Path $sessionPath 'scan.json')
            decisions = (Join-Path $sessionPath 'decisions.json')
            actions = (Join-Path $sessionPath 'actions.jsonl')
            panel = (Join-Path $sessionPath 'panel.html')
            report = (Join-Path $sessionPath 'report.html')
        }
    }
    Write-CdsJsonAtomic -Path (Join-Path $sessionPath 'session.json') -InputObject $session
    return $session
}

function Get-CdsSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions"
    )

    if ($SessionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$') {
        throw 'Session ID has an invalid format.'
    }
    return Read-CdsJson -Path (Join-Path (Join-Path ([IO.Path]::GetFullPath($SessionRoot)) $SessionId) 'session.json')
}

function Set-CdsSessionState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$NextState
    )

    $current = [string]$Session.state
    if (-not $script:SessionTransitions.ContainsKey($current) -or
        $script:SessionTransitions[$current] -notcontains $NextState) {
        throw "Invalid session state transition: $current -> $NextState"
    }
    $Session.state = $NextState
    if ($Session.PSObject.Properties['updated_at']) {
        $Session.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    return $Session
}

function Assert-CdsApprovedItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$ItemId,
        [Parameter(Mandatory)][ValidateSet('clean', 'move')][string]$Action,
        [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions",
        [string]$TargetPath
    )

    $session = Get-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
    if ($session.state -notin @('approved', 'executing')) {
        throw "Session is not approved for execution: $($session.state)"
    }
    $decisions = Read-CdsJson -Path $session.artifacts.decisions
    $approvedIds = if ($Action -eq 'clean') { @($decisions.approved_clean_ids) } else { @($decisions.approved_move_ids) }
    if ($approvedIds -notcontains $ItemId) {
        throw "Item is not approved for ${Action}: $ItemId"
    }
    if ($TargetPath) {
        $target = [IO.Path]::GetFullPath($TargetPath)
        foreach ($protected in @($decisions.protected_paths)) {
            if (Test-CdsPathWithin -Path $target -AllowedRoot $protected) {
                throw "Target is nested under a protected path: $protected"
            }
        }
    }
    return $true
}

function Write-CdsAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)]$ActionRecord,
        [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions"
    )

    $session = Get-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
    $line = $ActionRecord | ConvertTo-Json -Depth 100 -Compress -ErrorAction Stop
    $encoding = New-Object Text.UTF8Encoding $false
    $stream = New-Object IO.FileStream($session.artifacts.actions, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $writer = New-Object IO.StreamWriter($stream, $encoding)
        try { $writer.WriteLine($line) } finally { $writer.Dispose() }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Test-CdsElevated {
    [CmdletBinding()]
    param()

    if ($env:OS -ne 'Windows_NT') { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function @(
    'Resolve-CdsSafePath',
    'Test-CdsPathWithin',
    'Read-CdsJson',
    'Write-CdsJsonAtomic',
    'New-CdsSession',
    'Get-CdsSession',
    'Set-CdsSessionState',
    'Assert-CdsApprovedItem',
    'Write-CdsAction',
    'Test-CdsElevated'
)
