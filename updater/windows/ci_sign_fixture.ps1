# Disposable CI fixture signing only. Never sign production seed/release files.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('Sign','Verify')][string]$Action,[Parameter(Mandatory=$true)][string]$File,[string]$ProofDirectory=(Join-Path $PSScriptRoot 'proof'))
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if($env:GITHUB_ACTIONS -ne 'true' -or $env:BAKIM_NATIVE_TESTS -ne '1' -or $env:GITHUB_RUN_ID -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)){throw 'Disposable GitHub native-test runner required.'}
Import-Module Microsoft.PowerShell.Security -ErrorAction Stop
$pwsh=Join-Path $PSHOME 'pwsh.exe'
if(-not(Test-Path -LiteralPath $pwsh)){throw 'PowerShell 7 required for isolated CI signing.'}
$null=New-Item -ItemType Directory -Force -Path $ProofDirectory
$proofFile=Join-Path $ProofDirectory 'ci-signed-fixtures.jsonl'
$work=Join-Path $env:RUNNER_TEMP ('bakim-fixture-sign-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work
function Audit([hashtable]$row){
 $row.utc=[DateTime]::UtcNow.ToString('o');$row.action=$Action;$row.fileName=[IO.Path]::GetFileName($File);$row.labOnly=$true;$row.TemporaryMachineTrust=$true;$row.productionChanged=$false;$row.privateKeyExported=$false
 Add-Content -LiteralPath $proofFile -Value ($row|ConvertTo-Json -Compress -Depth 7) -Encoding UTF8
}
function Quote-Arg([string]$a){return '"'+[regex]::Replace([regex]::Replace($a,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'}
function Run-Bounded([string]$Name,[string]$Exe,[string[]]$Arguments){
 $nonce=[Guid]::NewGuid().ToString('N');$stdout=Join-Path $work ($nonce+'.out');$stderr=Join-Path $work ($nonce+'.err');$process=$null;$watch=[Diagnostics.Stopwatch]::StartNew();$timeout=$false
 Audit @{step=$Name;phase='before';timeoutSeconds=30}
 try{
  $line=($Arguments|ForEach-Object{Quote-Arg $_}) -join ' '
  $process=Start-Process -FilePath $Exe -ArgumentList $line -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -WindowStyle Hidden
  $null=$process.Handle
  if(-not $process.WaitForExit(30000)){$timeout=$true;try{$process.Kill();$null=$process.WaitForExit(5000)}catch{};throw ('Fixture call deadline: '+$Name)}
  $process.Refresh();$exit=$process.ExitCode
  $output=if(Test-Path -LiteralPath $stdout){[IO.File]::ReadAllText($stdout)}else{''}
  $errorOutput=if(Test-Path -LiteralPath $stderr){[IO.File]::ReadAllText($stderr)}else{''}
  if($exit -ne 0){throw ('Fixture call failed: '+$Name+', exit='+$exit+': '+$errorOutput.Trim())}
  return [string]$output
 }finally{$watch.Stop();Audit @{step=$Name;phase='after';elapsedMilliseconds=$watch.ElapsedMilliseconds;timeout=$timeout};if($null -ne $process){$process.Dispose()};Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue}
}
function Get-Motw([string]$Path){
 $stream=Get-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue
 if($null -eq $stream){return 'absent'}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path+':Zone.Identifier')))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Check-Signature([string]$Path){
 $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Path))
 $code='$ErrorActionPreference="Stop";Import-Module Microsoft.PowerShell.Security -ErrorAction Stop;$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$encoded+'"));$s=Get-AuthenticodeSignature -LiteralPath $p;[PSCustomObject]@{status=[string]$s.Status;type=[string]$s.SignatureType;thumbprint=if($null -eq $s.SignerCertificate){""}else{$s.SignerCertificate.Thumbprint}}|ConvertTo-Json -Compress'
 $b64=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
 $result=(Run-Bounded -Name 'GetAuthenticodeSignature' -Exe $pwsh -Arguments @('-NoProfile','-NonInteractive','-EncodedCommand',$b64))|ConvertFrom-Json
 if($result.status -ne 'Valid' -or $result.thumbprint -ne $script:state.thumbprint){throw ('Fixture signature not owned/trusted: '+$result.status)}
 return $result
}

