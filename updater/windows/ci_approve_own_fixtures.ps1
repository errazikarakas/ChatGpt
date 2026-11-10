# CI-ONLY: normal user consent for this repository's disposable Windows fixtures.
# Never packaged. No Defender, policy, MOTW, Zone.Identifier or registry changes.
param([int]$MaximumSeconds=600,[string]$ProofDirectory='')
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:BAKIM_NATIVE_TESTS -ne '1'){exit 12}
if(-not $ProofDirectory){$ProofDirectory=Join-Path $PSScriptRoot 'proof'}
New-Item -ItemType Directory -Force $ProofDirectory | Out-Null
$eventFile=Join-Path $ProofDirectory 'ci-consent-events.jsonl'
$windowFile=Join-Path $ProofDirectory 'ci-consent-windows.json'
$events=0;$captures=0
function Redact([string]$Value){
 if(-not $Value){return ''}
 foreach($pair in @(@($PSScriptRoot,'<WORKSPACE>'),@($env:LOCALAPPDATA,'<LOCALAPPDATA>'),@($env:TEMP,'<TEMP>'),@($env:USERPROFILE,'<PROFILE>'))){if($pair[0]){$Value=$Value -replace [regex]::Escape([string]$pair[0]),[string]$pair[1]}}
 $Value=$Value -replace '(?i)([?&](?:fixture|token|password|key|id)=)[^&\s]+','$1<REDACTED>'
 $Value=$Value -replace '(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}','<EMAIL>'
 if($Value.Length -gt 4096){$Value=$Value.Substring(0,4096)}
 return $Value
}
function Event([hashtable]$Data){
 if($script:events -ge 160){return};$script:events++
 $Data['utc']=[DateTime]::UtcNow.ToString('o')
 $Data | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $eventFile -Encoding UTF8
}
try {
 Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class BakimCiConsent {
 public struct Rect { public int Left,Top,Right,Bottom; }
 public class Node { public long Handle; public uint ProcessId; public string Title,ClassName; public bool Visible,Enabled; public Rect Bounds; }
 private delegate bool EnumProc(IntPtr h,IntPtr arg);
 [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb,IntPtr arg);
 [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr p,EnumProc cb,IntPtr arg);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr h,StringBuilder b,int n);
 [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h,uint c);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr h,int a,out Rect r,int n);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,UIntPtr e);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h,uint m,UIntPtr w,IntPtr l,uint f,uint t,out UIntPtr v);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] private static extern uint GetLongPathName(string s,StringBuilder b,uint n);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] private static extern uint GetShortPathName(string s,StringBuilder b,uint n);
 private static Node Read(IntPtr h){var a=new StringBuilder(32768);var b=new StringBuilder(256);uint p;Rect r;GetWindowText(h,a,a.Capacity);GetClassName(h,b,b.Capacity);GetWindowThreadProcessId(h,out p);GetWindowRect(h,out r);try{Rect physical;if(DwmGetWindowAttribute(h,9,out physical,Marshal.SizeOf(typeof(Rect)))==0)r=physical;}catch{}return new Node{Handle=h.ToInt64(),ProcessId=p,Title=a.ToString(),ClassName=b.ToString(),Visible=IsWindowVisible(h),Enabled=IsWindowEnabled(h),Bounds=r};}
 public static Node[] Windows(){var l=new List<Node>();EnumWindows((h,a)=>{if(IsWindowVisible(h))l.Add(Read(h));return true;},IntPtr.Zero);return l.ToArray();}
 public static Node[] Children(long p){var l=new List<Node>();EnumChildWindows(new IntPtr(p),(h,a)=>{l.Add(Read(h));return true;},IntPtr.Zero);return l.ToArray();}
 public static uint Process(long h){uint p;GetWindowThreadProcessId(new IntPtr(h),out p);return p;}
 public static string LongPath(string p){var b=new StringBuilder(32768);return GetLongPathName(p,b,(uint)b.Capacity)>0?b.ToString():p;}
 public static string ShortPath(string p){var b=new StringBuilder(32768);return GetShortPathName(p,b,(uint)b.Capacity)>0?b.ToString():p;}
}
'@
} catch {Event @{event='setup-failed';error=Redact $_.Exception.Message};exit 13}
try{[void][BakimCiConsent]::SetProcessDPIAware()}catch{}
$uia=$false;$drawing=$false
try {Add-Type -AssemblyName UIAutomationClient;Add-Type -AssemblyName UIAutomationTypes;$uia=$true}catch{Event @{event='uia-unavailable-native-fallback';error=Redact $_.Exception.Message}}
try {Add-Type -AssemblyName System.Drawing;$drawing=$true}catch{Event @{event='drawing-unavailable';error=Redact $_.Exception.Message}}
$testRootPattern='^TestWindows(?:RealSignedUpdateBusyDeferralAndRollback|ExactProductionEngineChildGUI|ActualLauncherDelegationAndExactChildRollback)[0-9]+$'
$knownHashes=@{};$candidates=@();$processInfo=@{};$lastRefresh=[DateTime]::MinValue
$seen=@{};$attempts=@{};$lastClick=@{}
$script:driverIdentity=$null
try{
 $selfDetails=Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID) -ErrorAction Stop
 $driver=Get-Process -Id ([int]$selfDetails.ParentProcessId) -ErrorAction Stop
 $script:driverIdentity=@{processId=$driver.Id;startTicks=$driver.StartTime.ToUniversalTime().Ticks}
}catch{}

