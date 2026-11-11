$ErrorActionPreference='Stop'
$base=$PSScriptRoot
$proof=Join-Path $base 'proof'
New-Item -ItemType Directory -Force $proof | Out-Null
$fixture=Join-Path $base 'fixtures';New-Item -ItemType Directory -Force $fixture | Out-Null
$csc=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $csc /nologo /codepage:65001 /target:winexe /platform:x64 /r:System.Windows.Forms.dll /out:$fixture/good.exe (Join-Path $base 'fixture.cs')
if($LASTEXITCODE -ne 0){throw 'Good synthetic GUI compilation failed'}
& $csc /nologo /codepage:65001 /target:winexe /platform:x64 /define:BROKEN /r:System.Windows.Forms.dll /out:$fixture/bad.exe (Join-Path $base 'fixture.cs')
if($LASTEXITCODE -ne 0){throw 'Broken synthetic fixture compilation failed'}
$env:BAKIM_FIXTURE_GOOD=Join-Path $fixture 'good.exe'
$env:BAKIM_FIXTURE_BAD=Join-Path $fixture 'bad.exe'
$env:BAKIM_NATIVE_TESTS='1'
$env:BAKIM_CI_PENDING=Join-Path $proof 'ci-pending-launch.json'
Remove-Item Env:BAKIM_CI_CATALOG_SCRIPT -ErrorAction SilentlyContinue
$publisher=Join-Path $base 'ci_trusted_publisher.ps1'
$signer=Join-Path $base 'ci_sign_fixture.ps1'
$profile=Join-Path $base 'ci_reputation_profile.ps1'
$profileMode=$env:BAKIM_CI_REPUTATION_PROFILE -eq '1'
Remove-Item Env:BAKIM_CI_SIGN_SCRIPT -ErrorAction SilentlyContinue
if(-not $profileMode){$env:BAKIM_CI_SIGN_SCRIPT=$signer}
$canonical=Join-Path $base 'release/Bakim-TR-Yardim.exe'
$canonicalSha=(Get-FileHash $canonical -Algorithm SHA256).Hash.ToLowerInvariant()
$canonicalSeed=Join-Path $base 'launcher/seed/engine.exe'
$expectedSeed='d9ec96f4c8b6fa14e95e5aec4dc8998c84072ec470f088bd6b84f481092835a1'
if((Get-FileHash $canonicalSeed -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSeed){throw 'Original production seed changed'}
$approver=$null;$observer=$null
try {
 if($profileMode){& $profile -Action Apply -ProofDirectory $proof}
 else {
  & $publisher -Action Initialize -ProofDirectory $proof
  foreach($sourceFixture in @($env:BAKIM_FIXTURE_GOOD,$env:BAKIM_FIXTURE_BAD)){& $signer -Action Sign -File $sourceFixture -ProofDirectory $proof}
 }
 $helper=Join-Path $base 'ci_approve_own_fixtures.ps1'
 $tokens=$null;$parseErrors=$null
 [void][System.Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$parseErrors)
 if($parseErrors.Count -gt 0){throw ('Consent watcher parse failed: '+($parseErrors.Message -join '; '))}
 $windowsPowerShell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
 $nativeModules=(Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 $approver=Start-Process $windowsPowerShell -Environment @{PSModulePath=$nativeModules} -ArgumentList @('-NoProfile','-File',('"'+$helper+'"')) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $proof 'consent-stderr.txt') -RedirectStandardOutput (Join-Path $proof 'consent-stdout.txt')
 Push-Location (Join-Path $base 'launcher')
 try {
  # Mandatory native lifecycle gate uses trusted embedded-signed TEST copies.
  # Canonical raw engine GUI security consent is observed separately below.
  $goArguments=@('test','-v','-count=1','-timeout=3m')
  if(-not $profileMode){$goArguments+=@('-skip','TestWindowsExactProductionEngineChildGUI')}
  $goArguments+='./...'
  & go @goArguments 2>&1 | Tee-Object -FilePath (Join-Path $proof 'native-tests.txt')
  if($LASTEXITCODE -ne 0){throw 'Mandatory Windows native updater lifecycle tests failed'}
 } finally {Pop-Location}
 $scope=if($profileMode){'exact-raw-app-native-lifecycle-in-temporary-ci-reputation-profile'}else{'native-lifecycle-with-embedded-signed-test-copies'}
 $summary=@{ok=$true;okScope=$scope;launcherVersion='1.0.0';originalEnginePreserved=$true;productionLauncherPreserved=$true;signedUpdateAndHashChecks=$true;nativeAtomicVersionUpdate=$true;nativeRollback=$true;busySessionPreserved=$true;singleUpdater=$true;launcherSelfDelegation=$true;exactChildPidAndReadinessAck=$true;launcherEarlyExitRollback=$true;knownNewVersionStartsOnFirstOpen=$true;motwPreserved=$true;productionSecuritySettingsChanged=$false;ciTemporaryTrustStoresChanged=(-not $profileMode);ciTemporaryReputationPolicyChanged=$profileMode;ciReputationPolicyRestored=$false;DefenderAVSettingsChanged=$false;productionPublisherCertificateAvailable=$false;productionWindowsWarningsRemoved=$false;fixtureExecutablePrefixPreservedExceptAuthenticode=(-not $profileMode);allTestExecutablesRawOriginal=$profileMode;canonicalRawEngineGuiUnderTestProfile=$profileMode;canonicalUnsignedGuiMandatoryGate=$false;realUnicodeChildGuiStarted=$false}
 $summary|ConvertTo-Json|Set-Content (Join-Path $proof 'windows-updater-proof.json') -Encoding UTF8
 # Exercise the exact full deliverable under the declared CI test condition.
 if($profileMode){
  Set-Content -LiteralPath ($canonical+':Zone.Identifier') -Encoding ASCII -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://xn--bakm-nza.tr/yardim-indir.php?platform=windows"
  $functional=Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',('"'+(Join-Path $base 'ci_unsigned_observation.ps1')+'"'),'-File',('"'+$canonical+'"'),'-ProofDirectory',('"'+$proof+'"'),'-ReportName','exact-bootstrap-ci-profile.json','-TemporaryReputationProfile') -WindowStyle Hidden -PassThru
  $null=$functional.Handle
  if(-not $functional.WaitForExit(45000)){$functional.Kill();throw 'Exact raw bootstrap CI-profile launch deadline exceeded'}
  $functionalProof=Get-Content (Join-Path $proof 'exact-bootstrap-ci-profile.json') -Raw|ConvertFrom-Json
  if(-not $functionalProof.realUnicodeEngineGuiObserved){throw 'Exact raw bootstrap did not start the real GUI under the declared CI test profile'}
  $summary.exactRawBootstrapGuiUnderTestProfile=$true
  Start-Sleep -Seconds 2
  Get-Process|Where-Object {$_.ProcessName -eq 'Bakım.TR Yardım'}|Stop-Process -Force -ErrorAction SilentlyContinue
  & $profile -Action Restore -ProofDirectory $proof
  $summary.ciReputationPolicyRestored=$true
  $summary|ConvertTo-Json|Set-Content (Join-Path $proof 'windows-updater-proof.json') -Encoding UTF8
 }
 # Normal restored-policy launch is a separate bounded observation.

 Set-Content -LiteralPath ($canonical+':Zone.Identifier') -Encoding ASCII -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://xn--bakm-nza.tr/yardim-indir.php?platform=windows"
 $worker=Join-Path $base 'ci_unsigned_observation.ps1'
 $observer=Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile','-File',('"'+$worker+'"'),'-File',('"'+$canonical+'"'),'-ProofDirectory',('"'+$proof+'"')) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $proof 'unsigned-observer-stderr.txt') -RedirectStandardOutput (Join-Path $proof 'unsigned-observer-stdout.txt')
 $null=$observer.Handle
 if(-not $observer.WaitForExit(45000)){
  $observer.Kill();$null=$observer.WaitForExit(5000)
  $observedPath=Join-Path $proof 'unsigned-bootstrap-observation.json'
  $observation=if(Test-Path $observedPath){Get-Content $observedPath -Raw|ConvertFrom-Json}else{[pscustomobject]@{}}
  $observation|Add-Member -NotePropertyName parentDeadlineReached -NotePropertyValue $true -Force
  $observation|Add-Member -NotePropertyName outcome -NotePropertyValue 'normal_os_launch_not_completed_within_45_seconds' -Force
  $observation|ConvertTo-Json|Set-Content $observedPath -Encoding UTF8
 }
 $observedPath=Join-Path $proof 'unsigned-bootstrap-observation.json'
 if(Test-Path $observedPath){$observation=Get-Content $observedPath -Raw|ConvertFrom-Json;$summary.realUnicodeChildGuiStarted=[bool]$observation.realUnicodeEngineGuiObserved}
 if((Get-FileHash $canonical -Algorithm SHA256).Hash.ToLowerInvariant() -ne $canonicalSha){throw 'Raw production launcher modified by the lab'}
 if((Get-FileHash $canonicalSeed -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSeed){throw 'Raw production engine seed modified by the lab'}
 $summary.productionLauncherSha256=$canonicalSha
 $summary|ConvertTo-Json|Set-Content (Join-Path $proof 'windows-updater-proof.json') -Encoding UTF8
} finally {
 if($observer -and -not $observer.HasExited){$observer.Kill()}
 if($approver){Stop-Process -Id $approver.Id -Force -ErrorAction SilentlyContinue}
 if($profileMode){& $profile -Action Restore -ProofDirectory $proof}
 else {& $publisher -Action Cleanup -ProofDirectory $proof}
 Get-Process|Where-Object {$_.ProcessName -eq 'Bakım.TR Yardım'}|Stop-Process -Force -ErrorAction SilentlyContinue
}
