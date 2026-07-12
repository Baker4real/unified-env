Set-StrictMode -Version Latest

function Get-CodexConfigNewline { param([string]$Text) if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" } }

function Get-CodexTomlLines {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -match '(?m)^\s*[A-Za-z0-9_.-]+\s*=\s*(?:''{3}|"{3})') { throw '拒绝处理 TOML multiline string。' }
    $lines = [Collections.ArrayList]::new(); [void]$lines.AddRange([string[]][regex]::Split($Text, '\r?\n')); return ,$lines
}

function Get-CodexTomlSectionRange {
    param([Collections.ArrayList]$Lines, [string]$Section)
    $found = @()
    for ($i=0; $i -lt $Lines.Count; $i++) { if ([string]$Lines[$i] -match "^\s*\[$([regex]::Escape($Section))\]\s*(?:#.*)?$") { $found += $i } }
    if ($found.Count -gt 1) { throw "Duplicate TOML section [$Section]." }
    if ($found.Count -eq 0) { return @{ found=$false; start=-1; end=$Lines.Count } }
    $end=$Lines.Count
    for ($i=$found[0]+1; $i -lt $Lines.Count; $i++) { if ([string]$Lines[$i] -match '^\s*\[\[?.+\]\]?\s*(?:#.*)?$') { $end=$i; break } }
    return @{ found=$true; start=$found[0]; end=$end }
}

function Get-CodexTomlCurrentValueEnd {
    param([Collections.ArrayList]$Lines,[int]$Start)
    $squareDepth=0;$braceDepth=0;$startedContainer=$false
    for($i=$Start;$i -lt $Lines.Count;$i++) { $line=[string]$Lines[$i];$quote=[char]0;$escaped=$false;$offset=0
        if($i -eq $Start){$offset=$line.IndexOf('=');if($offset -lt 0){throw 'TOML assignment 缺少等号。'};$offset++}
        for($j=$offset;$j -lt $line.Length;$j++){ $c=$line[$j]
            if($quote -ne [char]0){ if($quote -eq '"' -and $escaped){$escaped=$false;continue}; if($quote -eq '"' -and $c -eq '\'){$escaped=$true;continue}; if($c -eq $quote){$quote=[char]0}; continue }
            if($c -eq '#'){break}
            if($c -eq '"' -or $c -eq "'"){ if($j+2 -lt $line.Length -and $line.Substring($j,3) -in @('"""',"'''")){throw '拒绝处理 TOML multiline string。'}; $quote=$c;continue }
            if($c -eq '['){$squareDepth++;$startedContainer=$true;continue}
            if($c -eq ']'){$squareDepth--;if($squareDepth -lt 0){throw 'TOML array 括号不平衡。'}}
            if($c -eq '{'){$braceDepth++;$startedContainer=$true;continue}
            if($c -eq '}'){$braceDepth--;if($braceDepth -lt 0){throw 'TOML inline table 括号不平衡。'}}
            if($startedContainer -and $squareDepth -eq 0 -and $braceDepth -eq 0){return $i}
        }
        if($quote -ne [char]0){throw '拒绝处理跨行或未终止 TOML string。'}
        if(-not $startedContainer){return $Start}
    }
    if($squareDepth -ne 0 -or $braceDepth -ne 0){throw 'TOML container 未闭合。'}
    return $Start
}

function Set-CodexTomlSectionValue {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,[Parameter(Mandatory)][string]$Section,[Parameter(Mandatory)][string]$Key,[Parameter(Mandatory)][string]$Value,[ValidateSet('scalar','array')][string]$ValueKind='scalar')
    $nl=Get-CodexConfigNewline $Text; $hadFinal=$Text.EndsWith("`n"); $lines=Get-CodexTomlLines $Text
    if($hadFinal -and $lines.Count -gt 0){$lines.RemoveAt($lines.Count-1)}
    $range=Get-CodexTomlSectionRange $lines $Section; $desired="$Key = $Value"
    if(-not $range.found){ while($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace([string]$lines[$lines.Count-1])){$lines.RemoveAt($lines.Count-1)}; if($lines.Count){[void]$lines.Add('')}; [void]$lines.Add("[$Section]");[void]$lines.Add($desired) }
    else { $indexes=@();for($i=$range.start+1;$i -lt $range.end;$i++){if([string]$lines[$i] -match "^\s*$([regex]::Escape($Key))\s*="){$indexes+=$i}}
        if($indexes.Count -gt 1){throw "Duplicate TOML key $Section.$Key."}
        if($indexes.Count -eq 0){$insert=$range.end;while($insert -gt $range.start+1 -and [string]::IsNullOrWhiteSpace([string]$lines[$insert-1])){$insert--};$lines.Insert($insert,$desired)}
        else{$start=$indexes[0];$end=Get-CodexTomlCurrentValueEnd $lines $start;for($i=$end;$i -gt $start;$i--){$lines.RemoveAt($i)};$lines[$start]=$desired}
    }
    $result=([string[]]$lines -join $nl);if($hadFinal){$result+=$nl};return $result
}

function Update-CodexTomlPolicyText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,[Parameter(Mandatory)][Collections.IDictionary]$Sections,[string[]]$RemoveKeys=@())
    $nl=Get-CodexConfigNewline $Text; $result=$Text
    if($RemoveKeys.Count){$kept=[Collections.Generic.List[string]]::new();foreach($line in [regex]::Split($result,'\r?\n')){$remove=$false;foreach($key in $RemoveKeys){if($line -match "^\s*$([regex]::Escape($key))\s*="){$remove=$true;break}};if(-not $remove){$kept.Add($line)}};$result=$kept -join $nl}
    foreach($section in $Sections.Keys){foreach($key in $Sections[$section].Keys){$entry=$Sections[$section][$key];$value=if($entry -is [Collections.IDictionary]){[string]$entry.value}else{[string]$entry};$kind=if($entry -is [Collections.IDictionary] -and $entry.kind){[string]$entry.kind}else{'scalar'};$result=Set-CodexTomlSectionValue -Text $result -Section $section -Key $key -Value $value -ValueKind $kind}}
    return $result
}

