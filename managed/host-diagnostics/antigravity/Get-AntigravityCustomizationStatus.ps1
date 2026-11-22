#Requires -Version 7.5
[CmdletBinding()]
param()

function Get-AntigravityInstalledReadback {
    param([object[]]$Nodes, [string]$ConfigDirectory, [string[]]$ExpectedSkills)

    $report = [ordered]@{status='not-verified'; reason=$null; rule=$null; skills=$null; mcp=$null}
    $search = @($Nodes | Where-Object { $_.role -eq 'Edit' -and $_.name -match '^(搜索插件|搜索自定义项|Search plugins|Search customizations)(?:\.{3}|…)$' })
    $skillsHeader = @($Nodes | Where-Object { $_.role -eq 'Button' -and $_.name -match '^(技能与规则|Skills and Rules) \d+$' })
    $typeFilters = @($Nodes | Where-Object { $_.role -eq 'Button' -and $_.name -match '^(Filter skills and rules|筛选技能与规则)[:：]' })
    if ($search.Count -ne 1 -or $null -eq $search[0].value -or $skillsHeader.Count -ne 1) { $report.reason = 'installed-view-unavailable' }
    elseif ($search[0].value.Trim() -or ($search[0].value -eq '' -and $Nodes.name -match '^(Clear search|清除搜索)$')) { $report.reason = 'search-filter-active' }
    elseif ($typeFilters.Count -gt 1 -or ($typeFilters.Count -eq 1 -and $typeFilters[0].name -notmatch '^(Filter skills and rules:\s*All|筛选技能与规则[:：]\s*全部)$')) { $report.reason = 'skill-filter-not-all' }
    elseif ($Nodes.name -match '^(See \d+ more skills and rules|查看更多\s*[（(]\d+[)）])$') { $report.reason = 'skill-list-not-expanded' }
    if ($report.reason) { return [pscustomobject]$report }

    $ruleLabel = 'Global: Installed in ' + $ConfigDirectory + '\AGENTS.md'
    $skillsLabel = 'Global: Installed in ' + $ConfigDirectory + '\skills'
    $globalGroups = @($Nodes | Where-Object role -eq 'Group')
    $report.rule = [ordered]@{globalAgentsMd=$globalGroups.name -contains $ruleLabel}
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($skill in $ExpectedSkills) { [void]$expected.Add($skill) }
    $matched = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($node in $Nodes) {
        if ($node.globalSkillRow -and ($node.role -eq 'Text' -or $node.role -eq 'Button')) {
            $name = $node.name.TrimStart('/') -replace ' (的更多操作|more actions)$', ''
            if ($expected.Contains($name)) { [void]$matched.Add($name) }
        }
    }
    $globalSkillRows = @($globalGroups | Where-Object name -eq $skillsLabel).Count
    $completeSkills = $expected.Count -gt 0 -and $matched.Count -eq $expected.Count -and $globalSkillRows -ge $expected.Count
    if ($typeFilters.Count -eq 0 -and (!$report.rule.globalAgentsMd -or !$completeSkills)) {
        # The installed page does not always expose its type filter to UI Automation.
        $report.reason = 'skill-filter-unverified'
        $report.rule = $null
        return [pscustomobject]$report
    }
    $report.skills = [ordered]@{expected=$expected.Count; matched=$matched.Count; globalRows=$globalSkillRows}

    $mcpHeader = @($Nodes | Where-Object { $_.role -eq 'Button' -and $_.name -match '^MCP (Servers|服务器) 1$' })
    $toolsEnabled = $null
    if ($mcpHeader.Count -eq 1) {
        $mcp = @($Nodes | Where-Object { $_.role -eq 'Text' -and $_.name -ceq 'magpie' })
        $toolButtons = @($Nodes | Where-Object { $_.role -eq 'Button' -and $_.name -match '^(\d+) (tools? enabled|个工具已启用)$' })
        if ($mcp.Count -eq 1 -and $toolButtons.Count -eq 1 -and $toolButtons[0].name -match '^(\d{1,6}) ') {
            $toolsEnabled = [int]$Matches[1]
        }
    }
    $report.mcp = [ordered]@{magpie=$null -ne $toolsEnabled; toolsEnabled=$toolsEnabled}
    $report.reason = if (!$report.rule.globalAgentsMd) { 'shared-rule-unverified' }
        elseif (!$completeSkills) { 'managed-skills-unverified' }
        elseif (!$toolsEnabled) { 'magpie-tools-unverified' }
        else { $null }
    if (!$report.reason) { $report.status = 'verified' }
    [pscustomobject]$report
}

function Find-AntigravityVisibleWindow([int]$ProcessId) {
    if (-not ('HostDiagnostics.AntigravityVisibleWindows' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace HostDiagnostics {
    public static class AntigravityVisibleWindows {
        private delegate bool EnumProc(IntPtr window, IntPtr unused);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr unused);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out int owner);

        public static IntPtr[] Get(int processId) {
            var windows = new List<IntPtr>();
            bool complete = EnumWindows((window, unused) => {
                int owner;
                if (GetWindowThreadProcessId(window, out owner) != 0 && owner == processId && IsWindowVisible(window)) {
                    windows.Add(window);
                }
                return windows.Count <= 16;
            }, IntPtr.Zero);
            if (!complete) throw new InvalidOperationException("Visible window enumeration incomplete.");
            return windows.ToArray();
        }
    }
}
'@
    }
    [HostDiagnostics.AntigravityVisibleWindows]::Get($ProcessId)
}

