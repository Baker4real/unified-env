#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SpecJson)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$spec=$SpecJson | ConvertFrom-Json
$result=[ordered]@{tasks=@{};products=@{};processes=@{}}
foreach($name in $spec.tasks){
 try {
  # Enumerating once through the Task Scheduler API distinguishes not-found from query errors.
  $tasks=@(Get-ScheduledTask -ErrorAction Stop | Where-Object {$_.TaskName -ieq $name})
  $result.tasks[$name]=if($tasks.Count -gt 0){'present'}else{'absent'}
 }catch{$result.tasks[$name]='unknown'}
}
if(@($spec.products).Count -gt 0){
 try {
  Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class RetirementMsi { [DllImport("msi.dll",CharSet=CharSet.Unicode)] public static extern int MsiQueryProductState(string product); }' -ErrorAction Stop
  foreach($product in $spec.products){
   $state=[RetirementMsi]::MsiQueryProductState($product)
   # INSTALLSTATE_UNKNOWN (-1) is the documented product-not-registered result;
   # INVALIDARG/ACCESSDENIED and every other unknown failure stay unknown.
   $result.products[$product]=if($state -eq -1){'absent'}elseif($state -in @(1,2,3,4,5)){'present'}else{'unknown'}
  }
 }catch{foreach($product in $spec.products){$result.products[$product]='unknown'}}
}
try {
 $processes=@(Get-Process -ErrorAction Stop)
 foreach($name in $spec.process_names){$result.processes[$name]=if(@($processes | Where-Object {$_.ProcessName -ieq $name}).Count -gt 0){'present'}else{'absent'}}
}catch{foreach($name in $spec.process_names){$result.processes[$name]='unknown'}}
[pscustomobject]$result | ConvertTo-Json -Depth 6 -Compress
