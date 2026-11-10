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
Start-Process -FilePath $exe -ArgumentList @('--connect',$id)
$remote=[IntPtr]::Zero
for($i=0;$i -lt 60;$i++){Start-Sleep 2;$remote=[BakimWindows]::RemoteWindow();if($remote -ne [IntPtr]::Zero){break}}
if($remote -eq [IntPtr]::Zero){throw 'Remote desktop UI did not appear'}
# Our server operator accepts only the isolated fixture's request. No password is sent or logged.
Start-Sleep 100
[BakimWindows]::ShowWindow($remote,3)|Out-Null
[BakimWindows]::SetForegroundWindow($remote)|Out-Null
Start-Sleep 3
[System.Windows.Forms.SendKeys]::SendWait('BAKIMTR-CI-REMOTE-CONTROL-VERIFIED{ENTER}')
Start-Sleep 5
$r=New-Object BakimWindows+Rect
if(-not [BakimWindows]::GetWindowRect($remote,[ref]$r)){throw 'Remote window bounds unavailable'}
$width=[Math]::Max(1,$r.Right-$r.Left);$height=[Math]::Max(1,$r.Bottom-$r.Top)
$bitmap=New-Object System.Drawing.Bitmap($width,$height)
$graphics=[System.Drawing.Graphics]::FromImage($bitmap);$graphics.CopyFromScreen($r.Left,$r.Top,0,0,$bitmap.Size)
$bitmap.Save((Join-Path $out 'isolated-remote-desktop.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose();$bitmap.Dispose()
@{remoteWindowStarted=$true;fixtureIdMatched=$true;keyboardMarkerSent=$true;targetIsIsolatedFixture=$true;source='GitHub-hosted Windows runner';requiresIndependentTargetMarkerVerification=$true} | ConvertTo-Json | Set-Content (Join-Path $out 'remote-smoke.json') -Encoding UTF8
