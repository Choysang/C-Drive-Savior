# clean.ps1 - session-gated GREEN cleanup for C Drive Savior.
[CmdletBinding(DefaultParameterSetName='DryRun')]
param(
    [Parameter(ParameterSetName='Execute', Mandatory=$true)][switch]$Execute,
    [Parameter(ParameterSetName='Execute', Mandatory=$true)][string]$SessionId,
    [string[]]$Include,
    [string[]]$Exclude,
    [switch]$SkipProcessCheck,
    [string]$SessionRoot = "$env:USERPROFILE\c-drive-savior\sessions",
    [string]$LogDir = "$env:USERPROFILE\c-drive-savior"
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $skillRoot 'modules\CDriveSavior.Core.psm1') -Force
$classification = Read-CdsJson -Path (Join-Path $skillRoot 'config\classification.json')

function Get-CatalogRoot([string]$Name) {
    switch ($Name) {
        'localappdata' { return [IO.Path]::GetFullPath($env:LOCALAPPDATA) }
        'profile'      { return [IO.Path]::GetFullPath($env:USERPROFILE) }
        'systemroot'   { return [IO.Path]::GetFullPath($env:SystemRoot) }
        'programdata'  { return [IO.Path]::GetFullPath($env:ProgramData) }
        default        { throw "Unknown catalog root: $Name" }
    }
}

function Resolve-CatalogSpec([string]$Resolver) {
    if ($Resolver -in @('delivery-optimization', 'recycle-bin')) {
        return [pscustomobject]@{ Pattern=$null; AllowedRoot=$null; Special=$Resolver }
    }
    $parts = $Resolver.Split(':', 2)
    if ($parts.Count -ne 2) { throw "Invalid catalog resolver: $Resolver" }
    if ($parts[0] -eq 'temp') {
        return [pscustomobject]@{
            Pattern=[IO.Path]::GetFullPath($env:TEMP)
            AllowedRoot=(Get-CatalogRoot 'localappdata')
            Special=$null
        }
    }
    $root = Get-CatalogRoot $parts[0]
    $pattern = if ($parts[1]) {
        Join-Path $root ($parts[1].Replace('/', [IO.Path]::DirectorySeparatorChar))
    } else { $root }
    return [pscustomobject]@{ Pattern=$pattern; AllowedRoot=$root; Special=$null }
}

function Expand-CatalogSpec($Spec) {
    if ($Spec.Special) { return @() }
    [void](Resolve-CdsSafePath -Path $Spec.Pattern -AllowedRoot $Spec.AllowedRoot)
    if ($Spec.Pattern -like '*[*]*') {
        return @(Resolve-Path -Path $Spec.Pattern -ErrorAction SilentlyContinue | ForEach-Object {
            Resolve-CdsSafePath -Path $_.Path -AllowedRoot $Spec.AllowedRoot
        })
    }
    return @([IO.Path]::GetFullPath($Spec.Pattern))
}

function Assert-NoReparseDescendant([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw [InvalidOperationException]::new("reparse point found: $Path")
    }
    if (-not $item.PSIsContainer) { return }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
            $attributes = [IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw [InvalidOperationException]::new("reparse point found: $entry")
            }
            if ($attributes -band [IO.FileAttributes]::Directory) { $stack.Push($entry) }
        }
    }
}

function Get-SafeTreeBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    Assert-NoReparseDescendant -Path $Path
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return [long]$item.Length }
    [long]$total = 0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
            $attributes = [IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::Directory) { $stack.Push($entry) }
            else { $total += (New-Object IO.FileInfo $entry).Length }
        }
    }
    return $total
}