function Assert-PePrefix([byte[]]$before,[byte[]]$after){
 if($before.Length -lt 128 -or $after.Length -le $before.Length -or [BitConverter]::ToUInt16($before,0) -ne 0x5a4d){throw 'Invalid PE diagnostic inputs.'}
 $pe=[BitConverter]::ToInt32($before,0x3c)
 if($pe -lt 64 -or $pe+256 -ge $before.Length -or [BitConverter]::ToUInt32($before,$pe) -ne 0x4550){throw 'Invalid NT header.'}
 $opt=$pe+24;$magic=[BitConverter]::ToUInt16($before,$opt)
 $directory=if($magic -eq 0x20b){$opt+112}elseif($magic -eq 0x10b){$opt+96}else{throw 'Unsupported optional header.'}
 $checksum=$opt+64;$security=$directory+32
 if([BitConverter]::ToUInt32($before,$security) -ne 0 -or [BitConverter]::ToUInt32($before,$security+4) -ne 0){throw 'Original fixture already contains a certificate table.'}
 [long]$offset=[BitConverter]::ToUInt32($after,$security);[long]$size=[BitConverter]::ToUInt32($after,$security+4)
 $changed=0
 foreach($i in (($checksum..($checksum+3))+($security..($security+7)))){if($before[$i] -ne $after[$i]){$changed++}}
 # Mask only the PE signing metadata IN RAM, then hash the entire original-length
 # prefix. Never rewrite the executable or walk a 35 MB Go image in PowerShell.
 [Array]::Clear($before,$checksum,4);[Array]::Clear($before,$security,8)
 [Array]::Clear($after,$checksum,4);[Array]::Clear($after,$security,8)
 $digest=[Security.Cryptography.SHA256]::Create()
 try{$prefixBefore=([BitConverter]::ToString($digest.ComputeHash($before,0,$before.Length))).Replace('-','').ToLowerInvariant();$prefixAfter=([BitConverter]::ToString($digest.ComputeHash($after,0,$before.Length))).Replace('-','').ToLowerInvariant()}finally{$digest.Dispose()}
 if($prefixBefore -ne $prefixAfter){throw 'Executable prefix changed beyond the 12 allowed PE signing metadata bytes.'}
 if($offset -lt $before.Length -or $offset%8 -ne 0 -or $offset-$before.Length -gt 7 -or $size -lt 8 -or $offset+$size -ne $after.LongLength){throw 'Certificate table is not the sole aligned append.'}
 for([long]$i=$before.LongLength;$i -lt $offset;$i++){if($after[$i] -ne 0){throw 'Nonzero pre-certificate padding.'}}
 [long]$length=[BitConverter]::ToUInt32($after,[int]$offset)
 if($length -lt 8 -or $length -gt $size -or [BitConverter]::ToUInt16($after,[int]$offset+4) -ne 0x200 -or [BitConverter]::ToUInt16($after,[int]$offset+6) -ne 2){throw 'Unexpected WIN_CERTIFICATE header.'}
 for([long]$i=$offset+$length;$i -lt $offset+$size;$i++){if($after[$i] -ne 0){throw 'Unexpected trailing certificate data.'}}
 return [ordered]@{originalBytes=$before.LongLength;signedBytes=$after.LongLength;prefixUnchangedExceptPeSigningFields=$true;maskedPrefixSha256=$prefixBefore;changedHeaderBytes=$changed;certificateOffset=$offset;certificateTableBytes=$size;winCertificateLength=$length;certificateRevision='0x0200';certificateType=2}
}

try{
 $statePath=Join-Path $env:RUNNER_TEMP ('bakim-publisher-lab-'+$env:GITHUB_RUN_ID+'\state.json')
 $script:state=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
 if($state.runId -ne $env:GITHUB_RUN_ID -or $state.nonce -notmatch '^[a-f0-9]{32}$' -or $state.thumbprint -notmatch '^[a-fA-F0-9]{40}$' -or $state.subject -ne ('CN=Bakim CI disposable '+$env:GITHUB_RUN_ID+' '+$state.nonce) -or $state.trustLocation -ne 'LocalMachine'){throw 'Owned disposable publisher state mismatch.'}
 $certificate=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$state.thumbprint)
 if($certificate.Subject -ne $state.subject -or -not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date)){throw 'Owned disposable signing key unavailable.'}
 $sdkRoot=[IO.Path]::GetFullPath((Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin')).TrimEnd('\')+'\'
 if(-not([IO.Path]::GetFullPath($state.signTool).StartsWith($sdkRoot,[StringComparison]::OrdinalIgnoreCase)) -or [IO.Path]::GetFileName($state.signTool) -ne 'signtool.exe'){throw 'Unexpected signing executable.'}
 $item=Get-Item -LiteralPath $File
 if($item.PSIsContainer -or $item.Extension -ne '.exe' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Ordinary fixture EXE required.'}
 $File=$item.FullName
 $fixtureRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'fixtures')).TrimEnd('\')+'\'
 $tempRoot=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
 $inFixtures=$File.StartsWith($fixtureRoot,[StringComparison]::OrdinalIgnoreCase)
 $inNative=$File.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and $File.Substring($tempRoot.Length) -match '^TestWindows[^\\]+\\'
 if(-not($inFixtures -or $inNative)){throw 'Refusing to sign/verify a production or out-of-scope executable.'}
 if($Action -eq 'Sign' -and $inNative -and $item.Name -notin @('good.exe','bad.exe','next-launcher.exe')){throw 'Only native fixture source images may be signed.'}
 $beforeSha=(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant();$motwBefore=Get-Motw $File
 $prefix=$null
 if($Action -eq 'Sign'){
  $before=[IO.File]::ReadAllBytes($File)
  $null=Run-Bounded -Name 'SignTool-fixture-sign' -Exe $state.signTool -Arguments @('sign','/fd','SHA256','/sha1',$state.thumbprint,'/s','My',$File)
  $prefix=Assert-PePrefix -before $before -after ([IO.File]::ReadAllBytes($File))
 }
 $signature=Check-Signature $File
 $afterSha=(Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant();$motwAfter=Get-Motw $File
 if($motwBefore -ne $motwAfter){throw 'Mark-of-the-Web changed during fixture signing/verification.'}
 if($Action -eq 'Verify' -and $beforeSha -ne $afterSha){throw 'Read-only fixture verification changed the executable.'}
 Audit @{step='result';status='Valid';signatureType=$signature.type;signerThumbprint=$state.thumbprint;sha256=$afterSha;originalSha256=$beforeSha;bytes=(Get-Item -LiteralPath $File).Length;prefixUnchangedExceptPeSigningFields=($Action -eq 'Sign');pePrefix=$prefix;motwPreserved=$true;motwPresent=($motwAfter -ne 'absent');fileUnchanged=($beforeSha -eq $afterSha)}
}catch{Audit @{step='result';status='failed';message=$_.Exception.Message};throw}finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
