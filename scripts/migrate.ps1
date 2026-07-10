# migrate.ps1 - C Drive Savior: move a folder from C: to D: safely. PowerShell 5.1 / 7.
# Pattern: preflight -> robocopy -> verify (files+bytes) -> optional junction -> optional source delete -> undo log.
# Default is DRY-RUN preview. Add -Execute to act. Source is kept unless -DeleteSource or -Junction verifies.
# For user known folders (Desktop/Documents/...) prefer registry redirection: references/relocation-guide.md #1.
# ASCII-only source on purpose.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Dest,                     # default: D:\MovedFromC\<same relative path>
    [switch]$Junction,                 # after verified copy: remove source, create junction Source -> Dest
    [switch]$DeleteSource,             # after verified copy: remove source (no junction)
    [switch]$Execute,
    [string]$LogDir = "$env:USERPROFILE\c-drive-savior"
)

$ErrorActionPreference = 'SilentlyContinue'
function Format-GB([long]$b) { [math]::Round($b / 1GB, 2) }
function Get-TreeStat([string]$Path) {
    [long]$bytes = 0; [long]$files = 0
    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if (-not $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $bytes += $_.Length; $files++ }
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files }
}
function Fail([string]$msg) { Write-Host ("BLOCKED: " + $msg); exit 2 }

# --- preflight ---------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Source)) { Fail "source not found: $Source" }
$srcItem = Get-Item -LiteralPath $Source -Force
if ($srcItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail "source is already a junction/symlink" }
$lower = $Source.ToLowerInvariant()
foreach ($bad in @('c:\windows', 'c:\program files', 'c:\program files (x86)', 'c:\programdata\package cache')) {
    if ($lower.StartsWith($bad)) { Fail "refusing to migrate system/install area: $Source (decision-model.md RED tier)" }
}
if ($lower -like '*\onedrive*') { Fail "OneDrive-managed path: use OneDrive settings, never junction (pitfalls.md #12)" }

if (-not $Dest) {
    $rel = $Source -replace '^[A-Za-z]:', ''
    $Dest = Join-Path 'D:\MovedFromC' $rel.TrimStart('\')
}
$destDrive = [IO.Path]::GetPathRoot($Dest).TrimEnd('\')
$dinfo = Get-PSDrive $destDrive.TrimEnd(':') -ErrorAction SilentlyContinue
if (-not $dinfo) { Fail "destination drive $destDrive not found" }
$dtype = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$destDrive'").DriveType
if ($Junction -and $dtype -ne 3) { Fail "junction target must be a fixed internal disk (DriveType=3), got $dtype" }

Write-Host ("measuring {0} ..." -f $Source)
$src = Get-TreeStat $Source
if ($dinfo.Free -lt ($src.Bytes * 1.1)) {
    Fail ("not enough free space on {0}: need {1} GB x1.1, have {2} GB" -f $destDrive, (Format-GB $src.Bytes), (Format-GB $dinfo.Free))
}

Write-Host ''
Write-Host '=== C Drive Savior migrate plan ==='
Write-Host ("  source : {0}  ({1} GB, {2} files)" -f $Source, (Format-GB $src.Bytes), $src.Files)
Write-Host ("  dest   : {0}" -f $Dest)
$after = 'copy only (source kept)'
if ($Junction) { $after = 'junction: source replaced by link to dest' }
elseif ($DeleteSource) { $after = 'source deleted after verify' }
Write-Host ("  after  : {0}" -f $after)
if (-not $Execute) { Write-Host '[i] DRY-RUN. Re-run with -Execute to migrate.'; exit 0 }

# --- copy ---------------------------------------------------------------------
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Write-Host 'robocopy running ...'
& robocopy $Source $Dest /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /MT:8 /NFL /NDL /NP | Out-Null
$rc = $LASTEXITCODE
if ($rc -ge 8) { Fail ("robocopy failed with exit code {0} (>=8 = real failure); source untouched" -f $rc) }

# --- verify --------------------------------------------------------------------
$dst = Get-TreeStat $Dest
$verified = ($dst.Files -ge $src.Files) -and ($dst.Bytes -ge $src.Bytes)
Write-Host ("verify: source {0} files / {1} GB ; dest {2} files / {3} GB ; robocopy rc={4}" -f `
    $src.Files, (Format-GB $src.Bytes), $dst.Files, (Format-GB $dst.Bytes), $rc)

$status = 'copied'
$undo = "robocopy `"$Dest`" `"$Source`" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1"
if (-not $verified) {
    $status = 'copied-verify-mismatch'
    Write-Host 'WARN: dest smaller than source (locked/in-use files?). Source KEPT. Close owning apps and re-run.'
} elseif ($Junction) {
    Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Source) {
        $status = 'copied-source-locked'
        Write-Host 'WARN: source delete failed (locked files). Junction NOT created; source kept; dest copy exists.'
    } else {
        New-Item -ItemType Junction -Path $Source -Value $Dest | Out-Null
        if (Test-Path -LiteralPath $Source) {
            $status = 'moved+junction'
            $undo = "Remove junction: rmdir `"$Source`" ; then robocopy back if needed: $undo"
            Write-Host ("junction created: {0} -> {1}" -f $Source, $Dest)
        } else {
            $status = 'moved-junction-failed'
            Write-Host ("ERROR: junction creation failed; data lives at {0}; recreate link manually: cmd /c mklink /J `"{1}`" `"{0}`"" -f $Dest, $Source)
        }
    }
} elseif ($DeleteSource) {
    Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Source) {
        $status = 'copied-source-locked'
        Write-Host 'WARN: source delete incomplete (locked files remain).'
    } else {
        $status = 'moved'
        Write-Host ("moved. freed ~{0} GB on C:" -f (Format-GB $src.Bytes))
    }
} else {
    Write-Host 'copy done; source kept (rollback window). Delete it after you confirm apps still work.'
}

# --- log ------------------------------------------------------------------------
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$freed = [long]0
if ($status -eq 'moved' -or $status -eq 'moved+junction') { $freed = $src.Bytes }
$log = [pscustomobject]@{
    schema = 1; tool = 'migrate.ps1'; mode = 'execute'
    started = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    items = @([pscustomobject]@{
        id = 'migrate'; label = ("move to " + $destDrive); action = 'move'
        source = $Source; dest = $Dest
        bytes = $src.Bytes; files = $src.Files
        freed_bytes = $freed
        status = $status; robocopy_rc = $rc; undo = $undo
        timestamp = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    })
}
$logPath = Join-Path $LogDir ("actions-migrate-{0}.json" -f $stamp)
[IO.File]::WriteAllText($logPath, ($log | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $true))
Write-Host ("log: {0}" -f $logPath)
