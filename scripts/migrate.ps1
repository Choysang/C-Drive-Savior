# migrate.ps1 - staged, session-gated folder migration for C Drive Savior.
[CmdletBinding(DefaultParameterSetName='Stage')]
param(
    [Parameter(Mandatory, ParameterSetName='Stage')][switch]$Stage,
    [Parameter(Mandatory, ParameterSetName='Finalize')][switch]$Finalize,
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Dest,
    [Parameter(Mandatory)][string]$SessionId,
    [Parameter(ParameterSetName='Finalize')][switch]$Junction,
    [Parameter(ParameterSetName='Finalize')][switch]$DeleteSource,
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions"
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $skillRoot 'modules\CDriveSavior.Core.psm1') -Force
if (-not ('FileIdentity' -as [type])) { Add-Type -Path (Join-Path $skillRoot 'native\FileIdentity.cs') }

if (-not (Get-Command Get-CdsVolumeInfo -ErrorAction SilentlyContinue)) {
    function Get-CdsVolumeInfo {
        param([Parameter(Mandatory)][string]$Path)
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        $device = $root.TrimEnd('\')
        $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $device) -ErrorAction Stop
        return [pscustomobject]@{
            Root=$root
            IsSystem=[string]::Equals($device, $env:SystemDrive, [StringComparison]::OrdinalIgnoreCase)
            IsFixed=([int]$disk.DriveType -eq 3)
            FreeBytes=[long]$disk.FreeSpace
        }
    }
}

if (-not (Get-Command Invoke-CdsRobocopy -ErrorAction SilentlyContinue)) {
    function Invoke-CdsRobocopy {
        param(
            [Parameter(Mandatory)][string]$SourcePath,
            [Parameter(Mandatory)][string]$Destination
        )
        & robocopy $SourcePath $Destination /E /COPY:DATS /DCOPY:DAT /R:1 /W:1 /XJ /MT:8 /NFL /NDL /NP | Out-Null
        return [int]$LASTEXITCODE
    }
}

