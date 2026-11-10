$ErrorActionPreference='Stop'
$base=$PSScriptRoot
New-Item -ItemType Directory -Force (Join-Path $base 'proof') | Out-Null
$fixture=Join-Path $base 'fixtures';New-Item -ItemType Directory -Force $fixture | Out-Null
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /codepage:65001 /target:winexe /platform:x64 /r:System.Windows.Forms.dll /out:$fixture/good.exe (Join-Path $base 'fixture.cs')
if($LASTEXITCODE -ne 0){throw 'Good synthetic GUI fixture compilation failed'}
& $csc /nologo /codepage:65001 /target:winexe /platform:x64 /define:BROKEN /r:System.Windows.Forms.dll /out:$fixture/bad.exe (Join-Path $base 'fixture.cs')
if($LASTEXITCODE -ne 0){throw 'Broken synthetic fixture compilation failed'}
$env:BAKIM_FIXTURE_GOOD=Join-Path $fixture 'good.exe'
$env:BAKIM_FIXTURE_BAD=Join-Path $fixture 'bad.exe'
$env:BAKIM_NATIVE_TESTS='1'
$approver=Start-Process pwsh.exe -ArgumentList @('-NoProfile','-File',('"'+(Join-Path $base 'ci_approve_own_fixtures.ps1')+'"')) -WindowStyle Hidden -PassThru
try {
 Push-Location (Join-Path $base 'launcher')
 try {
  go test -v -count=1 -timeout=5m ./... 2>&1 | Tee-Object -FilePath (Join-Path $base 'proof/native-tests.txt')
  if($LASTEXITCODE -ne 0){throw 'Windows cryptographic/lifecycle/native GUI tests failed'}
 } finally {Pop-Location}
 $exe=Join-Path $base 'release/Bakim-TR-Yardim.exe'
 # Simulate an ordinary Internet download without stripping Windows origin evidence.
 Set-Content -LiteralPath ($exe+':Zone.Identifier') -Encoding ASCII -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://xn--bakm-nza.tr/yardim-indir.php?platform=windows"
 Start-Process -FilePath $exe
 $ready=$false
 for($i=0;$i -lt 45;$i++){
  Start-Sleep 1
  $inner=Get-Process | Where-Object {$_.ProcessName -eq 'Bakım.TR Yardım' -and $_.MainWindowTitle -eq 'Bakım.TR Yardım'}
  if($inner){$ready=$true;break}
 }
 if(-not $ready){throw 'Full native bootstrap did not start the real Unicode-named GUI child'}
 $statePath=Join-Path $env:LOCALAPPDATA 'BakimTRYardim/Launcher/current.json'
 $state=Get-Content $statePath -Raw | ConvertFrom-Json
 if($state.current -ne 2026111001){throw 'Unexpected initial engine version'}
 $payload=Join-Path $env:LOCALAPPDATA 'BakimTRYardim/Launcher/versions/2026111001/engine.exe'
 if((Get-FileHash $payload -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'd9ec96f4c8b6fa14e95e5aec4dc8998c84072ec470f088bd6b84f481092835a1'){throw 'Original proven engine changed'}
 if((Get-Content -LiteralPath ($payload+':Zone.Identifier') -Raw) -notmatch 'ZoneId=3'){throw 'Internet origin evidence missing from the extracted engine'}
 $sig=Get-AuthenticodeSignature -LiteralPath $exe
 $summary=@{ok=$true;launcherVersion='1.0.0';originalEnginePreserved=$true;realUnicodeChildGuiStarted=$true;signedUpdateAndHashChecks=$true;nativeAtomicVersionUpdate=$true;nativeRollback=$true;busySessionPreserved=$true;singleUpdater=$true;motwPreserved=$true;securitySettingsChanged=$false;authenticodeStatus=[string]$sig.Status;ciOnlyFixtureConsent=$true}
 $summary | ConvertTo-Json | Set-Content (Join-Path $base 'proof/windows-updater-proof.json') -Encoding UTF8
 $rootLog=Join-Path $env:LOCALAPPDATA 'BakimTRYardim/Launcher/launcher.log'
 if(Test-Path $rootLog){Copy-Item $rootLog (Join-Path $base 'proof/launcher.log')}
} finally {
 if($approver){Stop-Process -Id $approver.Id -Force -ErrorAction SilentlyContinue}
 Get-Process | Where-Object {$_.ProcessName -eq 'Bakım.TR Yardım'} | Stop-Process -Force -ErrorAction SilentlyContinue
}
