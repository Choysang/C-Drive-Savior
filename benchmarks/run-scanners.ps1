[CmdletBinding()]
param(
    [string]$ScanRoot = "$env:SystemDrive\",
    [int]$Runs = 3,
    [string]$Output = '.\benchmark-results',
    [string]$BaselineCommit = 'c2607dbeadf21df43a8eecc73bb59c45befa6918'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (& git rev-parse --show-toplevel).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Run the benchmark from a Git worktree.' }
$scanPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $ScanRoot))
if (-not (Test-Path -LiteralPath $scanPath -PathType Container)) { throw "Scan root not found: $scanPath" }
if ($Runs -lt 1) { throw 'Runs must be at least 1.' }
$isDriveRoot = [string]::Equals($scanPath.TrimEnd('\'),[IO.Path]::GetPathRoot($scanPath).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)
if ($isDriveRoot -and -not $PSBoundParameters.ContainsKey('Runs')) { $Runs = 1 }
$outputRoot = [IO.Path]::GetFullPath((Join-Path (Get-Location) $Output))
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

function Get-DatasetStats([string]$Root) {
    [long]$files=0; [int]$denied=0
    $pending=New-Object 'System.Collections.Generic.Stack[string]'; $pending.Push($Root)
    while($pending.Count){
        $path=$pending.Pop()
        try { foreach($file in [IO.Directory]::EnumerateFiles($path)){ $files++ } } catch { $denied++ }
        try {
            foreach($directory in [IO.Directory]::EnumerateDirectories($path)){
                try { if(-not ([IO.File]::GetAttributes($directory) -band [IO.FileAttributes]::ReparsePoint)){ $pending.Push($directory) } } catch { $denied++ }
            }
        } catch { $denied++ }
    }
    [pscustomobject]@{total_files=$files;denied_paths=$denied}
}

function Invoke-MeasuredProcess([string]$FilePath,[string[]]$Arguments,[hashtable]$Environment=@{}) {
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$FilePath; $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach($argument in $Arguments){[void]$start.ArgumentList.Add($argument)}
    foreach($key in $Environment.Keys){$start.EnvironmentVariables[$key]=[string]$Environment[$key]}
    $process=New-Object Diagnostics.Process; $process.StartInfo=$start
    $timer=[Diagnostics.Stopwatch]::StartNew(); [void]$process.Start()
    $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync(); [long]$peak=0
    while(-not $process.WaitForExit(20)){try{$process.Refresh();$peak=[math]::Max($peak,$process.WorkingSet64)}catch{}}
    $process.WaitForExit(); $timer.Stop()
    [pscustomobject]@{exit_code=$process.ExitCode;elapsed_ms=[long]$timer.ElapsedMilliseconds;peak_working_set_bytes=$peak;stdout=$stdout.GetAwaiter().GetResult();stderr=$stderr.GetAwaiter().GetResult()}
}

function Get-ScanMetadata([string]$Artifact,[string]$Snapshot) {
    if(-not $Artifact -or -not (Test-Path -LiteralPath $Artifact -PathType Leaf)){
        return [pscustomobject]@{scan_complete=$false;denied_paths=$null;contract_status='missing-artifact'}
    }
    $scan=Get-Content -Raw -Encoding UTF8 -LiteralPath $Artifact | ConvertFrom-Json
    $v2=($scan.schema_version -eq 2 -and $scan.PSObject.Properties['denied_paths'] -and $scan.PSObject.Properties['accounting'])
    $denied=if($v2){@($scan.denied_paths).Count}elseif($scan.PSObject.Properties['walk_errors']){[int]$scan.walk_errors}else{@($scan.rows | Where-Object {$_.errors -gt 0}).Count}
    $complete=if($scan.PSObject.Properties['scan_complete']){[bool]$scan.scan_complete}else{$denied -eq 0}
    [pscustomobject]@{scan_complete=$complete;denied_paths=$denied;contract_status=if($v2){'v2'}else{"legacy-$Snapshot"}}
}

function Get-Median([long[]]$Values) {
    if(-not $Values.Count){return $null}; $sorted=@($Values | Sort-Object); $middle=[int][math]::Floor($sorted.Count/2)
    if($sorted.Count % 2){return $sorted[$middle]}; return [long](($sorted[$middle-1]+$sorted[$middle])/2)
}

$baselineWorktree=Join-Path ([IO.Path]::GetTempPath()) ("c-drive-savior-benchmark-{0}" -f [guid]::NewGuid().ToString('N'))
$results=New-Object System.Collections.Generic.List[object]
try {
    & git -C $repoRoot worktree add --detach $baselineWorktree $BaselineCommit | Out-Host
    if($LASTEXITCODE -ne 0){throw 'Unable to create the baseline worktree.'}
    $baselineCommit=(& git -C $baselineWorktree rev-parse HEAD).Trim(); $currentCommit=(& git -C $repoRoot rev-parse HEAD).Trim()
    $dataset=Get-DatasetStats $scanPath
    $driveLetter=[IO.Path]::GetPathRoot($scanPath).Substring(0,1)
    $volume=Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}:'" -f $driveLetter) -ErrorAction SilentlyContinue
    $filesystem=if($volume){$volume.FileSystem}else{'unknown'}
    $windowsBuild=(Get-CimInstance Win32_OperatingSystem).Version
    $pwshVersion=(& pwsh --version).Trim(); $pythonVersion=(& python --version 2>&1).Trim()

    for($run=1;$run -le $Runs;$run++){
        foreach($snapshot in @('baseline','current')){
            $root=if($snapshot -eq 'baseline'){$baselineWorktree}else{$repoRoot}
            $commit=if($snapshot -eq 'baseline'){$baselineCommit}else{$currentCommit}
            foreach($engine in @('powershell','python')){
                $runRoot=Join-Path $outputRoot ("runs\{0}-{1}-{2}" -f $snapshot,$engine,$run)
                New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
                $environment=@{}; $artifact=$null
                if($engine -eq 'powershell'){
                    if($snapshot -eq 'baseline' -and -not $isDriveRoot){
                        $arguments=@('-NoProfile','-File',(Join-Path $repoRoot 'benchmarks\invoke-legacy-powershell.ps1'),'-Scanner',(Join-Path $root 'scripts\scan.ps1'),'-ScanRoot',$scanPath,'-Output',$runRoot)
                    } elseif($snapshot -eq 'baseline') {
                        $arguments=@('-NoProfile','-File',(Join-Path $root 'scripts\scan.ps1'),'-ThresholdGB','0','-MaxDepth','8','-OutDir',$runRoot,'-NoHtml')
                    } else {
                        $arguments=@('-NoProfile','-File',(Join-Path $root 'scripts\scan.ps1'),'-ScanRoot',$scanPath,'-ThresholdGB','0','-MaxReportDepth','8','-SessionRoot',$runRoot,'-NoHtml')
                    }
                    $measured=Invoke-MeasuredProcess 'pwsh' $arguments $environment
                    $artifact=(Get-ChildItem -LiteralPath $runRoot -Filter 'scan*.json' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
                    $runtime=$pwshVersion
                } else {
                    $artifact=Join-Path $runRoot 'scan.json'
                    $arguments=@((Join-Path $repoRoot 'benchmarks\invoke-python-core.py'),'--scanner',(Join-Path $root 'scripts\c_drive_panel.py'),'--mode',$(if($snapshot -eq 'baseline'){'legacy'}else{'current'}),'--scan-root',$scanPath,'--output',$artifact)
                    $measured=Invoke-MeasuredProcess 'python' $arguments
                    $runtime=$pythonVersion
                }
                $metadata=Get-ScanMetadata $artifact $snapshot
                $results.Add([pscustomobject][ordered]@{
                    snapshot=$snapshot;engine=$engine;commit=$commit;run=$run;runtime_version=$runtime;windows_build=$windowsBuild;filesystem=$filesystem
                    total_files=[long]$dataset.total_files;inventory_denied_paths=[int]$dataset.denied_paths;scanner_denied_paths=$metadata.denied_paths
                    scan_complete=($measured.exit_code -eq 0 -and $metadata.scan_complete);elapsed_ms=$measured.elapsed_ms;peak_working_set_bytes=$measured.peak_working_set_bytes
                    exit_code=$measured.exit_code;contract_status=$metadata.contract_status;artifact=$artifact;error=if($measured.exit_code){$measured.stderr.Trim()}else{$null}
                })
                Write-Host ("{0,-8} {1,-10} run {2}: {3} ms, peak {4:N1} MB" -f $snapshot,$engine,$run,$measured.elapsed_ms,($measured.peak_working_set_bytes/1MB))
            }
        }
    }
} finally {
    if(Test-Path -LiteralPath $baselineWorktree){
        & git -C $repoRoot worktree remove --force $baselineWorktree | Out-Host
        if($LASTEXITCODE -ne 0){Write-Warning "Temporary baseline worktree remains at $baselineWorktree"}
    }
}

$rawPath=Join-Path $outputRoot 'results.json'
[IO.File]::WriteAllText($rawPath,($results | ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding $false))
$lines=New-Object System.Collections.Generic.List[string]
$lines.Add('# Scanner benchmark'); $lines.Add(''); $lines.Add("Scan root: ``$scanPath``  "); $lines.Add("Runs: $Runs  "); $lines.Add('Results are machine-specific; compare saved artifacts before making speed claims.'); $lines.Add('')
$lines.Add($(if($isDriveRoot){'Full-drive mode runs each scanner unchanged.'}else{'Fixture mode disables only the legacy PowerShell hidden-system probe because it cannot be redirected to the fixture.'})); $lines.Add('')
$lines.Add('| Snapshot | Engine | Median ms | Peak MB (max) | Files | Denied | Complete | Contract |')
$lines.Add('|---|---:|---:|---:|---:|---:|---|---|')
foreach($group in $results | Group-Object snapshot,engine){
    $items=@($group.Group); $median=Get-Median @($items.elapsed_ms); $peak=($items.peak_working_set_bytes | Measure-Object -Maximum).Maximum/1MB
    $lines.Add(("| {0} | {1} | {2} | {3:N1} | {4} | {5} | {6} | {7} |" -f $items[0].snapshot,$items[0].engine,$median,$peak,$items[0].total_files,(($items.scanner_denied_paths|Measure-Object -Maximum).Maximum),(-not ($items.scan_complete -contains $false)),$items[0].contract_status))
}
$summaryPath=Join-Path $outputRoot 'summary.md'; [IO.File]::WriteAllLines($summaryPath,$lines,(New-Object Text.UTF8Encoding $false))
Write-Host "Raw results: $rawPath"; Write-Host "Summary: $summaryPath"
if(@($results | Where-Object {$_.exit_code -ne 0}).Count){throw 'One or more benchmark runs failed; inspect results.json.'}
