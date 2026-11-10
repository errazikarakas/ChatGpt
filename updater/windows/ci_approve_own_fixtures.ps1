# TEST-ONLY: a disposable GitHub Windows VM consents to our known fixture dialogs.
# This file is never embedded in or distributed with the application.
param([int]$MaximumSeconds=600)
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$until=(Get-Date).AddSeconds($MaximumSeconds)
while((Get-Date) -lt $until){
 $windows=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
 foreach($window in $windows){
  $title=$window.Current.Name
  if($title -notmatch 'Security Warning|SmartScreen|Windows protected|Windows Defender|Güvenlik Uyarısı'){continue}
  $items=$window.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
  $text=($items | ForEach-Object {$_.Current.Name}) -join ' '
  $known=($text -match 'engine.exe' -and $text -match 'TestWindowsRealSignedUpdate|TestWindowsExactProduction|BakimTRYardim') -or $text -match 'Bakim-TR-Yardim.exe'
  if(-not $known){continue}
  foreach($name in @('More info','Daha fazla bilgi','Run','Run anyway','Çalıştır','Yine de çalıştır')){
   $button=$items | Where-Object {$_.Current.Name -eq $name -and $_.Current.IsEnabled} | Select-Object -First 1
   if($button){try {$pattern=$button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern);$pattern.Invoke()}catch{}}
  }
 }
 Start-Sleep -Milliseconds 400
}
