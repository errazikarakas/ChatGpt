# CI ONLY: disposable publisher laboratory. Never included in a release package.
# Detached catalogs preserve executable bytes and Zone.Identifier. No policy changes.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateSet('Initialize','Add','Cleanup')][string]$Action,
  [string]$File,
  [string]$ProofDirectory = (Join-Path $PSScriptRoot 'proof')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:BAKIM_NATIVE_TESTS -ne '1') { throw 'Disposable GitHub Windows native-test runner required.' }
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP) -or $env:GITHUB_RUN_ID -notmatch '^\d+$') { throw 'RUNNER_TEMP and numeric GITHUB_RUN_ID required.' }
$labRoot = Join-Path $env:RUNNER_TEMP ('bakim-publisher-lab-' + $env:GITHUB_RUN_ID)
$stateFile = Join-Path $labRoot 'state.json'
$null = New-Item -ItemType Directory -Force -Path $ProofDirectory
$proofFile = Join-Path $ProofDirectory 'ci-trusted-publisher.jsonl'
$mutex = New-Object Threading.Mutex($false, ('Local\BakimPublisherLab.' + $env:GITHUB_RUN_ID))
$locked = $false

function Write-Proof($Data) {
  $Data.utc = [DateTime]::UtcNow.ToString('o')
  $Data.labOnly = $true
  $Data.runId = $env:GITHUB_RUN_ID
  $Data.policyChanged = $false
  $Data.productionSigning = $false
  Add-Content -LiteralPath $proofFile -Value ($Data | ConvertTo-Json -Compress -Depth 6) -Encoding UTF8
}
function Save-State($State) {
  $tempState = $stateFile + '.new'
  [IO.File]::WriteAllText($tempState, ($State | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tempState -Destination $stateFile -Force
}
function Invoke-SignTool([string[]]$Arguments) {
  $lines = & $script:state.signTool @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) { throw ('SignTool failed (' + ($Arguments -join ' ') + '): ' + ($lines -join ' ')) }
}
function Get-OwnedCertificate {
  $certificate = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $script:state.thumbprint)
  if ($certificate.Subject -ne $script:state.subject -or -not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date)) { throw 'Disposable signing certificate ownership/validity mismatch.' }
  return $certificate
}
function Get-MotwDigest([string]$Path) {
  $stream = Get-Item -LiteralPath $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue
  if ($null -eq $stream) { return 'absent' }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($Path + ':Zone.Identifier')))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Assert-Signature([string]$Path) {
  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $script:state.thumbprint) {
    throw ('Catalog trust preflight failed: status=' + $signature.Status + ', file=' + [IO.Path]::GetFileName($Path))
  }
  return $signature
}
try {
  try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
  if (-not $locked) { throw 'Disposable publisher laboratory lock timeout.' }
  if ($Action -eq 'Initialize') {
    if (Test-Path -LiteralPath $stateFile) { throw 'Laboratory already initialized; cleanup before reinitializing.' }
    $null = New-Item -ItemType Directory -Force -Path $labRoot
    $toolsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $signTool = Get-ChildItem -Path (Join-Path $toolsRoot '*\x64\signtool.exe') -File | Sort-Object FullName -Descending | Select-Object -First 1
    if ($null -eq $signTool) { throw 'Windows SDK x64 signtool.exe unavailable.' }
    $nonce = [Guid]::NewGuid().ToString('N')
    $subject = 'CN=Bakim CI disposable ' + $env:GITHUB_RUN_ID + ' ' + $nonce
    $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddHours(4)
    $script:state = [PSCustomObject]@{ version=1; runId=$env:GITHUB_RUN_ID; nonce=$nonce; subject=$subject; thumbprint=$certificate.Thumbprint; signTool=$signTool.FullName; catalogs=@() }
    # Record the owned key before adding public trust, so cleanup is possible after a partial failure.
    Save-State $script:state
    $publicCertificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2(,$certificate.RawData)
    foreach ($storeName in @('Root','TrustedPublisher')) {
      $store = New-Object Security.Cryptography.X509Certificates.X509Store($storeName, 'CurrentUser')
      try { $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite); $store.Add($publicCertificate) } finally { $store.Close() }
    }
    Write-Proof @{ action='Initialize'; thumbprint=$certificate.Thumbprint; keyExported=$false; certificateHours=4 }
    Write-Output 'Disposable publisher laboratory initialized; no executable bytes or Windows policy changed.'
  } else {
    if (-not (Test-Path -LiteralPath $stateFile)) {
      if ($Action -eq 'Cleanup') { Write-Output 'Disposable publisher laboratory already absent.'; return }
      throw 'Initialize disposable publisher laboratory first.'
    }
    $script:state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($script:state.version -ne 1 -or $script:state.runId -ne $env:GITHUB_RUN_ID -or $script:state.nonce -notmatch '^[a-f0-9]{32}$' -or $script:state.thumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or $script:state.subject -ne ('CN=Bakim CI disposable ' + $env:GITHUB_RUN_ID + ' ' + $script:state.nonce)) { throw 'Laboratory state ownership mismatch.' }
    if ($Action -eq 'Add') {
      if ([string]::IsNullOrWhiteSpace($File)) { throw '-File is required for Add.' }
      $item = Get-Item -LiteralPath $File
      if ($item.PSIsContainer -or $item.Extension -ne '.exe' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'An ordinary executable file is required.' }
      $path = $item.FullName
      # Never sign a general installed executable. Only this workspace, native test roots or the test cache.
      $allowedRoots = @($PSScriptRoot, (Join-Path $env:LOCALAPPDATA 'BakimTRYardim\Launcher'))
      $allowed = $false
      foreach ($root in $allowedRoots) { if ($path.StartsWith(([IO.Path]::GetFullPath($root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { $allowed=$true } }
      $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
      if ($path.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and $path.Substring($tempRoot.Length) -match '^TestWindows[^\\]+\\') { $allowed=$true }
      if (-not $allowed) { throw ('File outside disposable test scope: ' + [IO.Path]::GetFileName($path)) }
      $certificate = Get-OwnedCertificate
      $before = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
      $motwBefore = Get-MotwDigest $path
      $existing = @($script:state.catalogs | Where-Object { $_.fileSha256 -eq $before })
      if ($existing.Count -eq 0) {
        $name = 'bakim-ci-' + $script:state.nonce + '-' + [Guid]::NewGuid().ToString('N') + '.cat'
        $catalogPath = Join-Path $labRoot $name
        $record = [PSCustomObject]@{ name=$name; path=$catalogPath; fileSha256=$before; registered=$false }
        $script:state.catalogs = @($script:state.catalogs) + $record
        Save-State $script:state
        $null = New-FileCatalog -Path $path -CatalogFilePath $catalogPath -CatalogVersion 2
        Invoke-SignTool -Arguments @('sign','/fd','SHA256','/sha1',$script:state.thumbprint,'/s','My',$catalogPath)
        Invoke-SignTool -Arguments @('verify','/pa',$catalogPath)
        # The nonce+GUID catalog name is already unique. Do not rename it: cleanup removes exactly this owned entry.
        Invoke-SignTool -Arguments @('catdb','/d',$catalogPath)
        $record.registered = $true
        Save-State $script:state
      }
      $signature = Assert-Signature $path
      Invoke-SignTool -Arguments @('verify','/a','/pa',$path)
      $after = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
      $motwAfter = Get-MotwDigest $path
      if ($before -ne $after -or $motwBefore -ne $motwAfter) { throw 'Executable bytes or Mark-of-the-Web changed during catalog registration.' }
      Write-Proof @{ action='Add'; fileName=$item.Name; sha256=$after; bytes=[long]$item.Length; thumbprint=$script:state.thumbprint; status=[string]$signature.Status; executableUnchanged=$true; motwUnchanged=$true; motwPresent=($motwAfter -ne 'absent'); reused=($existing.Count -gt 0) }
      Write-Output ('Catalog preflight valid; executable SHA256 and MOTW preserved: ' + $item.Name)
    } else {
      $cleanupErrors = @()
      foreach ($entry in @($script:state.catalogs)) {
        if ($entry.name -notmatch ('^bakim-ci-' + $script:state.nonce + '-[a-f0-9]{32}\.cat$') -or [IO.Path]::GetFullPath($entry.path) -ne (Join-Path $labRoot $entry.name)) { throw 'Refusing non-owned catalog cleanup.' }
        if ($entry.registered) { try { Invoke-SignTool -Arguments @('catdb','/d','/r',$entry.name) } catch { $cleanupErrors += $_.Exception.Message } }
      }
      foreach ($storeName in @('Root','TrustedPublisher','My')) {
        $certificatePath = 'Cert:\CurrentUser\' + $storeName + '\' + $script:state.thumbprint
        $owned = Get-Item -LiteralPath $certificatePath -ErrorAction SilentlyContinue
        if ($null -ne $owned) {
          if ($owned.Subject -ne $script:state.subject) { throw 'Refusing non-owned certificate cleanup.' }
          try { if ($storeName -eq 'My') { Remove-Item -LiteralPath $certificatePath -DeleteKey } else { Remove-Item -LiteralPath $certificatePath } } catch { $cleanupErrors += $_.Exception.Message }
        }
      }
      Write-Proof @{ action='Cleanup'; thumbprint=$script:state.thumbprint; catalogs=@($script:state.catalogs).Count; errors=@($cleanupErrors) }
      if ($cleanupErrors.Count -gt 0) { throw ('Laboratory cleanup incomplete: ' + ($cleanupErrors -join '; ')) }
      Remove-Item -LiteralPath $labRoot -Recurse -Force
      Write-Output 'Only the owned disposable catalogs, trust entries and nonexportable private key were removed.'
    }
  }
} catch {
  Write-Proof @{ action=$Action; result='failed'; message=$_.Exception.Message }
  throw
} finally {
  if ($locked) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