function Clear-SafeTarget([string]$Path, [string]$AllowedRoot, [System.Collections.Generic.List[string]]$Errors) {
    [void](Resolve-CdsSafePath -Path $Path -AllowedRoot $AllowedRoot)
    Assert-NoReparseDescendant -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch { $Errors.Add($_.Exception.Message) }
        return
    }

    $directories = New-Object System.Collections.Generic.List[string]
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
            $attributes = [IO.File]::GetAttributes($entry)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw [InvalidOperationException]::new("reparse point found: $entry")
            }
            if ($attributes -band [IO.FileAttributes]::Directory) {
                $directories.Add($entry)
                $stack.Push($entry)
            } else {
                try { Remove-Item -LiteralPath $entry -Force -ErrorAction Stop }
                catch { $Errors.Add($_.Exception.Message) }
            }
        }
    }
    foreach ($directory in @($directories | Sort-Object { $_.Length } -Descending)) {
        try { Remove-Item -LiteralPath $directory -Force -ErrorAction Stop }
        catch { $Errors.Add($_.Exception.Message) }
    }
}

function New-ActionRecord($Item, [string]$CurrentSessionId) {
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [pscustomobject][ordered]@{
        schema_version=2; session_id=$CurrentSessionId; tool='clean.ps1'; item_id=$Item.id
        action='clean'; status='planned'; started_at=$now; finished_at=$null
        before_bytes=$null; after_bytes=$null; freed_bytes=$null
        source=$null; destination=$null; error_code=$null; error_message=$null
        undo=[pscustomobject][ordered]@{ kind='none'; steps=@() }
    }
}

function Complete-Action($Action, [string]$Status, $Before, $After, [string[]]$Errors) {
    $Action.status = $Status
    $Action.before_bytes = $Before
    $Action.after_bytes = $After
    if ($null -ne $Before -and $null -ne $After) {
        $freed = [long]$Before - [long]$After
        $Action.freed_bytes = if ($freed -gt 0) { [long]$freed } else { [long]0 }
    } else { $Action.freed_bytes = $null }
    $Action.finished_at = (Get-Date).ToUniversalTime().ToString('o')
    if ($Errors.Count -gt 0) {
        $Action.error_code = 'cleanup-error'
        $Action.error_message = ($Errors -join ' | ')
    }
    return $Action
}

function Get-ItemTargets($Item) {
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($resolver in @($Item.resolvers)) {
        $spec = Resolve-CatalogSpec $resolver
        if ($spec.Special) {
            if ($spec.Special -eq 'recycle-bin') {
                $driveRoot = [IO.Path]::GetPathRoot("$env:SystemDrive\")
                $targets.Add([pscustomobject]@{
                    Path=(Join-Path $driveRoot '$Recycle.Bin')
                    AllowedRoot=$driveRoot
                    Special=$spec.Special
                })
            } else {
                $targets.Add([pscustomobject]@{ Path=$null; AllowedRoot=$null; Special=$spec.Special })
            }
            continue
        }
        if ($Item.id -eq 'thumbcache') {
            [void](Resolve-CdsSafePath -Path $spec.Pattern -AllowedRoot $spec.AllowedRoot)
            foreach ($filter in @('thumbcache_*', 'iconcache_*')) {
                Get-ChildItem -LiteralPath $spec.Pattern -Filter $filter -File -Force -ErrorAction SilentlyContinue |
                    ForEach-Object { $targets.Add([pscustomobject]@{ Path=$_.FullName; AllowedRoot=$spec.AllowedRoot; Special=$null }) }
            }
            continue
        }
        foreach ($path in @(Expand-CatalogSpec $spec)) {
            $targets.Add([pscustomobject]@{ Path=$path; AllowedRoot=$spec.AllowedRoot; Special=$null })
        }
    }
    return @($targets | ForEach-Object { $_ })
}

function Invoke-WindowsUpdateCleanup($Targets, [System.Collections.Generic.List[string]]$Errors, [ref]$RestorationFailed) {
    $RestorationFailed.Value = $false
    $states = @{}
    foreach ($name in @('wuauserv','bits')) {
        try {
            $service = Get-Service -Name $name -ErrorAction Stop
            $serviceConfig = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name) -ErrorAction Stop
            $states[$name] = [pscustomobject]@{
                WasRunning=($service.Status -eq 'Running')
                Status=[string]$service.Status
                StartType=[string]$serviceConfig.StartMode
            }
            if ($states[$name].WasRunning) { Stop-Service -Name $name -Force -ErrorAction Stop }
        } catch { $Errors.Add("$name stop/state: $($_.Exception.Message)") }
    }
    try {
        if ($Errors.Count -eq 0) {
            foreach ($target in $Targets) { Clear-SafeTarget -Path $target.Path -AllowedRoot $target.AllowedRoot -Errors $Errors }
        }
    } finally {
        foreach ($name in @('wuauserv','bits')) {
            if ($states.ContainsKey($name) -and $states[$name].WasRunning) {
                try { Start-Service -Name $name -ErrorAction Stop }
                catch {
                    $RestorationFailed.Value = $true
                    $Errors.Add("$name restore: $($_.Exception.Message)")
                }
            }
            if ($states.ContainsKey($name)) {
                try {
                    $currentConfig = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name) -ErrorAction Stop
                    if ([string]$currentConfig.StartMode -ne $states[$name].StartType) {
                        $RestorationFailed.Value = $true
                        $Errors.Add("$name start type changed from $($states[$name].StartType) to $($currentConfig.StartMode)")
                    }
                } catch {
                    $RestorationFailed.Value = $true
                    $Errors.Add("$name start type verification: $($_.Exception.Message)")
                }
            }
        }
    }
}

