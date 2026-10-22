<#
.SYNOPSIS
Lint PowerShell for $(...) values that lose the array they output. Reads only.

.DESCRIPTION
$(...) collects the output of its statements: an array with one element comes back as that element and an empty
array comes back as $null, so $x = $(if ($a) { $list } else { @('gh') }) leaves $x[0] as 'g'. The lint lists each
assignment $x = $(...) and each hashtable value @{ k = $(...) } whose $(...) outputs an array expression @(...)
or an array literal a, b, either directly or from a branch of if, switch or try/catch/finally or from a loop body
inside it. Write such a value as @(...). Not listed: a target cast to an array type such as [string[]]$x, which
wraps the value again; compound assignments such as +=; ,@(...), which keeps the array; and the bare form
$x = if (...) { @(...) }, whose branches may output scalars on purpose.

Errors: parse-error, subexpression-array-unwrap.
Without -Path it checks every tracked *.ps1 and *.psm1 file of this repository.
Prints one JSON report and writes nothing; exit 0 when there is no finding, 1 otherwise.

.EXAMPLE
pwsh -NoProfile -File D:/agents/projects/统一环境/scripts/Invoke-PowerShellArrayUnwrapLint.ps1

.EXAMPLE
& D:/agents/projects/统一环境/scripts/Invoke-PowerShellArrayUnwrapLint.ps1 -Path .\a.ps1, .\b.ps1
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

# The statement blocks whose output is the output of the statement holding them.
function Get-OutputBlock($Statement) {
    if ($Statement -is [System.Management.Automation.Language.IfStatementAst]) {
        foreach ($clause in $Statement.Clauses) { $clause.Item2 }
        $Statement.ElseClause
    } elseif ($Statement -is [System.Management.Automation.Language.SwitchStatementAst]) {
        foreach ($clause in $Statement.Clauses) { $clause.Item2 }
        $Statement.Default
    } elseif ($Statement -is [System.Management.Automation.Language.TryStatementAst]) {
        $Statement.Body
        foreach ($catch in $Statement.CatchClauses) { $catch.Body }
        $Statement.Finally
    } elseif ($Statement -is [System.Management.Automation.Language.LoopStatementAst]) {
        $Statement.Body
    }
}

function Test-OutputsArray($Statements) {
    foreach ($statement in $Statements) {
        if ($statement -is [System.Management.Automation.Language.PipelineAst]) {
            $elements = $statement.PipelineElements
            if ($elements.Count -ne 1 -or $elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
            $expression = $elements[0].Expression
            # ,@(...) parses as a one-element array literal; it is the form that keeps the array.
            if ($expression -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                ($expression -is [System.Management.Automation.Language.ArrayLiteralAst] -and $expression.Elements.Count -gt 1)) { return $true }
            continue
        }
        foreach ($block in @(Get-OutputBlock $statement)) {
            if ($null -ne $block -and (Test-OutputsArray $block.Statements)) { return $true }
        }
    }
    $false
}

# The $(...) that makes up the whole value, if it does.
function Get-WholeSubExpression($Value) {
    if ($Value -is [System.Management.Automation.Language.PipelineAst] -and $Value.PipelineElements.Count -eq 1) { $Value = $Value.PipelineElements[0] }
    if ($Value -is [System.Management.Automation.Language.CommandExpressionAst] -and
        $Value.Expression -is [System.Management.Automation.Language.SubExpressionAst]) { $Value.Expression }
}

function Test-UnwrapsArray($Value) {
    $subExpression = Get-WholeSubExpression $Value
    $null -ne $subExpression -and (Test-OutputsArray $subExpression.SubExpression.Statements)
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
    $values = [System.Collections.Generic.List[object]]::new()
    foreach ($assignment in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Operator -eq 'Equals' }, $true)) {
        $target = $assignment.Left
        # [string[]]$x = $(...) and [array]$x = $(...) wrap the value again.
        if ($target -is [System.Management.Automation.Language.ConvertExpressionAst] -and
            ($target.Type.TypeName.IsArray -or $target.Type.TypeName.Name -in 'array', 'System.Array')) { continue }
        if (Test-UnwrapsArray $assignment.Right) { $values.Add([pscustomobject]@{ target = $target.Extent.Text; line = $assignment.Extent.StartLineNumber }) }
    }
    foreach ($hashtable in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
        foreach ($pair in $hashtable.KeyValuePairs) {
            if (Test-UnwrapsArray $pair.Item2) { $values.Add([pscustomobject]@{ target = $pair.Item1.Extent.Text; line = $pair.Item2.Extent.StartLineNumber }) }
        }
    }
    foreach ($value in $values | Sort-Object line) {
        $detail = '{0} = $(...) unwraps the array it outputs; use @(...)' -f $value.target
        $findings.Add((New-Finding 'subexpression-array-unwrap' $file.name $value.line $detail))
    }
}

[ordered]@{
    status   = if ($findings.Count) { 'error' } else { 'ok' }
    files    = $files.Count
    errors   = $findings.Count
    findings = @($findings)
} | ConvertTo-Json -Depth 4 -Compress
exit $(if ($findings.Count) { 1 } else { 0 })
