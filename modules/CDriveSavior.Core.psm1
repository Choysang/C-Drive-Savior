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

function Get-CdsCatalogRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    switch ($Name) {
        'localappdata' { return [IO.Path]::GetFullPath($env:LOCALAPPDATA) }
        'profile'      { return [IO.Path]::GetFullPath($env:USERPROFILE) }
        'systemroot'   { return [IO.Path]::GetFullPath($env:SystemRoot) }
        'programdata'  { return [IO.Path]::GetFullPath($env:ProgramData) }
        default        { throw "Unknown catalog root: $Name" }
    }
}

function Resolve-CdsCatalogSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Resolver)

    if ($Resolver -in @('delivery-optimization', 'recycle-bin')) {
        return [pscustomobject]@{ Pattern=$null; AllowedRoot=$null; Special=$Resolver }
    }
    $parts = $Resolver.Split(':', 2)
    if ($parts.Count -ne 2) { throw "Invalid catalog resolver: $Resolver" }
    if ($parts[0] -eq 'temp') {
        return [pscustomobject]@{
            Pattern=[IO.Path]::GetFullPath($env:TEMP)
            AllowedRoot=(Get-CdsCatalogRoot 'localappdata')
            Special=$null
        }
    }
    $root = Get-CdsCatalogRoot $parts[0]
    $pattern = if ($parts[1]) {
        Join-Path $root ($parts[1].Replace('/', [IO.Path]::DirectorySeparatorChar))
    } else { $root }
    return [pscustomobject]@{ Pattern=$pattern; AllowedRoot=$root; Special=$null }
}

function Expand-CdsCatalogSpec {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Spec)

    if ($Spec.Special) { return @() }
    [void](Resolve-CdsSafePath -Path $Spec.Pattern -AllowedRoot $Spec.AllowedRoot)
    if ($Spec.Pattern -like '*[*]*') {
        return @(Resolve-Path -Path $Spec.Pattern -ErrorAction SilentlyContinue | ForEach-Object {
            Resolve-CdsSafePath -Path $_.Path -AllowedRoot $Spec.AllowedRoot
        })
    }
    return @([IO.Path]::GetFullPath($Spec.Pattern))
}

function Read-CdsJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file was not found: $Path"
    }
    return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
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
    if ($decisions.session_id -ne $SessionId) {
        throw 'Decision session ID does not match the requested session.'
    }
    $approvedIds = if ($Action -eq 'clean') { @($decisions.approved_clean_ids) } else { @($decisions.approved_move_ids) }
    if ($approvedIds -notcontains $ItemId) {
        throw "Item is not approved for ${Action}: $ItemId"
    }
    if ($TargetPath) {
        $target = [IO.Path]::GetFullPath($TargetPath)
        foreach ($protected in @($decisions.protected_paths)) {
            if ((Test-CdsPathWithin -Path $target -AllowedRoot $protected) -or
                (Test-CdsPathWithin -Path $protected -AllowedRoot $target)) {
                throw "Target is nested under a protected path: $protected"
            }
        }
        $scan = Read-CdsJson -Path $session.artifacts.scan
        if ($scan.session_id -ne $SessionId) {
            throw 'Scan session ID does not match the requested session.'
        }
        $matchingRows = if ($Action -eq 'clean') {
            @($scan.rows | Where-Object { $_.action_id -eq $ItemId -or (-not $_.PSObject.Properties['action_id'] -and $_.id -eq $ItemId) })
        } else {
            @($scan.rows | Where-Object { $_.id -eq $ItemId })
        }
        $matchingRows = @($matchingRows)
        if ($matchingRows.Count -lt 1) {
            throw "Approved item does not have a scan baseline: $ItemId"
        }
        $withinBaseline = $false
        foreach ($row in $matchingRows) {
            $baseline = [IO.Path]::GetFullPath([string]$row.path)
            if (Test-CdsPathWithin -Path $target -AllowedRoot $baseline) { $withinBaseline = $true; break }
        }
        if (-not $withinBaseline) {
            throw 'Target is outside every approved scan baseline.'
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
    'Get-CdsCatalogRoot',
    'Resolve-CdsCatalogSpec',
    'Expand-CdsCatalogSpec',
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
