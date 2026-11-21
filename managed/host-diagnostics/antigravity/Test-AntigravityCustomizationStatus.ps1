#Requires -Version 7.5
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Get-AntigravityCustomizationStatus.ps1')

function Assert-Equal($Expected, $Actual, [string]$Check) {
    if ($Expected -cne $Actual) { throw "Antigravity customization fixture: $Check" }
}

function New-View([string]$Name, [string]$Role, [string]$Value, [bool]$GlobalSkillRow = $false) {
    [pscustomobject]@{name=$Name; role=$Role; value=$Value; globalSkillRow=$GlobalSkillRow}
}

$config = 'C:\Fixture User\.gemini\config'
$published = @('alpha', 'beta')
$view = @(
    (New-View 'Search plugins...' 'Edit' ''),
    (New-View 'Filter skills and rules: All' 'Button'),
    (New-View 'Skills and Rules 4' 'Button'),
    (New-View "Global: Installed in $config\AGENTS.md" 'Group'),
    (New-View "Global: Installed in $config\skills" 'Group'),
    (New-View "Global: Installed in $config\skills" 'Group'),
    (New-View '/alpha' 'Text' -GlobalSkillRow $true),
    (New-View 'beta 的更多操作' 'Button' -GlobalSkillRow $true),
    (New-View 'built-in' 'Text'),
    (New-View 'MCP Servers 1' 'Button'),
    (New-View 'magpie' 'Text'),
    (New-View '47 tools enabled' 'Button'),
    (New-View 'private-unrelated-window-content' 'Text')
)

$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'verified' $report.status 'all three surfaces verified'
Assert-Equal 2 $report.skills.matched 'match exact managed names, not the heading total'
Assert-Equal 47 $report.mcp.toolsEnabled 'confirmed tool count'
if (($report | ConvertTo-Json -Depth 5) -match 'private-unrelated-window-content|<test-secret>') {
    throw 'Unrelated UI content appeared in the receipt.'
}

$view[0].value = '<test-secret>'
$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'search-filter-active' $report.reason 'a filtered or stale inventory is not an acceptance check'
Assert-Equal $null $report.skills 'filter branch reports no misleading skill count'
if (($report | ConvertTo-Json -Depth 5) -match '<test-secret>') { throw 'Search value appeared in the receipt.' }

$view[0].value = ' '
$view[1].name = 'Filter skills and rules: Rules'
$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'skill-filter-not-all' $report.reason 'the scope filter is independent of search'

$view[1].name = 'Filter skills and rules: All'
$view[2].name = '技能与规则 4'
$view[11].name = '0 tools enabled'
$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'magpie-tools-unverified' $report.reason 'listed server with zero enabled tools is not sufficient'

$view[11].name = '47 tools enabled'
$view[9].name = 'MCP Servers 2'
$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'magpie-tools-unverified' $report.reason 'an unbound tool count must not be attributed to Magpie'
$view[9].name = 'MCP 服务器 1'
$view[7].name = '/beta-other'
$view += New-View 'See 1 more skills and rules' 'Button'
$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'skill-list-not-expanded' $report.reason 'a partial list is not an acceptance check'

$view = @($view | Where-Object name -ne 'See 1 more skills and rules')
$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'managed-skills-unverified' $report.reason 'prefix match cannot accept a different skill'

$view[7].name = '/beta'
$view[7].globalSkillRow = $false
$view += New-View '/gamma' 'Text' -GlobalSkillRow $true
$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'managed-skills-unverified' $report.reason 'a workspace skill cannot borrow another skill''s global location'
$view[7].globalSkillRow = $true
$withoutFilterLabel = @($view | Where-Object name -ne 'Filter skills and rules: All')
$report = Get-AntigravityInstalledReadback -Nodes $withoutFilterLabel -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'verified' $report.status 'all exact items prove coverage when the filter control has no accessible label'
$report = Get-AntigravityInstalledReadback -Nodes $withoutFilterLabel -ConfigDirectory $config -ExpectedSkills @('alpha','beta','missing-skill')
Assert-Equal 'skill-filter-unverified' $report.reason 'an unknown scope with partial skill evidence cannot be interpreted'
Assert-Equal $null $report.skills 'unknown scope must not report a misleading count'
$view[3].name = 'Global: Installed in C:\Another User\.gemini\config\AGENTS.md'
$report = Get-AntigravityInstalledReadback -Nodes $view -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'shared-rule-unverified' $report.reason 'a different scope cannot substitute for the configured rule'
Add-Type -AssemblyName UIAutomationTypes
function New-CachedElement([string]$Name, $Type, [object[]]$Children = @()) {
    [pscustomobject]@{Cached=[pscustomobject]@{Name=$Name; ControlType=$Type}; CachedChildren=$Children}
}
$group = [Windows.Automation.ControlType]::Group
$button = [Windows.Automation.ControlType]::Button
$scope = New-CachedElement "Global: Installed in $config\skills" $group
$detail = New-CachedElement 'alpha' $button @($scope)
$action = New-CachedElement 'alpha 的更多操作' $button
$actions = New-CachedElement '' $group @($action)
Assert-Equal $true (Test-AntigravityGlobalSkillCard @($detail,$actions) $scope.Cached.Name) 'scope badge and named action in sibling branches of one card'
$neighbor = New-CachedElement '' $group @($detail)
Assert-Equal $false (Test-AntigravityGlobalSkillCard @($neighbor,$actions) $scope.Cached.Name) 'a neighboring card cannot lend its scope badge'

$view[3].name = "Global: Installed in $config\AGENTS.md"
function Read-AntigravityInstalledView([IntPtr]$Window, [int]$ProcessId, [string]$ConfigDirectory) {
    if ($ProcessId -ne 123 -or $ConfigDirectory -ne $config) { throw 'UI read lost its process or configuration binding.' }
    if ($Window -in 20, 30) { $view }
    else { New-View 'Tooltip' 'Text' }
}
$report = Get-AntigravityInstalledWindowReport -Windows @(10,20) -ProcessId 123 -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'verified' $report.status 'select the Installed page when a tooltip appears first'
$report = Get-AntigravityInstalledWindowReport -Windows @(10) -ProcessId 123 -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'installed-view-unavailable' $report.reason 'a tooltip alone cannot verify the page'
$report = Get-AntigravityInstalledWindowReport -Windows @(20,30) -ProcessId 123 -ConfigDirectory $config -ExpectedSkills $published
Assert-Equal 'installed-view-ambiguous' $report.reason 'refuse to choose between two Installed pages'
Write-Output 'PASS AntigravityCustomizationStatus'
