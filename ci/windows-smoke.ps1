param([string]$Executable,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$out=(Resolve-Path $OutputDirectory).Path
$exe=(Resolve-Path $Executable).Path
$config=Get-Content '../branding/client-public.json' -Raw -Encoding UTF8 | ConvertFrom-Json
# Verify the real packed executable starts and loads its embedded server configuration.
$public=Join-Path $out 'runtime-public-config.json'
Start-Process -FilePath $exe -ArgumentList @('--bakim-public-config', ('"'+$public+'"')) -Wait
for($i=0;$i -lt 30 -and -not(Test-Path $public);$i++){Start-Sleep 1}
if(-not(Test-Path $public)){throw 'Portable public-config probe failed'}
$runtime=Get-Content $public -Raw -Encoding UTF8 | ConvertFrom-Json
foreach($key in @('appName','idServer','relayServer','publicKey')){if($runtime.$key -cne $config.$key){throw "Embedded runtime configuration mismatch: $key"}}
if(-not $runtime.installationDisabled -or $runtime.fileTransfer -ne 'N' -or $runtime.clipboard -ne 'Y'){throw 'Runtime permission policy mismatch'}
# Test the external protocol and relay from Microsoft's independent Windows runner.
python ../ci/network_probe.py --host xn--bakm-nza.tr --key $config.publicKey --output (Join-Path $out 'external-network.json')
if($LASTEXITCODE -ne 0){throw 'External server protocol probe failed'}
$app=Start-Process -FilePath $exe -PassThru
Start-Sleep 25
$windows=Get-Process | Where-Object {$_.MainWindowTitle -like '*Yard*m*' -or $_.MainWindowTitle -like '*Bak*m.TR*'}
if(-not $windows){throw 'Branded GUI window did not start'}
$windows | Select-Object ProcessName,MainWindowTitle | ConvertTo-Json | Set-Content (Join-Path $out 'window.json') -Encoding UTF8
# Capture only window headers: the temporary password area is deliberately excluded.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bounds=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap=New-Object System.Drawing.Bitmap($bounds.Width,[Math]::Min(180,$bounds.Height))
$graphics=[System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen(0,0,0,0,$bitmap.Size)
$bitmap.Save((Join-Path $out 'window-header.png'),[System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose();$bitmap.Dispose()
$after=Join-Path $out 'runtime-after-registration.json'
Start-Process -FilePath $exe -ArgumentList @('--bakim-public-config', ('"'+$after+'"')) -Wait
for($i=0;$i -lt 15 -and -not(Test-Path $after);$i++){Start-Sleep 1}
if(Test-Path $after){$r=Get-Content $after -Raw -Encoding UTF8 | ConvertFrom-Json;$r | ConvertTo-Json | Set-Content (Join-Path $out 'registration.json') -Encoding UTF8}
$windows | Stop-Process -Force -ErrorAction SilentlyContinue
@{ok=$true;artifact='Bakim-TR-Yardim.exe';guiWindowStarted=$true;embeddedConfigVerified=$true;externalProtocolVerified=$true;unsigned=$true;registrationConfirmed=([bool]$r.keyConfirmed)} | ConvertTo-Json | Set-Content (Join-Path $out 'smoke-result.json') -Encoding UTF8
