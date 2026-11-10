param([Parameter(Mandatory=$true)][string]$File,[string]$CertificateThumbprint=$env:BAKIM_CODE_SIGNING_THUMBPRINT,[string]$TimestampServer='http://timestamp.digicert.com')
$ErrorActionPreference='Stop'
if(-not $CertificateThumbprint){Write-Output 'Authenticode credential is not configured; unsigned release is explicitly recorded.';return}
$cert=Get-Item ('Cert:\CurrentUser\My\'+$CertificateThumbprint)
if(-not $cert.HasPrivateKey -or $cert.NotAfter -le (Get-Date)){throw 'A usable private code-signing certificate is required'}
$codeSigning=@($cert.EnhancedKeyUsageList | Where-Object {$_.ObjectId -eq '1.3.6.1.5.5.7.3.3'})
if($codeSigning.Count -eq 0){throw 'The certificate is not authorized for code signing'}
$result=Set-AuthenticodeSignature -LiteralPath $File -Certificate $cert -HashAlgorithm SHA256 -TimestampServer $TimestampServer
if($result.Status -ne 'Valid'){throw 'Windows did not trust the resulting Authenticode signature'}
$verified=Get-AuthenticodeSignature -LiteralPath $File
if($verified.Status -ne 'Valid' -or $verified.SignerCertificate.Thumbprint -ne $cert.Thumbprint){throw 'Post-signing publisher verification failed'}
Write-Output 'SHA256 Authenticode signature and trusted publisher verified.'
