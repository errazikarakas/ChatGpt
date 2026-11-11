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
$env:BAKIM_CI_SIGN_SCRIPT=$signer
$canonical=Join-Path $base 'release/Bakim-TR-Yardim.exe'
$canonicalSha=(Get-FileHash $canonical -Algorithm SHA256).Hash.ToLowerInvariant()
$canonicalSeed=Join-Path $base 'launcher/seed/engine.exe'
$expectedSeed='d9ec96f4c8b6fa14e95e5aec4dc8998c84072ec470f088bd6b84f481092835a1'
if((Get-FileHash $canonicalSeed -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSeed){throw 'Original production seed changed'}
$approver=$null;$observer=$null
& $publisher -Action Initialize -ProofDirectory $proof
try {
 foreach($sourceFixture in @($env:BAKIM_FIXTURE_GOOD,$env:BAKIM_FIXTURE_BAD)){
  & $signer -Action Sign -File $sourceFixture -ProofDirectory $proof
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
  go test -v -count=1 -timeout=2m -skip TestWindowsExactProductionEngineChildGUI ./... 2>&1 | Tee-Object -FilePath (Join-Path $proof 'native-tests.txt')
  if($LASTEXITCODE -ne 0){throw 'Mandatory Windows native updater lifecycle tests failed'}
 } finally {Pop-Location}
 $summary=@{ok=$true;okScope='real-native-update-rollback-selfdelegation-with-embedded-signed-test-copies';launcherVersion='1.0.0';originalEnginePreserved=$true;productionLauncherPreserved=$true;signedUpdateAndHashChecks=$true;nativeAtomicVersionUpdate=$true;nativeRollback=$true;busySessionPreserved=$true;singleUpdater=$true;launcherSelfDelegation=$true;exactChildPidAndReadinessAck=$true;launcherEarlyExitRollback=$true;knownNewVersionStartsOnFirstOpen=$true;motwPreserved=$true;productionSecuritySettingsChanged=$false;ciTemporaryTrustStoresChanged=$true;smartScreenDefenderPoliciesChanged=$false;productionPublisherCertificateAvailable=$false;productionWindowsWarningsRemoved=$false;fixtureExecutablePrefixPreservedExceptAuthenticode=$true;canonicalUnsignedGuiMandatoryGate=$false;realUnicodeChildGuiStarted=$false}
 $summary|ConvertTo-Json|Set-Content (Join-Path $proof 'windows-updater-proof.json') -Encoding UTF8
 # Normal OS launch of the raw deliverable is a separate, strict observation.
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
 & $publisher -Action Cleanup -ProofDirectory $proof
 Get-Process|Where-Object {$_.ProcessName -eq 'Bakım.TR Yardım'}|Stop-Process -Force -ErrorAction SilentlyContinue
}