function Update-SerenaYamlPolicyText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text,[Parameter(Mandatory)][Collections.IDictionary]$Values)
    $nl=Get-CodexConfigNewline $Text;$hadFinal=$Text.EndsWith("`n");$lines=[Collections.ArrayList]::new();[void]$lines.AddRange([string[]][regex]::Split($Text,'\r?\n'));if($hadFinal){$lines.RemoveAt($lines.Count-1)}
    foreach($key in $Values.Keys){$indexes=@();for($i=0;$i -lt $lines.Count;$i++){if([string]$lines[$i] -match "^$([regex]::Escape([string]$key))\s*:"){$indexes+=$i}};if($indexes.Count -gt 1){throw "Duplicate YAML top-level key $key."};$desired="${key}: $($Values[$key])";if($indexes.Count){$old=[string]$lines[$indexes[0]];$quote=[char]0;$escaped=$false;$comment=$null;for($j=0;$j -lt $old.Length;$j++){$c=$old[$j];if($quote -ne [char]0){if($quote -eq '"' -and $escaped){$escaped=$false;continue};if($quote -eq '"' -and $c -eq '\'){$escaped=$true;continue};if($c -eq $quote){$quote=[char]0};continue};if($c -eq '"' -or $c -eq "'"){$quote=$c;continue};if($c -eq '#' -and $j -gt 0 -and [char]::IsWhiteSpace($old[$j-1])){$comment=$old.Substring($j).TrimEnd();break}};if($comment){$desired="$desired $comment"};$lines[$indexes[0]]=$desired}else{[void]$lines.Add($desired)}}
    $result=([string[]]$lines -join $nl);if($hadFinal){$result+=$nl};return $result
}
