$ErrorActionPreference='Stop'
$env:GOOS='windows';$env:GOARCH='amd64';$env:CGO_ENABLED='0'
$base=$PSScriptRoot
Push-Location (Join-Path $base 'launcher')
try {
 Remove-Item resources.syso -ErrorAction SilentlyContinue
 go run github.com/tc-hib/go-winres@v0.3.3 make --in winres.json --arch amd64 --out resources
 if($LASTEXITCODE -ne 0){throw 'Go resource generation failed'}
 New-Item -ItemType Directory -Force (Join-Path $base 'release') | Out-Null
 go build -trimpath -buildvcs=false -ldflags '-s -w -H=windowsgui' -o ../release/Bakim-TR-Yardim.exe .
 if($LASTEXITCODE -ne 0){throw 'Native launcher build failed'}
} finally {Pop-Location}
