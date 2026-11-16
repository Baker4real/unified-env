param([Parameter(Mandatory)][string]$Spec)
$ErrorActionPreference='Stop'
try{
 $config=Get-Content -LiteralPath $Spec -Raw|ConvertFrom-Json -AsHashtable
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($config.script,[ref]$tokens,[ref]$errors)
 if($errors.Count -gt 0 -or $ast.DynamicParamBlock){throw 'script-parameters-not-statically-verifiable'}
 $declared=@{}
 foreach($param in $ast.ParamBlock.Parameters){$declared[$param.Name.VariablePath.UserPath]=$param}
 $provided=@{}
 foreach($key in $config.parameters.Keys){
  if($provided.ContainsKey($key)){throw 'duplicate-script-parameter'}
  if(-not $declared.ContainsKey($key)){throw 'unknown-script-parameter'}
  $provided[$key]=$config.parameters[$key]
 }
 $sets=@{'__AllParameterSets'=$true}
 foreach($param in $declared.Values){
  foreach($attribute in $param.Attributes|Where-Object{$_.TypeName.Name -in @('Parameter','ParameterAttribute')}){
   $setArgument=@($attribute.NamedArguments|Where-Object ArgumentName -eq 'ParameterSetName')
   if($setArgument.Count -gt 0){$setName=[string]$setArgument[0].Argument.SafeGetValue();$sets[$setName]=$true}
  }
 }
 if($sets.Count -gt 1){$sets.Remove('__AllParameterSets')}
 $validSets=0
 foreach($setName in $sets.Keys){
  $valid=$true
  foreach($name in $declared.Keys){
   $param=$declared[$name]
   $attributes=@($param.Attributes|Where-Object{$_.TypeName.Name -in @('Parameter','ParameterAttribute')})
   $member=$attributes.Count -eq 0
   $mandatory=$false
   foreach($attribute in $attributes){
    $setArgument=@($attribute.NamedArguments|Where-Object ArgumentName -eq 'ParameterSetName')
    $thisSet=if($setArgument.Count -eq 0){'__AllParameterSets'}else{[string]$setArgument[0].Argument.SafeGetValue()}
    if($thisSet -in @('__AllParameterSets',$setName)){
     $member=$true
     foreach($a in $attribute.NamedArguments|Where-Object ArgumentName -eq 'Mandatory'){
      if($a.ExpressionOmitted -or $a.Argument.SafeGetValue() -eq $true){$mandatory=$true}
     }
    }
   }
   if($mandatory -and -not $provided.ContainsKey($name)){$valid=$false}
   if($provided.ContainsKey($name) -and -not $member){$valid=$false}
  }
  if($valid){$validSets++}
 }
 if($validSets -eq 0){throw 'missing-mandatory-or-incompatible-parameter-set'}
 foreach($name in $provided.Keys){
  $param=$declared[$name];$value=$provided[$name]
  foreach($attribute in $param.Attributes|Where-Object{$_.TypeName.Name -in @('ValidateSet','ValidateSetAttribute')}){
   $allowed=@($attribute.PositionalArguments|ForEach-Object{$_.SafeGetValue()})
   if($allowed -notcontains $value){throw 'invalid-script-validate-set-value'}
  }
  # Match the ordinary scalar parameter types supported by the typed step spec.
  $type=$param.StaticType
  if($type -eq [string] -and $value -isnot [string]){throw 'script-parameter-type-mismatch'}
  if($type -eq [bool] -or $type -eq [Management.Automation.SwitchParameter]){if($value -isnot [bool]){throw 'script-parameter-type-mismatch'}}
  if($type -in @([int],[long],[double],[float],[decimal])){if($value -isnot [ValueType] -or $value -is [bool]){throw 'script-parameter-type-mismatch'}}
 }
 @{ok=$true;status='script-parameter-contract-validated-without-execution'}|ConvertTo-Json -Compress
}catch{
 @{ok=$false;status='script-parameter-contract-rejected'}|ConvertTo-Json -Compress
 exit 1
}
