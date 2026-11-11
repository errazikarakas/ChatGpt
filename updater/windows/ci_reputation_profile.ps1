# CI ONLY. Never shipped in the application or applied on user devices.
# Exactly one temporary Application Reputation policy value on a disposable,
# GitHub-hosted Windows test VM. The caller MUST invoke Restore in finally.
# No Defender Antivirus, Attachment Manager, MOTW, Edge or app-install policy changes.
# Microsoft policy mapping and value:
# https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-windowsexplorer#enablesmartscreen
# https://learn.microsoft.com/en-us/windows/privacy/manage-connections-from-windows-operating-system-components-to-microsoft-services#241-microsoft-defender-smartscreen
# https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-settingchange
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][ValidateSet('Apply','Restore')][string]$Action,
 [string]$ProofDirectory=(Join-Path $PSScriptRoot 'proof')
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2

# A production binary never calls this script. No force/skip-guard parameter.
if($PSVersionTable.PSVersion.Major -lt 7 -or -not $IsWindows){throw 'Disposable Windows PowerShell 7 runner required.'}
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:BAKIM_NATIVE_TESTS -cne '1' -or $env:BAKIM_CI_REPUTATION_PROFILE -cne '1'){throw 'Explicit disposable GitHub-hosted native-test reputation profile required.'}
if($env:GITHUB_REPOSITORY -cne 'errazikarakas/ChatGpt' -or $env:GITHUB_REF_NAME -cne 'bakim-yardim-build' -or $env:GITHUB_EVENT_NAME -notin @('push','workflow_dispatch')){throw 'Dedicated build repository/branch/event required.'}
if($env:GITHUB_RUN_ID -notmatch '^[0-9]{8,16}$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[1-9][0-9]*$' -or $env:GITHUB_SHA -notmatch '^[a-f0-9]{40}$' -or [string]::IsNullOrWhiteSpace($env:GITHUB_JOB) -or [string]::IsNullOrWhiteSpace($env:RUNNER_NAME)){throw 'Exact run, attempt, commit, job and runner identity required.'}
if([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or -not [IO.Path]::IsPathFullyQualified($env:RUNNER_TEMP) -or -not (Test-Path -LiteralPath $env:RUNNER_TEMP -PathType Container)){throw 'Absolute existing RUNNER_TEMP required.'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Disposable administrator test VM required.'}
$runnerTemp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
if(([IO.File]::GetAttributes($runnerTemp) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Runner temp reparse points are not allowed.'}
$profileRoot=Join-Path $runnerTemp ('bakim-ci-reputation-'+$env:GITHUB_RUN_ID+'-'+$env:GITHUB_RUN_ATTEMPT)
if((Test-Path -LiteralPath $profileRoot) -and (([IO.File]::GetAttributes($profileRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0)){throw 'Profile state directory reparse point refused.'}
$stateFile=Join-Path $profileRoot 'state.json'
$ProofDirectory=[IO.Path]::GetFullPath($ProofDirectory)
$proofFile=Join-Path $ProofDirectory 'ci-reputation-profile.jsonl'
$policyKey='SOFTWARE\Policies\Microsoft\Windows\System'
$valueName='EnableSmartScreen'
$prefixes=@('SOFTWARE','SOFTWARE\Policies','SOFTWARE\Policies\Microsoft','SOFTWARE\Policies\Microsoft\Windows',$policyKey)
$mutex=[Threading.Mutex]::new($false,('Local\BakimCIReputation.'+$env:GITHUB_RUN_ID+'.'+$env:GITHUB_RUN_ATTEMPT))
$locked=$false

function Write-ProfileProof([hashtable]$Data){
 $null=New-Item -ItemType Directory -Force -Path $ProofDirectory
 $Data.utc=[DateTime]::UtcNow.ToString('o');$Data.action=$Action;$Data.runId=$env:GITHUB_RUN_ID
 $Data.profileTestTemporary=$true;$Data.productionChanged=$false;$Data.DefenderAVChanged=$false;$Data.MOTWChanged=$false
 $Data.policy='HKLM64\'+$policyKey+'\'+$valueName
 $Data.userDeviceWarningSolved=$false
 Add-Content -LiteralPath $proofFile -Value ($Data|ConvertTo-Json -Compress -Depth 10) -Encoding UTF8
}
function Save-ProfileState($State){
 if(-not(Test-Path -LiteralPath $profileRoot)){$null=New-Item -ItemType Directory -Path $profileRoot}
 if(([IO.File]::GetAttributes($profileRoot) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Profile state reparse point refused.'}
 # A terminated Apply may leave an incomplete temporary file. A fresh unique
 # name keeps that debris from blocking the critical Restore operation.
 $newFile=Join-Path $profileRoot ('.state-'+[Guid]::NewGuid().ToString('N')+'.new')
 try{
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($State|ConvertTo-Json -Depth 10))
  $stream=[IO.FileStream]::new($newFile,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
  [IO.File]::Move($newFile,$stateFile,$true)
 }finally{if(Test-Path -LiteralPath $newFile){Remove-Item -LiteralPath $newFile -Force}}
}
function Encode-RegistryData([Microsoft.Win32.RegistryValueKind]$Kind,$Value){
 switch($Kind.ToString()){
  'DWord' {return ([int]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)}
  'QWord' {return ([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)}
  'Binary' {return [Convert]::ToBase64String([byte[]]$Value)}
  'None' {return [Convert]::ToBase64String([byte[]]$Value)}
  'MultiString' {return ,([string[]]$Value)}
  'String' {return [string]$Value}
  'ExpandString' {return [string]$Value}
  default {throw ('Unsupported saved registry type: '+$Kind)}
 }
}
function Decode-RegistryData([string]$Kind,$Value){
 switch($Kind){
  'DWord' {return [int]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)}
  'QWord' {return [long]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture)}
  'Binary' {return ,([Convert]::FromBase64String([string]$Value))}
  'None' {return ,([Convert]::FromBase64String([string]$Value))}
  'MultiString' {return ,([string[]]$Value)}
  'String' {return [string]$Value}
  'ExpandString' {return [string]$Value}
  default {throw ('Unsupported restore registry type: '+$Kind)}
 }
}
function Read-PolicySnapshot([Microsoft.Win32.RegistryKey]$Hive){
 $presence=@()
 foreach($path in $prefixes){
  $key=$Hive.OpenSubKey($path,$false)
  try{$presence+=,[PSCustomObject]@{path=$path;existed=($null -ne $key)}}finally{if($null -ne $key){$key.Dispose()}}
 }
 $key=$Hive.OpenSubKey($policyKey,$false)
 try{
  $exists=$null -ne $key -and @($key.GetValueNames()) -contains $valueName
  $kind='';$data=$null
  if($exists){$type=$key.GetValueKind($valueName);$kind=$type.ToString();$data=Encode-RegistryData -Kind $type -Value ($key.GetValue($valueName,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames))}
  return [PSCustomObject]@{keys=$presence;valueExisted=$exists;kind=$kind;data=$data}
 }finally{if($null -ne $key){$key.Dispose()}}
}
function Assert-OwnedProfileState($State){
 if($State.schema -ne 1 -or $State.runId -cne $env:GITHUB_RUN_ID -or $State.runAttempt -cne $env:GITHUB_RUN_ATTEMPT -or $State.sourceCommit -cne $env:GITHUB_SHA -or $State.job -cne $env:GITHUB_JOB -or $State.runnerName -cne $env:RUNNER_NAME -or $State.computerName -cne $env:COMPUTERNAME -or $State.sid -cne $identity.User.Value -or $State.nonce -notmatch '^[a-f0-9]{32}$' -or $State.policyKey -cne $policyKey -or $State.valueName -cne $valueName){throw 'Profile state does not belong to this exact disposable runner invocation.'}
 if(@($State.original.keys).Count -ne $prefixes.Count){throw 'Invalid owned registry key snapshot.'}
 for($i=0;$i -lt $prefixes.Count;$i++){if($State.original.keys[$i].path -cne $prefixes[$i] -or $State.original.keys[$i].existed -isnot [bool]){throw 'Non-owned registry key path or invalid snapshot.'}}
 if($State.original.valueExisted -isnot [bool] -or $State.applied -isnot [bool] -or $State.restored -isnot [bool]){throw 'Invalid profile state flags.'}
 if($State.original.valueExisted){$null=Decode-RegistryData -Kind $State.original.kind -Value $State.original.data}
}
function Restore-PolicySnapshot([Microsoft.Win32.RegistryKey]$Hive,$Original){
 $key=$Hive.OpenSubKey($policyKey,$true)
 if($Original.valueExisted){
  if($null -eq $key){$key=$Hive.CreateSubKey($policyKey,$true)}
  try{$kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$Original.kind);$data=Decode-RegistryData -Kind $Original.kind -Value $Original.data;$key.SetValue($valueName,$data,$kind);$key.Flush()}finally{$key.Dispose()}
 }elseif($null -ne $key){try{$key.DeleteValue($valueName,$false);$key.Flush()}finally{$key.Dispose()}}
 # Remove only keys that were originally absent AND are still empty. Never
 # delete a subtree or another process's newly created values/children.
 for($i=$prefixes.Count-1;$i -ge 0;$i--){
  if($Original.keys[$i].existed){continue}
  $path=$prefixes[$i];$key=$Hive.OpenSubKey($path,$false)
  if($null -eq $key){continue}
  try{$empty=$key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0}finally{$key.Dispose()}
  if(-not $empty){throw 'Originally absent policy key now contains non-owned data; refusing deletion.'}
  $Hive.DeleteSubKey($path,$false)
 }
 $actual=Read-PolicySnapshot $Hive
 if(($actual|ConvertTo-Json -Compress -Depth 8) -cne ($Original|ConvertTo-Json -Compress -Depth 8)){throw 'Typed registry snapshot was not restored exactly.'}
}
function Send-PolicyChange{
 if($null -eq ('BakimCiPolicyNotification' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BakimCiPolicyNotification {
 [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr parameter,
  string area, uint flags, uint timeout, out UIntPtr result);
}
'@
 }
 [UIntPtr]$result=[UIntPtr]::Zero
 # WM_SETTINGCHANGE/Policy. The application-sent wParam must be zero.
 $sent=[BakimCiPolicyNotification]::SendMessageTimeout([IntPtr]0xffff,0x001a,[UIntPtr]::Zero,'Policy',2,1000,[ref]$result)
 return $sent -ne [IntPtr]::Zero
}
function Invoke-ProfileRestore([Microsoft.Win32.RegistryKey]$Hive,$State){
 Restore-PolicySnapshot -Hive $Hive -Original $State.original
 $State.restored=$true;$State.restoredAt=[DateTime]::UtcNow.ToString('o');Save-ProfileState $State
 $notified=$false
 try{$notified=Send-PolicyChange}catch{}
 Write-ProfileProof @{phase='restored';profileRestored=$true;typedSnapshotRestored=$true;policyChangeBroadcastDelivered=$notified}
}
try{
 try{$locked=$mutex.WaitOne(15000)}catch [Threading.AbandonedMutexException]{$locked=$true}
 if(-not $locked){throw 'Owned profile mutex deadline exceeded.'}
 $hive=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,[Microsoft.Win32.RegistryView]::Registry64)
 try{
  if(Test-Path -LiteralPath $stateFile){
   if(([IO.File]::GetAttributes($stateFile) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Profile state file reparse point refused.'}
   $state=Get-Content -LiteralPath $stateFile -Raw|ConvertFrom-Json;Assert-OwnedProfileState $state
  }else{$state=$null}
  if($Action -eq 'Restore'){
   if($null -eq $state){Write-ProfileProof @{phase='already-absent';profileRestored=$true;noOwnedSnapshot=$true};return}
   if($state.restored){$actual=Read-PolicySnapshot $hive;if(($actual|ConvertTo-Json -Compress -Depth 8) -cne ($state.original|ConvertTo-Json -Compress -Depth 8)){throw 'Restored profile has changed after cleanup.'};Write-ProfileProof @{phase='already-restored';profileRestored=$true;typedSnapshotRestored=$true};return}
   Invoke-ProfileRestore -Hive $hive -State $state;return
  }
  if($null -ne $state){throw 'Owned profile state already exists. Restore instead of replacing its original snapshot.'}
  $original=Read-PolicySnapshot $hive
  $state=[PSCustomObject]@{schema=1;runId=$env:GITHUB_RUN_ID;runAttempt=$env:GITHUB_RUN_ATTEMPT;sourceCommit=$env:GITHUB_SHA;job=$env:GITHUB_JOB;runnerName=$env:RUNNER_NAME;computerName=$env:COMPUTERNAME;sid=$identity.User.Value;nonce=[Guid]::NewGuid().ToString('N');policyKey=$policyKey;valueName=$valueName;createdAt=[DateTime]::UtcNow.ToString('o');original=$original;applied=$false;restored=$false;restoredAt=''}
  Save-ProfileState $state
  try{
   $key=$hive.CreateSubKey($policyKey,$true)
   try{$key.SetValue($valueName,[int]0,[Microsoft.Win32.RegistryValueKind]::DWord);$key.Flush()}finally{$key.Dispose()}
   $actual=Read-PolicySnapshot $hive
   if(-not $actual.valueExisted -or $actual.kind -cne 'DWord' -or $actual.data -cne '0'){throw 'Temporary policy readback mismatch.'}
   $state.applied=$true;Save-ProfileState $state;$notified=Send-PolicyChange
   Write-ProfileProof @{phase='applied';profileRestored=$false;onlyChangedRegistryValue='EnableSmartScreen';temporaryDword=0;originalValueExisted=$original.valueExisted;originalValueKind=$original.kind;policyChangeBroadcastDelivered=$notified}
  }catch{
   $applyError=$_
   try{Invoke-ProfileRestore -Hive $hive -State $state}catch{Write-ProfileProof @{phase='rollback-failed';profileRestored=$false;errorType=$_.Exception.GetType().Name}}
   throw $applyError
  }
 }finally{$hive.Dispose()}
}finally{if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