$selected = @($classification.cleanup_items | Where-Object {
    (-not $Include -or $Include -contains $_.id) -and (-not $Exclude -or $Exclude -notcontains $_.id)
})
$results = New-Object System.Collections.Generic.List[object]
$session = $null
$sessionWasExecuting = $false

if ($Execute) {
    $session = Get-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
    if ($session.state -eq 'approved') {
        $session = Set-CdsSessionState -Session $session -NextState 'executing'
        Write-CdsJsonAtomic -Path (Join-Path $session.root 'session.json') -InputObject $session
        $sessionWasExecuting = $true
    } elseif ($session.state -eq 'executing') { $sessionWasExecuting = $true }
}

try {
    foreach ($item in $selected) {
        if (-not $Execute) {
            $targets = @(Get-ItemTargets $item)
            [long]$planned = 0
            foreach ($target in @($targets | Where-Object Path)) {
                $safe = Resolve-CdsSafePath -Path $target.Path -AllowedRoot $target.AllowedRoot
                $planned += Get-SafeTreeBytes $safe
            }
            $results.Add([pscustomobject]@{ item_id=$item.id; status='planned'; before_bytes=$planned })
            continue
        }

        $action = New-ActionRecord -Item $item -CurrentSessionId $SessionId
        $errors = New-Object System.Collections.Generic.List[string]
        try {
            Assert-CdsApprovedItem -SessionId $SessionId -ItemId $item.id -Action clean -SessionRoot $SessionRoot | Out-Null
        } catch {
            $errors.Add($_.Exception.Message)
            $action = Complete-Action $action 'skipped' $null $null $errors
            Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
            $results.Add($action)
            throw
        }

        if ($item.admin -and -not (Test-CdsElevated)) {
            $errors.Add('Administrator privileges are required.')
            $action = Complete-Action $action 'skipped' $null $null $errors
            Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
            $results.Add($action); continue
        }
        $running = @($item.owner_processes | Where-Object { Get-Process -Name $_ -ErrorAction SilentlyContinue })
        if ($running.Count -gt 0 -and -not $SkipProcessCheck) {
            $errors.Add('Owning process is running: ' + ($running -join ','))
            $action = Complete-Action $action 'skipped' $null $null $errors
            Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
            $results.Add($action); continue
        }

        try {
            $targets = @(Get-ItemTargets $item)
            $normalTargets = @($targets | Where-Object Path)
            foreach ($target in $normalTargets) {
                $target.Path = Resolve-CdsSafePath -Path $target.Path -AllowedRoot $target.AllowedRoot
                Assert-CdsApprovedItem -SessionId $SessionId -ItemId $item.id -Action clean `
                    -SessionRoot $SessionRoot -TargetPath $target.Path | Out-Null
            }
        } catch {
            $errors.Add($_.Exception.Message)
            $action = Complete-Action $action 'skipped' $null $null $errors
            Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
            $results.Add($action)
            throw
        }
        $action.source = if ($normalTargets.Count -gt 0) { $normalTargets[0].Path } else { [string]$targets[0].Special }

        $existing = @($normalTargets | Where-Object { Test-Path -LiteralPath $_.Path })
        if ($normalTargets.Count -gt 0 -and $existing.Count -eq 0) {
            $action = Complete-Action $action 'not-found' ([long]0) ([long]0) $errors
            Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
            $results.Add($action); continue
        }

        try {
            foreach ($target in $existing) { Assert-NoReparseDescendant -Path $target.Path }
        } catch {
            if ($_.Exception.Message -like 'reparse point found:*') {
                $errors.Add($_.Exception.Message)
                $action = Complete-Action $action 'skipped' $null $null $errors
                Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
                $results.Add($action); continue
            }
            throw
        }

        $unmeasuredSpecial = $item.id -eq 'delivery-opt'
        $before = if ($unmeasuredSpecial) { $null } else { [long]0 }
        if (-not $unmeasuredSpecial) {
            foreach ($target in $existing) { $before = [long]$before + (Get-SafeTreeBytes $target.Path) }
        }
        try {
            $serviceRestorationFailed = $false
            switch ($item.id) {
                'wu-cache' { Invoke-WindowsUpdateCleanup -Targets $existing -Errors $errors -RestorationFailed ([ref]$serviceRestorationFailed) }
                'delivery-opt' {
                    $command = Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue
                    if ($command) { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop }
                    else { $errors.Add('Delivery Optimization cleanup command is unavailable.') }
                }
                'recyclebin' { Clear-RecycleBin -Force -ErrorAction Stop }
                default {
                    foreach ($target in $existing) {
                        $target.Path = Resolve-CdsSafePath -Path $target.Path -AllowedRoot $target.AllowedRoot
                        Assert-NoReparseDescendant -Path $target.Path
                        Clear-SafeTarget -Path $target.Path -AllowedRoot $target.AllowedRoot -Errors $errors
                    }
                }
            }
        } catch { $errors.Add($_.Exception.Message) }

        $after = if ($unmeasuredSpecial) { $null } else { [long]0 }
        if (-not $unmeasuredSpecial) {
            foreach ($target in $existing) {
                try { $after = [long]$after + (Get-SafeTreeBytes $target.Path) }
                catch { $errors.Add($_.Exception.Message) }
            }
        }
        $freed = if ($null -ne $before -and $null -ne $after) { [long]($before - $after) } else { $null }
        $status = if ($serviceRestorationFailed) { 'failed' }
            elseif ($errors.Count -eq 0 -and ($null -eq $after -or $after -eq 0)) { 'completed' }
            elseif ($null -ne $freed -and $freed -gt 0) { 'partial' }
            else { 'failed' }
        $action = Complete-Action $action $status $before $after $errors
        Write-CdsAction -SessionId $SessionId -SessionRoot $SessionRoot -ActionRecord $action
        $results.Add($action)
        if ($serviceRestorationFailed) {
            throw "Service restoration failed: $($action.error_message)"
        }
    }
} finally {
    if ($Execute -and $sessionWasExecuting) {
        $latest = Get-CdsSession -SessionId $SessionId -SessionRoot $SessionRoot
        if ($latest.state -eq 'executing') {
            $latest = Set-CdsSessionState -Session $latest -NextState 'approved'
            Write-CdsJsonAtomic -Path (Join-Path $latest.root 'session.json') -InputObject $latest
        }
    }
}

Write-Host ("C Drive Savior clean: {0} item(s), execute={1}" -f $results.Count, [bool]$Execute)
return @($results | ForEach-Object { $_ })