function Get-AntigravityInstalledWindowReport {
    param([IntPtr[]]$Windows, [int]$ProcessId, [string]$ConfigDirectory, [string[]]$ExpectedSkills)

    $views = @(foreach ($window in $Windows) {
        $nodes = @(Read-AntigravityInstalledView $window $ProcessId $ConfigDirectory)
        $result = Get-AntigravityInstalledReadback $nodes $ConfigDirectory $ExpectedSkills
        if ($result.reason -ne 'installed-view-unavailable') { $result }
    })
    if ($views.Count -eq 1) { return $views[0] }
    [pscustomobject]@{
        status='not-verified'; rule=$null; skills=$null; mcp=$null
        reason=if ($views.Count -eq 0) { 'installed-view-unavailable' } else { 'installed-view-ambiguous' }
    }
}

function Test-AntigravityGlobalSkillCard($Children, [string]$GlobalLabel) {
    $button = [Windows.Automation.ControlType]::Button
    $group = [Windows.Automation.ControlType]::Group
    if ($Children.Count -ne 2 -or $Children[0].Cached.ControlType -ne $button -or
        $Children[1].Cached.ControlType -ne $group) { return $false }

    # The detail button owns the scope badge. Its sibling group owns the named action.
    $badges = @($Children[0].CachedChildren | Where-Object {
        $_.Cached.ControlType -eq $group -and $_.Cached.Name -ceq $GlobalLabel
    })
    $actions = @($Children[1].CachedChildren | Where-Object {
        $_.Cached.ControlType -eq $button -and $_.Cached.Name -match '^.+ (的更多操作|more actions)$'
    })
    return $badges.Count -eq 1 -and $actions.Count -eq 1
}

function Read-AntigravityInstalledView([IntPtr]$Window, [int]$ProcessId, [string]$ConfigDirectory) {
    $null = Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
    $root = [Windows.Automation.AutomationElement]::FromHandle($Window)
    if ($root.Current.ProcessId -ne $ProcessId) { throw 'Automation window identity changed.' }
    $cache = [Windows.Automation.CacheRequest]::new()
    $cache.Add([Windows.Automation.AutomationElement]::NameProperty)
    $cache.Add([Windows.Automation.AutomationElement]::ControlTypeProperty)
    $cache.Add([Windows.Automation.AutomationElement]::IsControlElementProperty)
    $cache.Add([Windows.Automation.ValuePattern]::ValueProperty)
    $cache.TreeFilter = [Windows.Automation.Automation]::RawViewCondition
    $cache.TreeScope = [Windows.Automation.TreeScope]::Subtree
    $cache.AutomationElementMode = [Windows.Automation.AutomationElementMode]::None
    $pending = [Collections.Generic.Stack[object]]::new()
    $pending.Push(@{element=$root.GetUpdatedCache($cache); globalSkillRow=$false})
    $label = 'Global: Installed in ' + $ConfigDirectory + '\skills'
    while ($pending.Count) {
        $row = $pending.Pop()
        $element = $row.element
        $name = $element.Cached.Name
        $role = $element.Cached.ControlType.ProgrammaticName -replace '^ControlType\.', ''
        $children = $element.CachedChildren
        $globalSkillRow = $row.globalSkillRow -or ($role -eq 'Group' -and (
            $name -ceq $label -or (Test-AntigravityGlobalSkillCard $children $label)))
        foreach ($child in $children) {
            $pending.Push(@{element=$child; globalSkillRow=$globalSkillRow})
        }
        if (!$name -or !$element.Cached.IsControlElement -or $role -notin 'Button','Text','Group','Edit') { continue }
        $value = $null
        if ($role -eq 'Edit' -and $name -match '^(搜索插件|搜索自定义项|Search plugins|Search customizations)(?:\.{3}|…)$') {
            $read = $element.GetCachedPropertyValue([Windows.Automation.ValuePattern]::ValueProperty, $true)
            if ($read -is [string]) { $value = $read }
        }
        [pscustomobject]@{name=$name; role=$role; value=$value; globalSkillRow=$globalSkillRow}
    }
    if ($root.Current.ProcessId -ne $ProcessId) { throw 'Automation window identity changed.' }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $process = $null
    try {
        . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/AntigravityProcessIdentity.ps1')
        $applicationPaths = @(
            'D:\Apps\Google.Antigravity\Antigravity.exe'
            (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs\antigravity\Antigravity.exe')
        )
        $session = (Get-Process -Id $PID).SessionId
        $main = @(foreach ($exe in $applicationPaths) {
            Get-AntigravityObservedProcess $exe $session | Where-Object isDesktopMain | ForEach-Object {
                [pscustomobject]@{observed=$_; executable=$exe}
            }
        })
        if ($main.Count -ne 1) {
            $result = @{status='not-verified'; reason='desktop-window-unavailable'}
        } else {
            $process = Assert-AntigravityDesktopMainProcess $main[0].observed $main[0].executable $session
            $homePath = [Environment]::GetFolderPath('UserProfile')
            $configDirectory = Join-Path $homePath '.gemini\config'
            $library = 'D:/Codex/.config/magpie/library.json'
            $data = [IO.File]::ReadAllText($library) | ConvertFrom-Json -AsHashtable
            $expected = @($data.skills | Where-Object { $_.agents -contains 'antigravity' -and !$_.offHere } | ForEach-Object name)
            # Electron overlays can occupy Process.MainWindowHandle alongside the real application window.
            $windows = @(Find-AntigravityVisibleWindow $process.Id)
            $result = Get-AntigravityInstalledWindowReport $windows $process.Id $configDirectory $expected
            if ($process.HasExited) { throw 'Desktop process exited during readback.' }
        }
    } catch {
        $result = @{status='not-verified'; reason='client-readback-unavailable'; errorType=$_.Exception.GetType().Name}
    } finally {
        if ($process) { $process.Dispose() }
    }
    $result | ConvertTo-Json -Depth 4 -Compress
    if ($result.status -ne 'verified') { exit 1 }
}
