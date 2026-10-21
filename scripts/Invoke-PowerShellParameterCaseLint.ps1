<#
.SYNOPSIS
Lint PowerShell functions for assignments that overwrite a parameter through another spelling. Reads only.

.DESCRIPTION
PowerShell variable names ignore case, so inside function F([string]$Original) the assignment $original = ...
overwrites the parameter $Original. In every function and class method the lint lists each assignment to a variable
whose name equals one of that function's parameters ignoring case but differs in case: $x = and its compound forms,
[type]$x =, each element of $a, $b =, a foreach loop variable, and ++ or --. Reading a parameter through another
spelling reads the parameter itself and is not listed. A nested function is checked against its own parameters.
Not checked: script-level param() blocks, scope-qualified variables such as $local:x, and Set-Variable; an
assignment inside a child scope such as & { } is listed like any other.

Errors: parse-error, case-variant-assignment.
Without -Path it checks every tracked *.ps1 and *.psm1 file of this repository.
Prints one JSON report and writes nothing; exit 0 when there is no finding, 1 otherwise.

.EXAMPLE
pwsh -NoProfile -File D:/agents/projects/统一环境/scripts/Invoke-PowerShellParameterCaseLint.ps1

.EXAMPLE
& D:/agents/projects/统一环境/scripts/Invoke-PowerShellParameterCaseLint.ps1 -Path .\a.ps1, .\b.ps1
Checks only the named files. Name several files in-process like this: pwsh -File passes them as one string.
#>
[CmdletBinding()]
param(
    [string[]]$Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$projectRoot = Split-Path -Parent $PSScriptRoot

function New-Finding([string]$Code, [string]$File, [int]$Line, [string]$Detail) {
    [ordered]@{ code = $Code; path = $File; line = $Line; detail = $Detail }
}

# The variables an assignment target rebinds: $x, [type]$x, and each element of $a, $b.
function Get-AssignedVariable($Node) {
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) { $Node }
    elseif ($Node -is [System.Management.Automation.Language.AttributedExpressionAst]) { Get-AssignedVariable $Node.Child }
    elseif ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) { foreach ($element in $Node.Elements) { Get-AssignedVariable $element } }
}

# The function or class method whose scope an assignment writes to; $null at script level.
function Get-EnclosingFunction($Node) {
    $current = $Node.Parent
    while ($null -ne $current -and $current -isnot [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $current -isnot [System.Management.Automation.Language.FunctionMemberAst]) { $current = $current.Parent }
    $current
}

$rebinds = {
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -or
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -or
    ($node -is [System.Management.Automation.Language.UnaryExpressionAst] -and $node.TokenKind -in 'PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus')
}

$files = @(if ($Path) {
    foreach ($file in $Path) { [pscustomobject]@{ name = $file; fullPath = (Resolve-Path -LiteralPath $file).ProviderPath } }
} else {
    $tracked = @(git -C $projectRoot -c core.quotepath=false ls-files -- '*.ps1' '*.psm1')
    if ($LASTEXITCODE -ne 0) { throw "git ls-files failed in $projectRoot" }
    # A tracked file deleted in the work tree has nothing left to check.
    foreach ($file in $tracked) {
        $fullPath = Join-Path $projectRoot $file
        if ([System.IO.File]::Exists($fullPath)) { [pscustomobject]@{ name = $file; fullPath = $fullPath } }
    }
})

$findings = [System.Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.fullPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors) {
        $findings.Add((New-Finding 'parse-error' $file.name $parseErrors[0].Extent.StartLineNumber $parseErrors[0].Message))
        continue
    }
    foreach ($statement in $ast.FindAll($rebinds, $true)) {
        $function = Get-EnclosingFunction $statement
        if ($null -eq $function) { continue }
        # foreach, not .Name on the collection: StrictMode throws on member access over an empty param() block.
        $parameters = @(
            foreach ($declared in $function.Parameters) { $declared.Name.VariablePath.UserPath }
            if ($function.Body.ParamBlock) { foreach ($declared in $function.Body.ParamBlock.Parameters) { $declared.Name.VariablePath.UserPath } }
        )
        $targets = if ($statement -is [System.Management.Automation.Language.AssignmentStatementAst]) { Get-AssignedVariable $statement.Left }
            elseif ($statement -is [System.Management.Automation.Language.ForEachStatementAst]) { $statement.Variable }
            else { Get-AssignedVariable $statement.Child }
        foreach ($target in $targets) {
            $name = $target.VariablePath.UserPath
            foreach ($parameter in $parameters) {
                if ($parameter -ieq $name -and $parameter -cne $name) {
                    $detail = '{0} assigns ${1}, which is the parameter ${2}' -f $function.Name, $name, $parameter
                    $findings.Add((New-Finding 'case-variant-assignment' $file.name $target.Extent.StartLineNumber $detail))
                }
            }
        }
    }
}

[ordered]@{
    status   = if ($findings.Count) { 'error' } else { 'ok' }
    files    = $files.Count
    errors   = $findings.Count
    findings = @($findings)
} | ConvertTo-Json -Depth 4 -Compress
exit $(if ($findings.Count) { 1 } else { 0 })
