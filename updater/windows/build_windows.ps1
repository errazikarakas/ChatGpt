$ErrorActionPreference='Stop'
$env:GOOS='windows';$env:GOARCH='amd64';$env:CGO_ENABLED='0'
$base=$PSScriptRoot
Push-Location (Join-Path $base 'launcher')
try {
 $rc=Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Filter rc.exe -Recurse | Where-Object {$_.FullName -match '\\x64\\rc.exe$'} | Sort-Object FullName -Descending | Select-Object -First 1
 $vswhere='C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
 $install=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
 $cvtres=Get-ChildItem (Join-Path $install 'VC\Tools\MSVC') -Filter cvtres.exe -Recurse | Where-Object {$_.FullName -match '\\Hostx64\\x64\\cvtres.exe$'} | Sort-Object FullName -Descending | Select-Object -First 1
 if(-not $rc -or -not $cvtres){throw 'Microsoft native resource tools unavailable'}
 & $rc.FullName /nologo /fo resources.res resources.rc
 if($LASTEXITCODE -ne 0){throw 'Native resource compilation failed'}
 & $cvtres.FullName /NOLOGO /MACHINE:X64 /OUT:resources.syso resources.res
 if($LASTEXITCODE -ne 0){throw 'Native resource conversion failed'}
 New-Item -ItemType Directory -Force (Join-Path $base 'release') | Out-Null
 go build -trimpath -buildvcs=false -ldflags '-s -w -H=windowsgui' -o ../release/Bakim-TR-Yardim.exe .
 if($LASTEXITCODE -ne 0){throw 'Native launcher build failed'}
} finally {Pop-Location}