function Add-KnownHash([string]$Path){if($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)){try{$script:knownHashes[(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()]=$true}catch{}}}
function Refresh-Known {
 if(((Get-Date)-$script:lastRefresh).TotalSeconds -lt 2){return};$script:lastRefresh=Get-Date
 foreach($file in @($env:BAKIM_FIXTURE_GOOD,$env:BAKIM_FIXTURE_BAD,(Join-Path $PSScriptRoot 'launcher/seed/engine.exe'),(Join-Path $PSScriptRoot 'release/Bakim-TR-Yardim.exe'))){Add-KnownHash $file}
 $roots=@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -ErrorAction SilentlyContinue | Where-Object {$_.Name -match $testRootPattern})
 foreach($root in $roots){foreach($file in @(Get-ChildItem -LiteralPath $root.FullName -Filter 'next-launcher.exe' -Recurse -File -ErrorAction SilentlyContinue)){Add-KnownHash $file.FullName}}
 $paths=New-Object 'System.Collections.Generic.List[string]'
 foreach($root in $roots){foreach($file in @(Get-ChildItem -LiteralPath $root.FullName -Filter '*.exe' -Recurse -File -ErrorAction SilentlyContinue)){if($file.FullName -match '\\(?:launchers\\)?versions\\[0-9]+\\(?:engine|launcher)\.exe$'){$paths.Add($file.FullName)}}}
 $realRoot=Join-Path $env:LOCALAPPDATA 'BakimTRYardim/Launcher/versions'
 if(Test-Path -LiteralPath $realRoot){foreach($file in @(Get-ChildItem -LiteralPath $realRoot -Filter 'engine.exe' -Recurse -File -ErrorAction SilentlyContinue)){$paths.Add($file.FullName)}}
 $release=Join-Path $PSScriptRoot 'release/Bakim-TR-Yardim.exe';if(Test-Path -LiteralPath $release){$paths.Add($release)}
 $script:candidates=@()
 foreach($path in @($paths | Select-Object -Unique)){try{$hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();if($script:knownHashes.ContainsKey($hash)){$full=[BakimCiConsent]::LongPath([IO.Path]::GetFullPath($path));$script:candidates+=@{path=$full;short=[BakimCiConsent]::ShortPath($full);name=[IO.Path]::GetFileName($full);sha256=$hash}}}catch{}}
 $script:processInfo=@{};try{foreach($p in Get-CimInstance Win32_Process -ErrorAction Stop){$script:processInfo[[int]$p.ProcessId]=$p}}catch{}
}
function Trusted-Caller([int]$ProcessId){
 if($script:driverIdentity -and $ProcessId -eq $script:driverIdentity.processId){
  try{$driver=Get-Process -Id $ProcessId -ErrorAction Stop;if($driver.StartTime.ToUniversalTime().Ticks -eq $script:driverIdentity.startTicks){return $true}}catch{}
 }

 for($depth=0;$depth -lt 5 -and $ProcessId -gt 0;$depth++){
  $p=$script:processInfo[$ProcessId];if(-not $p){return $false}
  if($p.Name -match '\.test\.exe$' -and $p.ExecutablePath -match '\\go-build[^\\]+\\'){return $true}
  foreach($known in $script:candidates){if($p.ExecutablePath -and ([BakimCiConsent]::LongPath([string]$p.ExecutablePath) -ieq $known.path)){return $true}}
  $ProcessId=[int]$p.ParentProcessId
 };return $false
}
function Pending-Match([string]$DialogText){
 $file=Join-Path $ProofDirectory 'ci-pending-launch.json'
 if(-not (Test-Path -LiteralPath $file -PathType Leaf)){return @()}
 try{
  if((Get-Item -LiteralPath $file).Length -gt 4096){return @()}
  $pending=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
  if(-not ($pending.path -is [string]) -or -not ($pending.sha256 -is [string]) -or $pending.sha256 -notmatch '^[0-9a-fA-F]{64}$'){return @()}
  $callerId=[int]$pending.callerPid;if($callerId -le 0){return @()}
  $when=[datetime]::Parse([string]$pending.utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
  $age=([datetime]::UtcNow-$when).TotalSeconds;if($age -gt 120 -or $age -lt -10){return @()}
  $live=Get-Process -Id $callerId -ErrorAction Stop
  if(-not $script:processInfo.ContainsKey($callerId)){
   $detail=Get-CimInstance Win32_Process -Filter ('ProcessId='+$callerId) -ErrorAction Stop
   if($detail){$script:processInfo[$callerId]=$detail}
  }
  if(-not (Trusted-Caller $callerId)){return @()}
  $full=[BakimCiConsent]::LongPath([IO.Path]::GetFullPath([string]$pending.path))
  $same=@($script:candidates | Where-Object {$_.path -ieq $full -and $_.sha256 -ieq $pending.sha256})
  if($same.Count -eq 0 -or -not $script:knownHashes.ContainsKey($pending.sha256.ToLowerInvariant())){return @()}
  if((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ine $pending.sha256){return @()}
  $names=@($same | Where-Object {$DialogText -match ('(?i)(?<![A-Za-z0-9_-])'+[regex]::Escape($_.name)+'(?![A-Za-z0-9_.-])')})
  if($names.Count -gt 0){return $names}
  # VersionInfo may display the branded product name rather than the executable filename.
  $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($full)
  foreach($label in @($version.FileDescription,$version.ProductName)){
   if($label -and $label -match '(?i)^Bak[ıi]m[. -]?TR.*Yard[ıi]m' -and $DialogText.IndexOf($label,[StringComparison]::OrdinalIgnoreCase) -ge 0){return $same}
  }
 }catch{}
 return @()
}
function Text-And-Actions($Window,$Native){
 $texts=New-Object 'System.Collections.Generic.List[string]';$actions=New-Object 'System.Collections.Generic.List[object]';$texts.Add([string]$Window.Title)
 foreach($item in $Native){if($item.Title){$texts.Add([string]$item.Title)};if($item.ClassName -eq 'Button' -and $item.Visible -and $item.Enabled){$r=$item.Bounds;$actions.Add(@{name=[string]$item.Title;node=$null;handle=$item.Handle;rect=@($r.Left,$r.Top,($r.Right-$r.Left),($r.Bottom-$r.Top))})}}
 if($script:uia){try{$element=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Window.Handle);$items=$element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition);foreach($item in $items){$c=$item.Current;if($c.Name){$texts.Add([string]$c.Name)};if($c.HelpText){$texts.Add([string]$c.HelpText)};try{$value=$item.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value;if($value){$texts.Add([string]$value)}}catch{};if($c.IsEnabled -and -not $c.IsOffscreen -and $c.Name){$r=$c.BoundingRectangle;if($r.Width -gt 1 -and $r.Height -gt 1){$actions.Add(@{name=[string]$c.Name;node=$item;handle=[long]$c.NativeWindowHandle;rect=@($r.X,$r.Y,$r.Width,$r.Height)})}}}}catch{}}
 return @{text=($texts -join "`n");actions=$actions}
}
function Save-Dialog($Window){
 if(-not $script:drawing -or $script:captures -ge 12){return};$r=$Window.Bounds;$w=$r.Right-$r.Left;$h=$r.Bottom-$r.Top
 if($w -lt 20 -or $h -lt 20 -or $w -gt 2400 -or $h -gt 1600){return}
 try{$bitmap=New-Object System.Drawing.Bitmap($w,$h);$graphics=[System.Drawing.Graphics]::FromImage($bitmap);try{$graphics.CopyFromScreen($r.Left,$r.Top,0,0,$bitmap.Size);$script:captures++;$bitmap.Save((Join-Path $ProofDirectory ('ci-consent-dialog-{0:D2}.png' -f $script:captures)),[System.Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}}catch{Event @{event='dialog-crop-failed';error=Redact $_.Exception.Message}}
}
function Click-Action($Window,$Action,[int]$Attempt){
 $nativeHandle=[long]$Action.handle
 if($Attempt -eq 1 -and $Action.node){try{$Action.node.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke();return 'UIA-Invoke'}catch{}}
 if($Attempt -le 2 -and $nativeHandle -ne 0){try{$value=[UIntPtr]::Zero;$ok=[BakimCiConsent]::SendMessageTimeout([IntPtr]$nativeHandle,0xF5,[UIntPtr]::Zero,[IntPtr]::Zero,2,600,[ref]$value);if($ok -ne [IntPtr]::Zero){return 'Button-Click'}}catch{}}
 $r=$Action.rect;$outer=$Window.Bounds;$x=[int]($r[0]+$r[2]/2);$y=[int]($r[1]+$r[3]/2)
 if($x -lt $outer.Left -or $x -ge $outer.Right -or $y -lt $outer.Top -or $y -ge $outer.Bottom){return 'rejected-outside-dialog'}
 [void][BakimCiConsent]::ShowWindow([IntPtr]$Window.Handle,9);[void][BakimCiConsent]::SetForegroundWindow([IntPtr]$Window.Handle);Start-Sleep -Milliseconds 80
 [void][BakimCiConsent]::SetCursorPos($x,$y);[BakimCiConsent]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[BakimCiConsent]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 return 'Normal-Mouse-Click'
}
Event @{event='watcher-start';uia=$uia;nativeEnumeration=$true;securitySettingsChanged=$false;motwChanged=$false}
$until=(Get-Date).AddSeconds($MaximumSeconds);$lastSnapshot=[DateTime]::MinValue
while((Get-Date) -lt $until){
 try {
  Refresh-Known;$windows=@([BakimCiConsent]::Windows())
  if(((Get-Date)-$lastSnapshot).TotalSeconds -ge 8){$lastSnapshot=Get-Date;@($windows | ForEach-Object {@{handle=$_.Handle;pid=$_.ProcessId;class=$_.ClassName;title=Redact $_.Title}}) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $windowFile -Encoding UTF8}
  foreach($window in $windows){
   $p=$script:processInfo[[int]$window.ProcessId];$securityTitle=$window.Title -match '(?i)Security Warning|Windows Security|SmartScreen|Windows protected|Windows Defender|Güvenlik Uyarısı|Windows.*korudu';$securityProcess=$p -and $p.Name -match '(?i)^smartscreen\.exe$'
   if(-not $securityTitle -and -not $securityProcess -and $window.ClassName -ne '#32770'){continue}
   $native=@([BakimCiConsent]::Children($window.Handle));$content=Text-And-Actions $window $native
   if(-not $securityTitle -and -not $securityProcess -and $content.text -notmatch '(?i)Publisher|Open File|Security Warning|Yayımcı|Yayıncı|Güvenlik Uyarısı'){continue}
   $text=[string]$content.text;$normalized=$text.Replace('/','\').ToLowerInvariant()
   $matched=@($script:candidates | Where-Object {$normalized.Contains($_.path.ToLowerInvariant()) -or $normalized.Contains($_.short.ToLowerInvariant())});$authorization='exact-full-or-short-path-and-known-hash'
   if($matched.Count -eq 0){$owner=[BakimCiConsent]::GetWindow([IntPtr]$window.Handle,4);$ownerPid=if($owner -ne [IntPtr]::Zero){[BakimCiConsent]::Process($owner.ToInt64())}else{0};$caller=(Trusted-Caller ([int]$window.ProcessId)) -or (Trusted-Caller ([int]$ownerPid));if($caller){$matched=@($script:candidates | Where-Object {$text -match ('(?i)(?<![A-Za-z0-9_-])'+[regex]::Escape($_.name)+'(?![A-Za-z0-9_.-])')});$authorization='known-hashed-fixture-name-and-trusted-test-caller'}}
   if($matched.Count -eq 0){$pendingMatch=@(Pending-Match $text);if($pendingMatch.Count -gt 0){$matched=$pendingMatch;$authorization='pending-exact-path-sha-live-caller-ttl120'}}
   $stateKey=[string]$window.Handle+'|'+[string]$text.GetHashCode()
   if(-not $seen.ContainsKey($stateKey)){$seen[$stateKey]=$true;Event @{event='security-dialog';handle=$window.Handle;pid=$window.ProcessId;class=$window.ClassName;title=Redact $window.Title;text=Redact $text;authorized=($matched.Count -gt 0);authorization=$authorization;matchingNames=@($matched | ForEach-Object {$_.name} | Select-Object -Unique);buttons=@($content.actions | ForEach-Object {Redact $_.name} | Select-Object -Unique)};Save-Dialog $window}
   foreach($wanted in @('More info','Daha fazla bilgi','Run anyway','Yine de çalıştır','Run','Çalıştır')){
    $informationOnly=$wanted -in @('More info','Daha fazla bilgi')
    if($matched.Count -eq 0 -and -not ($informationOnly -and ($securityProcess -or $window.Title -match '(?i)SmartScreen'))){continue}
    $action=@($content.actions | Where-Object {(($_.name -replace '&','') -replace '\s+',' ').Trim() -ieq $wanted} | Select-Object -First 1);if($action.Count -eq 0){continue}
    $actionKey=[string]$window.Handle+'|'+$wanted;if($lastClick.ContainsKey($actionKey) -and ((Get-Date)-$lastClick[$actionKey]).TotalSeconds -lt 1.2){break};$lastClick[$actionKey]=Get-Date
    if(-not $attempts.ContainsKey($actionKey)){$attempts[$actionKey]=0};$attempts[$actionKey]++;if($attempts[$actionKey] -gt 4){break}
    $method=Click-Action $window $action[0] $attempts[$actionKey];Event @{event=$(if($informationOnly){'information-only-more-info'}else{'normal-fixture-user-consent'});handle=$window.Handle;action=$wanted;method=$method;attempt=$attempts[$actionKey];authorization=$(if($informationOnly -and $matched.Count -eq 0){'information-only-no-execution'}else{$authorization})};break
   }
  }
 }catch{Event @{event='watcher-iteration-error';error=Redact $_.Exception.Message}}
 Start-Sleep -Milliseconds 250
}
Event @{event='watcher-finished';events=$events;dialogCrops=$captures;securitySettingsChanged=$false;motwChanged=$false}