function Get-RelativePath([string]$Root, [string]$Path) {
    $rootUri = New-Object Uri(([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'))
    $pathUri = New-Object Uri([IO.Path]::GetFullPath($Path))
    return [Uri]::UnescapeDataString($rootUri.MakeRelativeUri($pathUri).ToString()).Replace('/', '\')
}

function Get-CdsStreams([string]$Path) {
    if (-not (Get-Item -LiteralPath $Path -Force).PSIsContainer) {
        return @(Get-Item -LiteralPath $Path -Stream * -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Stream } | Sort-Object -Unique)
    }
    return @()
}

function Get-CdsManifest([string]$Root, [switch]$IncludeHash) {
    $entries = New-Object System.Collections.Generic.List[object]
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($current)) {
            $item = Get-Item -LiteralPath $path -Force
            $attributes = $item.Attributes
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "reparse item blocks migration: $path"
            }
            if ($attributes -band [IO.FileAttributes]::Encrypted) {
                throw "EFS item blocks migration: $path"
            }
            if ($attributes -band [IO.FileAttributes]::SparseFile) {
                throw "sparse item blocks migration: $path"
            }
            $isDirectory = [bool]$item.PSIsContainer
            if ($isDirectory) { $stack.Push($path) }
            $hash = $null
            if ($IncludeHash -and -not $isDirectory) {
                $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            $acl = Get-Acl -LiteralPath $path
            $entries.Add([pscustomobject][ordered]@{
                relative_path=Get-RelativePath -Root $Root -Path $path
                kind=if($isDirectory){'directory'}else{'file'}
                length=if($isDirectory){[long]0}else{[long]$item.Length}
                last_write_utc=$item.LastWriteTimeUtc.ToString('o')
                attributes=[int]$attributes
                streams=@(Get-CdsStreams $path)
                acl_sddl=[string]$acl.Sddl
                sha256=$hash
            })
        }
    }
    return @($entries | Sort-Object relative_path | ForEach-Object { $_ })
}

function Get-CdsAllocatedBytes([string]$Root, $Manifest) {
    [long]$total = 0
    foreach ($entry in @($Manifest | Where-Object kind -eq 'file')) {
        $path = Join-Path $Root ([string]$entry.relative_path)
        $total += [long]([FileIdentity]::Read($path).AllocatedBytes)
    }
    return $total
}

function Convert-CdsManifestCanonical($Manifest) {
    return @($Manifest | ForEach-Object {
        $timestamp = if ($_.last_write_utc -is [datetime]) {
            ([datetime]$_.last_write_utc).ToUniversalTime().ToString('o')
        } else {
            [datetime]::Parse([string]$_.last_write_utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o')
        }
        [pscustomobject][ordered]@{
            relative_path=[string]$_.relative_path; kind=[string]$_.kind; length=[long]$_.length
            last_write_utc=$timestamp; attributes=[int]$_.attributes
            streams=@($_.streams | ForEach-Object { [string]$_ } | Sort-Object)
            acl_sddl=[string]$_.acl_sddl; sha256=if($null -eq $_.sha256){$null}else{[string]$_.sha256}
        }
    } | Sort-Object relative_path)
}

function Test-CdsManifestEqual($Left, $Right) {
    $leftJson = @(Convert-CdsManifestCanonical $Left) | ConvertTo-Json -Depth 10 -Compress
    $rightJson = @(Convert-CdsManifestCanonical $Right) | ConvertTo-Json -Depth 10 -Compress
    return [string]::Equals($leftJson, $rightJson, [StringComparison]::Ordinal)
}

function Get-CdsManifestDifference($Left, $Right) {
    $leftEntries = @(Convert-CdsManifestCanonical $Left)
    $rightEntries = @(Convert-CdsManifestCanonical $Right)
    if ($leftEntries.Count -ne $rightEntries.Count) {
        return "entry count $($leftEntries.Count) != $($rightEntries.Count)"
    }
    $fields = @('relative_path','kind','length','last_write_utc','attributes','acl_sddl','sha256')
    for ($index=0; $index -lt $leftEntries.Count; $index++) {
        foreach ($field in $fields) {
            if ([string]$leftEntries[$index].$field -cne [string]$rightEntries[$index].$field) {
                return "entry $index field $field differs: '$($leftEntries[$index].$field)' != '$($rightEntries[$index].$field)'"
            }
        }
        if ((@($leftEntries[$index].streams) -join '|') -cne (@($rightEntries[$index].streams) -join '|')) {
            return "entry $index field streams differs"
        }
    }
    return 'serialized representation differs'
}

function New-MigrationAction([string]$ItemId, [string]$Operation, [string]$SourcePath, [string]$Destination) {
    return [pscustomobject][ordered]@{
        schema_version=2; session_id=$SessionId; tool='migrate.ps1'; item_id=$ItemId
        action=$Operation; status='planned'; started_at=(Get-Date).ToUniversalTime().ToString('o'); finished_at=$null
        before_bytes=$null; after_bytes=$null; freed_bytes=$null
        source=$SourcePath; destination=$Destination; error_code=$null; error_message=$null
        undo=[pscustomobject][ordered]@{ kind='none'; steps=@() }
    }
}

function Complete-MigrationAction($Action, [string]$Status, $Before, $After, [string]$ErrorCode, [string]$ErrorMessage, $Undo) {
    $Action.status=$Status; $Action.before_bytes=$Before; $Action.after_bytes=$After
    if ($null -ne $Before -and $null -ne $After) {
        $freed=[long]$Before-[long]$After; $Action.freed_bytes=if($freed -gt 0){$freed}else{[long]0}
    }
    $Action.error_code=$ErrorCode; $Action.error_message=$ErrorMessage
    if ($Undo) { $Action.undo=$Undo }
    $Action.finished_at=(Get-Date).ToUniversalTime().ToString('o')
    return $Action
}

function Write-AndThrowMigration($Action, [string]$Code, [string]$Message, $Before, $After) {
    $Action = Complete-MigrationAction $Action 'failed' $Before $After $Code $Message $Action.undo
    Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $Action
    throw $Message
}

$sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd('\')
$destPath = [IO.Path]::GetFullPath($Dest).TrimEnd('\')
if ([string]::Equals($sourcePath, $destPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source and destination are the same path.'
}
if ((Test-CdsPathWithin -Path $destPath -AllowedRoot $sourcePath) -or
    (Test-CdsPathWithin -Path $sourcePath -AllowedRoot $destPath)) {
    throw 'Source and destination cannot be nested.'
}
if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Source was not found: $sourcePath" }
$sourceItem = Get-Item -LiteralPath $sourcePath -Force
if ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source is a reparse point.' }

$sourceLower = $sourcePath.ToLowerInvariant()
foreach ($blocked in @('c:\windows','c:\program files','c:\program files (x86)','c:\programdata\package cache')) {
    if ($sourceLower -eq $blocked -or $sourceLower.StartsWith($blocked + '\')) {
        throw "System/install path cannot be migrated: $sourcePath"
    }
}
if ($sourceLower -like '*\onedrive\*' -or $sourceLower.EndsWith('\onedrive')) {
    throw 'OneDrive-managed paths must be moved through OneDrive settings.'
}
$destLower = $destPath.ToLowerInvariant()
if ($destLower -like '*\onedrive\*' -or $destLower.EndsWith('\onedrive')) {
    throw 'OneDrive-managed destinations are not allowed.'
}

$session = Get-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
$scan = Read-CdsJson -Path $session.artifacts.scan
$moveRows = @($scan.rows | Where-Object {
    $_.tier -eq 'MOVE' -and [string]::Equals([IO.Path]::GetFullPath([string]$_.path).TrimEnd('\'), $sourcePath, [StringComparison]::OrdinalIgnoreCase)
})
if ($moveRows.Count -ne 1) { throw 'Source does not match exactly one approved MOVE scan row.' }
$itemId = [string]$moveRows[0].id
Assert-CdsApprovedItem -SessionId $SessionId -ItemId $itemId -Action move -SessionRoot $SessionRoot -TargetPath $sourcePath | Out-Null

$sourceVolume = Get-CdsVolumeInfo -Path $sourcePath
$destVolume = Get-CdsVolumeInfo -Path $destPath
if (-not $sourceVolume.IsSystem) { throw 'Source must be on the system volume.' }
if ($destVolume.IsSystem -or -not $destVolume.IsFixed) { throw 'Destination must be on a fixed non-system volume.' }
if ([string]::Equals($sourceVolume.Root, $destVolume.Root, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Destination must be on a different volume.'
}

$manifestPath = Join-Path $session.root 'migration-manifest.json'
$sessionWasExecuting = $false
if ($session.state -eq 'approved') {
    $session = Set-CdsSessionState -Session $session -NextState 'executing'
    Write-CdsJsonAtomic -Path (Join-Path $session.root 'session.json') -InputObject $session
    $sessionWasExecuting = $true
} elseif ($session.state -eq 'executing') { $sessionWasExecuting = $true }

try {
    if ($Stage) {
        $action = New-MigrationAction -ItemId $itemId -Operation 'stage-move' -SourcePath $sourcePath -Destination $destPath
        if (Test-Path -LiteralPath $destPath) {
            $destinationItems = @([IO.Directory]::EnumerateFileSystemEntries($destPath))
            if ($destinationItems.Count -gt 0) {
                Write-AndThrowMigration $action 'destination-not-empty' 'Destination must be absent or empty.' $null $null
            }
        }
        $sourceManifest = @(Get-CdsManifest -Root $sourcePath)
        [long]$sourceBytes = ($sourceManifest | Where-Object kind -eq 'file' | Measure-Object length -Sum).Sum
        [long]$sourceAllocatedBytes = Get-CdsAllocatedBytes -Root $sourcePath -Manifest $sourceManifest
        if ($destVolume.FreeBytes -lt [long][math]::Ceiling($sourceAllocatedBytes * 1.1)) {
            Write-AndThrowMigration $action 'insufficient-space' 'Destination free space is below source bytes x1.1.' $sourceBytes $sourceBytes
        }
        New-Item -ItemType Directory -Path $destPath -Force | Out-Null
        $copyCode = Invoke-CdsRobocopy -SourcePath $sourcePath -Destination $destPath
        if ($copyCode -lt 0 -or $copyCode -ge 8) {
            Write-AndThrowMigration $action 'copy-failed' "Robocopy failed with exit code $copyCode." $sourceBytes $sourceBytes
        }
        $destManifest = @(Get-CdsManifest -Root $destPath)
        if (-not (Test-CdsManifestEqual $sourceManifest $destManifest)) {
            $difference = Get-CdsManifestDifference $sourceManifest $destManifest
            Write-AndThrowMigration $action 'manifest-mismatch' "Staged destination manifest mismatch: $difference" $sourceBytes $sourceBytes
        }
        $staged = [pscustomobject][ordered]@{
            schema_version=2; session_id=$SessionId; item_id=$itemId
            source=$sourcePath; destination=$destPath; staged_at=(Get-Date).ToUniversalTime().ToString('o')
            robocopy_exit_code=[int]$copyCode; source_allocated_bytes=$sourceAllocatedBytes; source_manifest=$sourceManifest
        }
        Write-CdsJsonAtomic -Path $manifestPath -InputObject $staged
        $undo = [pscustomobject][ordered]@{
            kind='staged-copy'
            steps=@([pscustomobject][ordered]@{ action='remove-staged-copy'; source=$null; destination=$null; path=$destPath })
        }
        $action = Complete-MigrationAction $action 'completed' $sourceBytes $sourceBytes $null $null $undo
        Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
        return $action
    }

    $action = New-MigrationAction -ItemId $itemId -Operation 'finalize-move' -SourcePath $sourcePath -Destination $destPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Write-AndThrowMigration $action 'manifest-not-found' 'Staged migration manifest was not found.' $null $null
    }
    $staged = Read-CdsJson -Path $manifestPath
    if ($staged.session_id -ne $SessionId -or
        -not [string]::Equals([IO.Path]::GetFullPath($staged.source).TrimEnd('\'), $sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetFullPath($staged.destination).TrimEnd('\'), $destPath, [StringComparison]::OrdinalIgnoreCase)) {
        Write-AndThrowMigration $action 'manifest-path-mismatch' 'Staged manifest paths do not match this finalize request.' $null $null
    }
    $sourceManifest = @(Get-CdsManifest -Root $sourcePath)
    $destManifest = @(Get-CdsManifest -Root $destPath)
    [long]$sourceBytes = ($sourceManifest | Where-Object kind -eq 'file' | Measure-Object length -Sum).Sum
    if (-not (Test-CdsManifestEqual $staged.source_manifest $sourceManifest)) {
        $difference = Get-CdsManifestDifference $staged.source_manifest $sourceManifest
        Write-AndThrowMigration $action 'source-changed' "Source changed after staging: $difference" $sourceBytes $sourceBytes
    }
    if (-not (Test-CdsManifestEqual $staged.source_manifest $destManifest)) {
        $difference = Get-CdsManifestDifference $staged.source_manifest $destManifest
        Write-AndThrowMigration $action 'manifest-mismatch' "Destination manifest mismatch: $difference" $sourceBytes $sourceBytes
    }

    $undo = [pscustomobject][ordered]@{ kind='none'; steps=@() }
    if ($DeleteSource -or $Junction) {
        $sourceHashes = @(Get-CdsManifest -Root $sourcePath -IncludeHash)
        $destHashes = @(Get-CdsManifest -Root $destPath -IncludeHash)
        if (-not (Test-CdsManifestEqual $sourceHashes $destHashes)) {
            Write-AndThrowMigration $action 'hash-mismatch' 'Source and destination hash mismatch.' $sourceBytes $sourceBytes
        }
        $undo = if ($Junction) {
            [pscustomobject][ordered]@{
                kind='junction-migration'
                steps=@(
                    [pscustomobject][ordered]@{ action='remove-junction'; source=$null; destination=$null; path=$sourcePath },
                    [pscustomobject][ordered]@{ action='copy-back'; source=$destPath; destination=$sourcePath; path=$null }
                )
            }
        } else {
            [pscustomobject][ordered]@{
                kind='copy-back'
                steps=@([pscustomobject][ordered]@{ action='copy-back'; source=$destPath; destination=$sourcePath; path=$null })
            }
        }
        $action.undo = $undo
        try { Remove-Item -LiteralPath $sourcePath -Recurse -Force -ErrorAction Stop }
        catch {
            Write-AndThrowMigration $action 'source-delete-failed' ("Source deletion failed; destination copy remains: " + $_.Exception.Message) $sourceBytes $sourceBytes
        }
        if (Test-Path -LiteralPath $sourcePath) {
            Write-AndThrowMigration $action 'source-delete-failed' 'Source deletion did not complete.' $sourceBytes $sourceBytes
        }
        if ($Junction) {
            try {
                New-Item -ItemType Junction -Path $sourcePath -Target $destPath -ErrorAction Stop | Out-Null
                $link = Get-Item -LiteralPath $sourcePath -Force
                $target = @($link.Target)[0]
                $linkedManifest = @(Get-CdsManifest -Root $sourcePath -IncludeHash)
                if ($link.LinkType -ne 'Junction' -or
                    -not [string]::Equals([IO.Path]::GetFullPath($target).TrimEnd('\'), $destPath, [StringComparison]::OrdinalIgnoreCase) -or
                    -not (Test-CdsManifestEqual $destHashes $linkedManifest)) {
                    throw 'Junction validation failed.'
                }
            } catch {
                $action.undo = $undo
                Write-AndThrowMigration $action 'junction-failed' ("Junction creation failed; data remains at destination: " + $_.Exception.Message) $sourceBytes ([long]0)
            }
        }
    }
    $afterBytes = if ($DeleteSource -or $Junction) { [long]0 } else { $sourceBytes }
    $action = Complete-MigrationAction $action 'completed' $sourceBytes $afterBytes $null $null $undo
    Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
    return $action
} finally {
    if ($sessionWasExecuting) {
        $latest = Get-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
        if ($latest.state -eq 'executing') {
            $latest = Set-CdsSessionState -Session $latest -NextState 'approved'
            Write-CdsJsonAtomic -Path (Join-Path $latest.root 'session.json') -InputObject $latest
        }
    }
}
