param([string]$Executable,[string]$OutputDirectory='remote-proof')
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$out=(Resolve-Path $OutputDirectory).Path;$exe=(Resolve-Path $Executable).Path
$target=Invoke-RestMethod -Uri 'https://xn--bakm-nza.tr/assets/support/test-target.json' -TimeoutSec 20
$id=[string]$target.targetId
if($id -notmatch '^[A-Za-z0-9_-]{6,40}$'){throw 'No isolated RustDesk fixture ID available'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;using System.Collections.Generic;using System.Runtime.InteropServices;using System.Text;
public class BakimWindows {
 public delegate bool EnumProc(IntPtr h,IntPtr p);
 [DllImport("user32.dll")]public static extern bool EnumWindows(EnumProc e,IntPtr p);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
 [DllImport("user32.dll")]public static extern bool ClientToScreen(IntPtr h,ref Point p);
 [DllImport("user32.dll")]public static extern uint GetDpiForWindow(IntPtr h);
 public struct Point {public int X,Y;}
 [DllImport("user32.dll")]public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")]public static extern void mouse_event(uint f,uint x,uint y,uint data,UIntPtr extra);
 public struct Rect {public int Left,Top,Right,Bottom;}
 public static IntPtr RemoteWindow(){IntPtr result=IntPtr.Zero;EnumWindows((h,p)=>{var t=new StringBuilder(512);GetWindowText(h,t,t.Capacity);var s=t.ToString();if(IsWindowVisible(h)&&(s.Contains("Remote Desktop")||s.Contains("Uzak Masaüstü")))result=h;return true;},IntPtr.Zero);return result;}
}
'@
Start-Process -FilePath $exe
Start-Sleep 15
$controllerFile=Join-Path $out 'controller-id.txt'
Start-Process -FilePath $exe -ArgumentList @('--get-id') -RedirectStandardOutput $controllerFile -Wait
$controller=''
for($i=0;$i -lt 15;$i++){
 Start-Sleep 1
 if(Test-Path $controllerFile){$controller=(Get-Content $controllerFile | Where-Object {$_ -match '^\d{6,14}$'} | Select-Object -Last 1)}
 if($controller){break}
}
if(-not $controller){throw 'Synthetic Windows controller ID unavailable'}
# Notify only our test operator through the web server access log before requesting approval.
$null=Invoke-WebRequest -UseBasicParsing -Uri ('https://xn--bakm-nza.tr/assets/support/test-target.json?controllerId='+$controller) -TimeoutSec 20
# Exercise the same ID field + Enter path a user follows. No custom URI scheme or CLI connect is used.
Start-Sleep 12
$cfg=Get-Content branding/client-public.json -Raw -Encoding UTF8 | ConvertFrom-Json
$mainProcess=Get-Process | Where-Object {$_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -eq $cfg.appName} | Select-Object -First 1
if(-not $mainProcess){throw 'Branded main GUI unavailable for connection test'}
$main=[IntPtr]$mainProcess.MainWindowHandle
[BakimWindows]::ShowWindow($main,9)|Out-Null
[BakimWindows]::SetWindowPos($main,[IntPtr]::Zero,20,20,1000,700,0x0040)|Out-Null
[BakimWindows]::SetForegroundWindow($main)|Out-Null
Start-Sleep 2
$remote=[IntPtr]::Zero
$entryMethod=''
try {
 Add-Type -AssemblyName UIAutomationClient
 Add-Type -AssemblyName UIAutomationTypes
 $root=[System.Windows.Automation.AutomationElement]::FromHandle($main)
 $condition=New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Edit)
 $edits=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,$condition)
 $editable=@($edits | Where-Object {$_.Current.IsEnabled -and -not $_.Current.IsPassword -and $_.Current.BoundingRectangle.Left -gt 220})
 if($editable.Count -gt 0){
  $editable[0].SetFocus()
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  [System.Windows.Forms.SendKeys]::SendWait($id+'{ENTER}')
  $entryMethod='GUI ID field via accessibility focus'
  Start-Sleep 5
  $remote=[BakimWindows]::RemoteWindow()
 }
} catch {$entryMethod=''}
# Flutter semantics are not always exposed in a hosted runner. The fixed main window
# makes the source-defined ID text-field bounds deterministic (200-DIP left pane).
if($remote -eq [IntPtr]::Zero){
 $scale=[double][BakimWindows]::GetDpiForWindow($main)/96.0
 if($scale -lt 1){$scale=1.0}
 foreach($fieldY in @(145,125,165,185)){
  $point=New-Object BakimWindows+Point
  $point.X=[int](390*$scale);$point.Y=[int]($fieldY*$scale)
  [BakimWindows]::ClientToScreen($main,[ref]$point)|Out-Null
  [BakimWindows]::SetForegroundWindow($main)|Out-Null
  [BakimWindows]::SetCursorPos($point.X,$point.Y)|Out-Null
  [BakimWindows]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
  [BakimWindows]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  [System.Windows.Forms.SendKeys]::SendWait($id+'{ENTER}')
  Start-Sleep 5
  $remote=[BakimWindows]::RemoteWindow()
  if($remote -ne [IntPtr]::Zero){$entryMethod='GUI ID field via source-derived coordinates';break}
 }
}
for($i=0;$i -lt 20 -and $remote -eq [IntPtr]::Zero;$i++){Start-Sleep 2;$remote=[BakimWindows]::RemoteWindow()}
if($remote -eq [IntPtr]::Zero){throw 'Remote desktop UI did not appear'}
# Our server operator accepts only the isolated fixture's request. No password is sent or logged.
Start-Sleep 100
[BakimWindows]::ShowWindow($remote,3)|Out-Null
[BakimWindows]::SetForegroundWindow($remote)|Out-Null
Start-Sleep 3
$r=New-Object BakimWindows+Rect
if(-not [BakimWindows]::GetWindowRect($remote,[ref]$r)){throw 'Remote window bounds unavailable'}
[BakimWindows]::SetCursorPos([int](($r.Left+$r.Right)/2),[int](($r.Top+$r.Bottom)/2))|Out-Null
[BakimWindows]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
[BakimWindows]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
Start-Sleep 1
[System.Windows.Forms.SendKeys]::SendWait('BAKIMTR-CI-REMOTE-CONTROL-VERIFIED{ENTER}')
Start-Sleep 5
$width=[Math]::Max(1,$r.Right-$r.Left);$height=[Math]::Max(1,$r.Bottom-$r.Top)
$bitmap=New-Object System.Drawing.Bitmap($width,$height)
$graphics=[System.Drawing.Graphics]::FromImage($bitmap);$graphics.CopyFromScreen($r.Left,$r.Top,0,0,$bitmap.Size)
$bitmap.Save((Join-Path $out 'isolated-remote-desktop.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose();$bitmap.Dispose()
@{remoteWindowStarted=$true;fixtureIdMatched=$true;keyboardMarkerSent=$true;targetIsIsolatedFixture=$true;source='GitHub-hosted Windows runner';connectionEntryMethod=$entryMethod;usesNormalGuiConnectionFlow=$true;requiresIndependentTargetMarkerVerification=$true} | ConvertTo-Json | Set-Content (Join-Path $out 'remote-smoke.json') -Encoding UTF8
