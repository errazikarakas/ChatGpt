# Disposable Windows CI diagnostic only. No GUI launch, no release signing.
[CmdletBinding()]
param([string]$WindowsSource=$PSScriptRoot,[string]$ProofDirectory=(Join-Path $PSScriptRoot 'proof'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
if($env:GITHUB_ACTIONS -ne 'true' -or $env:BAKIM_NATIVE_TESTS -ne '1' -or $env:GITHUB_RUN_ID -notmatch '^\d+$'){throw 'Disposable GitHub native-test runner required.'}
$WindowsSource=[IO.Path]::GetFullPath($WindowsSource)
$ProofDirectory=[IO.Path]::GetFullPath($ProofDirectory)
$null=New-Item -ItemType Directory -Force -Path $ProofDirectory
$work=Join-Path $WindowsSource ('fixtures\publisher-probe-'+$env:GITHUB_RUN_ID)
$null=New-Item -ItemType Directory -Force -Path $work
$pwsh=Join-Path $PSHOME 'pwsh.exe'
if(-not(Test-Path -LiteralPath $pwsh)){throw 'Run this CI probe with PowerShell 7.'}
$report=[ordered]@{labOnly=$true;runId=$env:GITHUB_RUN_ID;policyChanged=$false;motwChanged=$false;privateKeyExported=$false;guiLaunched=$false;calls=@();errors=@();embeddedCopyVerified=$false;cleanupSucceeded=$false}
$reportPath=Join-Path $ProofDirectory 'publisher-probe.json'
function Save-Report { [IO.File]::WriteAllText($reportPath,($script:report|ConvertTo-Json -Depth 10),[Text.Encoding]::UTF8) }
function Quote-Arg([string]$a){return '"'+[regex]::Replace([regex]::Replace($a,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
function Run-Call([string]$Name,[string]$Exe,[string[]]$Arguments,[int]$TimeoutSeconds=30){
 $n=[Guid]::NewGuid().ToString('N');$stdout=Join-Path $work ($n+'.out');$stderr=Join-Path $work ($n+'.err');$proc=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
 $row=[ordered]@{name=$Name;phase='started';timeoutSeconds=$TimeoutSeconds;timedOut=$false;exitCode=$null;elapsedMilliseconds=0;stdout='';stderr=''}
 $script:report.calls+=,$row;Save-Report
 try{
  $line=($Arguments|ForEach-Object{Quote-Arg $_}) -join ' '
  $proc=Start-Process -FilePath $Exe -ArgumentList $line -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
  $null=$proc.Handle
  if(-not $proc.WaitForExit($TimeoutSeconds*1000)){$row.timedOut=$true;try{$proc.Kill();$null=$proc.WaitForExit(5000)}catch{};throw ('Deadline: '+$Name)}
  $proc.Refresh();$row.exitCode=$proc.ExitCode
  if(Test-Path -LiteralPath $stdout){$row.stdout=([string](Get-Content -LiteralPath $stdout -Raw)).Trim()}
  if(Test-Path -LiteralPath $stderr){$row.stderr=([string](Get-Content -LiteralPath $stderr -Raw)).Trim()}
  if($row.stdout.Length -gt 6000){$row.stdout=$row.stdout.Substring(0,6000)}
  if($row.stderr.Length -gt 2500){$row.stderr=$row.stderr.Substring(0,2500)}
  if($row.exitCode -ne 0){throw ('Call failed: '+$Name+', exit='+$row.exitCode)}
  return [string]$row.stdout
 }finally{$watch.Stop();$row.elapsedMilliseconds=$watch.ElapsedMilliseconds;$row.phase='finished';if($null -ne $proc){$proc.Dispose()};Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue;Save-Report}
}
function Invoke-Lab([string]$Action,[string]$Path=''){
 $a=@('-NoProfile','-NonInteractive','-File',(Join-Path $WindowsSource 'ci_trusted_publisher.ps1'),'-Action',$Action,'-ProofDirectory',$ProofDirectory)
 if($Path){$a+=@('-File',$Path)}
 # Each native operation inside this helper has its own 30-second bound.
 return Run-Call -Name ('lab-'+$Action) -Exe $pwsh -Arguments $a -TimeoutSeconds 150
}
function Signature-Probe([string]$Name,[string]$Path){
 $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Path))
 $code='$ErrorActionPreference="Stop";Import-Module Microsoft.PowerShell.Security -ErrorAction Stop; $p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$encoded+'")); $s=Get-AuthenticodeSignature -LiteralPath $p; [PSCustomObject]@{status=[string]$s.Status;type=[string]$s.SignatureType;signerThumbprint=if($null -eq $s.SignerCertificate){""}else{$s.SignerCertificate.Thumbprint}}|ConvertTo-Json -Compress'
 $b64=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
 return ((Run-Call -Name $Name -Exe $pwsh -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',$b64))|ConvertFrom-Json)
}
function Assert-PePrefix([string]$Original,[string]$Signed){
 $before=[IO.File]::ReadAllBytes($Original);$after=[IO.File]::ReadAllBytes($Signed)
 if($before.Length -lt 128 -or $after.Length -le $before.Length -or [BitConverter]::ToUInt16($before,0) -ne 0x5a4d){throw 'Invalid PE diagnostic inputs.'}
 $pe=[BitConverter]::ToInt32($before,0x3c)
 if($pe -lt 64 -or $pe+256 -ge $before.Length -or [BitConverter]::ToUInt32($before,$pe) -ne 0x4550){throw 'Invalid NT header.'}
 $opt=$pe+24;$magic=[BitConverter]::ToUInt16($before,$opt)
 $directory=if($magic -eq 0x20b){$opt+112}elseif($magic -eq 0x10b){$opt+96}else{throw 'Unsupported optional header.'}
 $checksum=$opt+64;$security=$directory+32
 if([BitConverter]::ToUInt32($before,$security) -ne 0 -or [BitConverter]::ToUInt32($before,$security+4) -ne 0){throw 'Original fixture already contains a certificate table.'}
 $changed=0
 for($i=0;$i -lt $before.Length;$i++){
  if($before[$i] -eq $after[$i]){continue}
  if(($i -ge $checksum -and $i -lt $checksum+4) -or ($i -ge $security -and $i -lt $security+8)){$changed++;continue}
  throw ('Unexpected executable-prefix byte modification at '+$i)
 }
 [long]$offset=[BitConverter]::ToUInt32($after,$security);[long]$size=[BitConverter]::ToUInt32($after,$security+4)
 if($offset -lt $before.Length -or $offset%8 -ne 0 -or $offset-$before.Length -gt 7 -or $size -lt 8 -or $offset+$size -ne $after.LongLength){throw 'Certificate table is not the sole aligned append.'}
 for([long]$i=$before.LongLength;$i -lt $offset;$i++){if($after[$i] -ne 0){throw 'Nonzero pre-certificate padding.'}}
 [long]$length=[BitConverter]::ToUInt32($after,[int]$offset)
 if($length -lt 8 -or $length -gt $size -or [BitConverter]::ToUInt16($after,[int]$offset+4) -ne 0x200 -or [BitConverter]::ToUInt16($after,[int]$offset+6) -ne 2){throw 'Unexpected WIN_CERTIFICATE header.'}
 for([long]$i=$offset+$length;$i -lt $offset+$size;$i++){if($after[$i] -ne 0){throw 'Unexpected trailing certificate data.'}}
 return [ordered]@{originalBytes=$before.LongLength;signedBytes=$after.LongLength;prefixUnchangedExceptPeSigningFields=$true;changedHeaderBytes=$changed;certificateOffset=$offset;certificateTableBytes=$size;winCertificateLength=$length;certificateRevision='0x0200';certificateType=2}
}
$initialized=$false
try{
 $good=Join-Path $work 'good.exe';$embedded=Join-Path $work 'embedded.exe'
 $csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
 $null=Run-Call -Name 'compile-fixture' -Exe $csc -Arguments @('/nologo','/codepage:65001','/target:winexe','/reference:System.Windows.Forms.dll',('/out:'+$good),(Join-Path $WindowsSource 'fixture.cs'))
 $originalHash=(Get-FileHash -LiteralPath $good -Algorithm SHA256).Hash.ToLowerInvariant();$report.originalSha256=$originalHash
 $null=Invoke-Lab -Action Initialize;$initialized=$true
 try{$null=Invoke-Lab -Action Add -Path $good}catch{$report.errors+=('catalog-add: '+$_.Exception.Message);Save-Report}
 $statePath=Join-Path $env:RUNNER_TEMP ('bakim-publisher-lab-'+$env:GITHUB_RUN_ID+'\state.json')
 $state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
 if($state.runId -ne $env:GITHUB_RUN_ID -or $state.nonce -notmatch '^[a-f0-9]{32}$' -or $state.thumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or $state.subject -ne ('CN=Bakim CI disposable '+$env:GITHUB_RUN_ID+' '+$state.nonce)){throw 'Owned publisher state mismatch.'}
 $cert=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$state.thumbprint)
 if($cert.Subject -ne $state.subject -or -not $cert.HasPrivateKey){throw 'Owned certificate mismatch.'}
 $report.thumbprint=$state.thumbprint
 $catalog=@($state.catalogs|Where-Object{$_.fileSha256 -eq $originalHash})[0]
 $labRoot=Split-Path -Parent $statePath
 if($catalog.name -notmatch ('^bakim-ci-'+$state.nonce+'-[a-f0-9]{32}\.cat$') -or [IO.Path]::GetFullPath($catalog.path) -ne (Join-Path $labRoot $catalog.name)){throw 'Owned catalog mismatch.'}
 foreach($probe in @(
  @{name='catalog-explicit';args=@('verify','/v','/pa','/c',$catalog.path,$good)},
  @{name='catalog-default-db';args=@('verify','/v','/a','/ad','/hash','SHA256','/pa',$good)},
  @{name='catalog-system-db';args=@('verify','/v','/a','/as','/hash','SHA256','/pa',$good)}
 )){try{$null=Run-Call -Name $probe.name -Exe $state.signTool -Arguments $probe.args}catch{$report.errors+=($probe.name+': '+$_.Exception.Message)}}
 $report.catalogGetAuthenticode=Signature-Probe -Name 'catalog-GetAuthenticodeSignature' -Path $good
 if((Get-FileHash -LiteralPath $good -Algorithm SHA256).Hash.ToLowerInvariant() -ne $originalHash){throw 'Catalog operation modified original fixture.'}
 Copy-Item -LiteralPath $good -Destination $embedded
 $null=Run-Call -Name 'embedded-copy-sign' -Exe $state.signTool -Arguments @('sign','/fd','SHA256','/sha1',$state.thumbprint,'/s','My',$embedded)
 $report.embeddedGetAuthenticode=Signature-Probe -Name 'embedded-GetAuthenticodeSignature' -Path $embedded
 if($report.embeddedGetAuthenticode.status -ne 'Valid' -or $report.embeddedGetAuthenticode.signerThumbprint -ne $state.thumbprint){throw 'Embedded copy trust verification failed.'}
 $report.pePrefix=Assert-PePrefix -Original $good -Signed $embedded
 $report.originalUnchanged=((Get-FileHash -LiteralPath $good -Algorithm SHA256).Hash.ToLowerInvariant() -eq $originalHash)
 if(-not $report.originalUnchanged){throw 'Original fixture changed.'}
 $report.embeddedCopyVerified=$true
}catch{$report.errors+=('fatal: '+$_.Exception.Message);throw}finally{
 try{$null=Invoke-Lab -Action Cleanup;$report.cleanupSucceeded=$true}catch{$report.errors+=('cleanup: '+$_.Exception.Message)}
 Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
 Save-Report
}
