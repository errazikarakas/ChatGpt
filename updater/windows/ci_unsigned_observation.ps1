# CI-only bounded observation. The parent enforces the outer 45-second deadline.
param([string]$File,[string]$ProofDirectory,[int]$ObserveSeconds=20,[string]$ReportName='unsigned-bootstrap-observation.json',[switch]$TemporaryReputationProfile,[int]$ExpectedDriverPid=0)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:BAKIM_NATIVE_TESTS -ne '1'){exit 12}
$reportPath=Join-Path $ProofDirectory $ReportName
$report=@{observationalOnly=(-not $TemporaryReputationProfile);coreTestResultUnaffected=(-not $TemporaryReputationProfile);exactUnsignedBootstrapAttempted=$true;normalShellReturned=$false;realUnicodeEngineGuiObserved=$false;outcome='pending';callerPid=$PID;productionSecuritySettingsChanged=$false;smartScreenDefenderPoliciesChanged=[bool]$TemporaryReputationProfile;ciTemporaryReputationProfile=[bool]$TemporaryReputationProfile;DefenderAVChanged=$false}
function Save-Observation {$report|ConvertTo-Json|Set-Content -LiteralPath $reportPath -Encoding UTF8}
try {$report.executionParentPid=[int](Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID)).ParentProcessId} catch {$report.executionParentPid=0}
$report.expectedDriverPid=$ExpectedDriverPid
$report.executionParentMatchesDriver=($report.executionParentPid -eq $ExpectedDriverPid)
Save-Observation
try {
 $File=[IO.Path]::GetFullPath($File)
 $report.sha256=(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
 @{path=$File;sha256=$report.sha256;callerPid=$PID;utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content $env:BAKIM_CI_PENDING -Encoding UTF8
 $started=Start-Process -FilePath $File -PassThru
 $report.normalShellReturned=$true;$report.launcherPid=$started.Id;Save-Observation
 for($i=0;$i -lt $ObserveSeconds;$i++){
  Start-Sleep -Seconds 1
  # Authorize only the exact canonical updater's own, hash-pinned recovery image.
  # This is CI-only pending-intent bookkeeping, never a product execution hook.
  $cacheEngine=Join-Path $env:LOCALAPPDATA 'BakimTRYardim/Launcher/versions/2026111001/engine.exe'
  $liveGo=Get-Process -Id $started.Id -ErrorAction SilentlyContinue
  if($liveGo -and $liveGo.Path -ieq $File -and (Test-Path -LiteralPath $cacheEngine -PathType Leaf)){
   $engineSha=(Get-FileHash -LiteralPath $cacheEngine -Algorithm SHA256).Hash.ToLowerInvariant()
   if($engineSha -eq 'd9ec96f4c8b6fa14e95e5aec4dc8998c84072ec470f088bd6b84f481092835a1'){
    @{path=$cacheEngine;sha256=$engineSha;callerPid=$started.Id;utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content $env:BAKIM_CI_PENDING -Encoding UTF8
    $report.exactOwnedRecoveryIntentRefreshed=$true
   }
  }
  $inner=Get-Process|Where-Object {$_.ProcessName -eq 'Bakım.TR Yardım' -and $_.MainWindowTitle -eq 'Bakım.TR Yardım'}
  if($inner){$report.realUnicodeEngineGuiObserved=$true;$report.outcome='gui_observed';break}
 }
 if(-not $report.realUnicodeEngineGuiObserved){$report.outcome='no_gui_within_bound'}
} catch {$report.outcome='launch_not_completed';$report.error=$_.Exception.Message} finally {Save-Observation}
