#requires -Version 7.4
<#
.SYNOPSIS
Exercise Invoke-ManagedRecycle through its public process interface on D: fixtures.
.DESCRIPTION
Check, refusal and plan cases never touch the Recycle Bin. The live case recycles two fixture trees into the D: bin,
the second while the first one's $I index record is held open the way Explorer or a scanner briefly holds a new
record and a decoy $I record for another path sits in the bin, then restores both the way Explorer does, without
deleting anything: each $R content moves back to its path and each $I record, the decoy included, moves into this
run's evidence. The same case then recycles a third tree whose hard links all stay inside it, planned with
-AllowInternalHardLinks, and restores it the same way. -SkipLiveRecycle reports that case as skipped. Every call
passes a fixture knowledge base under the run directory, so the live knowledge base never decides a case.
#>
[CmdletBinding()]
param(
    [string]$EvidenceRoot = 'D:/agents/run-evidence/managed-recycle-tests',
    [switch]$SkipLiveRecycle
)

$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$fullEvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
if (-not $fullEvidenceRoot.StartsWith('D:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'EvidenceRoot must resolve to D drive.' }
$runRoot = Join-Path $fullEvidenceRoot ('ManagedRecycle-' + [guid]::NewGuid().ToString('N'))
$fixtures = Join-Path $runRoot 'fixtures'
$entryEvidence = Join-Path $runRoot 'entry'
$knowledgeBase = Join-Path $runRoot 'knowledge-base'
[void][IO.Directory]::CreateDirectory($fixtures)
[void][IO.Directory]::CreateDirectory($entryEvidence)
[void][IO.Directory]::CreateDirectory((Join-Path $knowledgeBase 'wiki\topics'))
$entry = Join-Path $PSScriptRoot 'Invoke-ManagedRecycle.ps1'
$cases = [Collections.Generic.List[object]]::new()
$junctions = [Collections.Generic.List[string]]::new()
$expectedManifest = @("D`tempty", "D`tsub", "F`ta.txt`t5", "F`tsub\b.bin`t1024")
$liveCase = 'live recycle finds each tree''s own bin record past a locked record and a newer decoy, moves a tree with internal hard links whole, and the test restores them'
# Whether the fixture volume has bin settings; a fresh profile (a CI runner) has none until the volume's bin is first used.
$fixtureVolume = try { [string](Get-CimInstance Win32_Volume -Filter "DriveLetter='$([IO.Path]::GetPathRoot($fullEvidenceRoot).TrimEnd('\'))'").DeviceID } catch { '' }
$binSettingsKey = if ($fixtureVolume) {
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\' + ($fixtureVolume -replace '^\\\\\?\\Volume|\\$', '')
}
function Test-BinSettings {
    if (-not $binSettingsKey) { return $null }
    $settings = Get-ItemProperty -LiteralPath $binSettingsKey -ErrorAction SilentlyContinue
    $null -ne $settings -and $null -ne $settings.PSObject.Properties['MaxCapacity'] -and $null -ne $settings.PSObject.Properties['NukeOnDelete']
}
$binSettingsAtStart = Test-BinSettings
# Earlier suites can create the settings first. Only on a disposable GitHub-hosted runner, the Check case removes them right
# before it calls the entry, so a pass always proves that the entry's query-first order recreates them.
$resetBinSettings = $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted' -and [bool]$binSettingsKey
$binSettingsCheck = [ordered]@{ reset = $false; removed = $null; beforeCheck = $null; afterCheck = $null }

function Invoke-Entry {
    param([string[]]$EntryArguments)
    $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $entry) + $EntryArguments + @('-EvidenceRoot', $entryEvidence, '-KnowledgeBaseRoot', $knowledgeBase)) {
        $psi.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            throw 'Entry exceeded its 60-second test timeout.'
        }
        $out = $stdout.GetAwaiter().GetResult()
        $json = try { $out | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $null }
        [pscustomobject]@{ exitCode = $process.ExitCode; json = $json; stdout = $out; stderr = $stderr.GetAwaiter().GetResult() }
    }
    finally {
        if (-not $process.HasExited) { $process.Kill($true) }
        $process.Dispose()
    }
}

function Invoke-Plan([string]$Target) {
    Invoke-Entry @('-Mode', 'Plan', '-TargetPath', $Target, '-Purpose', 'managed recycle test', '-Authorization', 'test fixture created by this run')
}

function Assert-Refused($Response, [string]$Reason) {
    if ($null -eq $Response.json) { throw "Entry output was not JSON (exit $($Response.exitCode))." }
    if ($Response.exitCode -ne 1 -or $Response.json.status -ne 'refused' -or $Response.json.reason -ne $Reason) {
        throw "Expected refusal '$Reason'; received exit $($Response.exitCode) status '$($Response.json.status)' reason '$($Response.json.reason)'."
    }
    if ($Response.stderr) { throw 'Entry wrote to stderr.' }
}

function Assert-Case {
    param([string]$Name, [scriptblock]$Test)
    try {
        & $Test
        $cases.Add([pscustomobject]@{ name = $Name; status = 'passed' })
    } catch {
        $cases.Add([pscustomobject]@{ name = $Name; status = 'failed'; reason = $_.Exception.Message })
    }
}

function New-Tree([string]$Name) {
    $root = Join-Path $fixtures $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'sub'))
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'empty'))
    [IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'hello', $utf8)
    [IO.File]::WriteAllBytes((Join-Path $root 'sub\b.bin'), [byte[]]::new(1024))
    $root
}

function Invoke-FixtureGit([string]$WorkTree, [string[]]$Arguments) {
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & git -C $WorkTree -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.autocrlf=false @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') exited $LASTEXITCODE`: $($output -join ' ')" }
}

function New-Junction([string]$Path, [string]$Target) {
    $null = New-Item -ItemType Junction -Path $Path -Target $Target
    $junctions.Add($Path)
}

# A version 2 $I record for a path that was never recycled, dated a day ahead so that it is the newest in the bin.
function New-BinDecoy([string]$BinDirectory, [string]$Original) {
    $path = Join-Path $BinDirectory ('$I' + [guid]::NewGuid().ToString('N').Substring(0, 6).ToUpperInvariant())
    $name = [Text.Encoding]::Unicode.GetBytes($Original + [char]0)
    $bytes = [byte[]]([BitConverter]::GetBytes([long]2) + [BitConverter]::GetBytes([long]1029) +
        [BitConverter]::GetBytes([DateTime]::UtcNow.AddDays(1).ToFileTimeUtc()) + [BitConverter]::GetBytes([int]($name.Length / 2)) + $name)
    $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
    $path
}

# Explorer and scanners briefly open new $I records; retry a step on one for up to 10 seconds.
function Invoke-BinStep([scriptblock]$Step) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ($true) {
        try { return & $Step }
        catch [IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

$realTarget = Join-Path $fixtures 'junction-target'
[void][IO.Directory]::CreateDirectory((Join-Path $realTarget 'child'))
$longTree = Join-Path $fixtures 'tree-long'
$longFile = $null

try {
    Assert-Case 'plan refuses relative and missing targets' {
        Assert-Refused (Invoke-Plan 'relative\target') 'target-not-fully-qualified'
        Assert-Refused (Invoke-Plan (Join-Path $fixtures 'missing')) 'target-missing'
    }

    Assert-Case 'plan refuses volume roots, protected roots and their ancestors' {
        foreach ($target in @('D:\', 'D:\agents\projects', 'C:\Users', $entryEvidence, (Split-Path -Parent $entryEvidence))) {
            $response = Invoke-Plan $target
            Assert-Refused $response 'protected-location'
            if ($response.json.protection -notin @('volume-root', 'protected-root')) { throw "Unexpected protection for $target." }
        }
    }

    Assert-Case 'plan refuses system subtrees, the bin and the evidence root' {
        $windowsTemp = Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp'
        foreach ($target in @($windowsTemp, 'D:\$Recycle.Bin', (Join-Path $entryEvidence 'inside'))) {
            $response = Invoke-Plan $target
            Assert-Refused $response 'protected-location'
            if ($response.json.protection -ne 'protected-subtree') { throw "Unexpected protection for $target." }
        }
    }

    Assert-Case 'plan refuses a junction on the target path' {
        $link = Join-Path $fixtures 'junction-on-path'
        New-Junction $link $realTarget
        $response = Invoke-Plan (Join-Path $link 'child')
        Assert-Refused $response 'reparse-point-on-path'
        if ($response.json.reparsePoint -ne $link) { throw 'The reported reparse point is not the junction.' }
    }

    Assert-Case 'plan refuses a junction inside the tree' {
        $tree = New-Tree 'tree-junction'
        New-Junction (Join-Path $tree 'inner') $realTarget
        $response = Invoke-Plan $tree
        Assert-Refused $response 'tree-not-recyclable'
        if (@($response.json.problems) -notcontains 'reparse-point: inner') { throw 'The junction was not reported.' }
    }

    Assert-Case 'plan refuses hard-linked files' {
        $tree = New-Tree 'tree-hardlink'
        $null = New-Item -ItemType HardLink -Path (Join-Path $fixtures 'hardlink-twin.txt') -Target (Join-Path $tree 'a.txt')
        $response = Invoke-Plan $tree
        Assert-Refused $response 'tree-not-recyclable'
        if (@($response.json.problems) -notcontains 'hard-link: a.txt (2 links)') { throw 'The hard link was not reported.' }
    }

    Assert-Case 'check accepts hard links that stay inside the tree only with -AllowInternalHardLinks' {
        $tree = New-Tree 'tree-internal-hardlink'
        $null = New-Item -ItemType HardLink -Path (Join-Path $tree 'sub\a-twin.txt') -Target (Join-Path $tree 'a.txt')
        $refused = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree)
        Assert-Refused $refused 'tree-not-recyclable'
        if (@($refused.json.problems) -notcontains 'hard-link: a.txt (2 links)') { throw 'Without the switch the hard link was not reported.' }
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree, '-AllowInternalHardLinks')
        if ($response.exitCode -ne 0 -or $response.json.status -ne 'checked' -or $response.stderr) { throw "Check failed: $($response.stdout)" }
        if ($response.json.internalHardLinkFiles -ne 2 -or $response.json.fileCount -ne 3 -or $response.json.totalBytes -ne 1034) { throw 'Check did not count the internal hard links.' }
    }

    Assert-Case '-AllowInternalHardLinks still refuses a hard link with a name outside the tree' {
        $tree = New-Tree 'tree-external-hardlink'
        # A sibling whose path starts with the tree's path is still outside the tree.
        $sibling = $tree + '-sibling'
        [void][IO.Directory]::CreateDirectory($sibling)
        $null = New-Item -ItemType HardLink -Path (Join-Path $sibling 'a-twin.txt') -Target (Join-Path $tree 'a.txt')
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree, '-AllowInternalHardLinks')
        Assert-Refused $response 'tree-not-recyclable'
        if (@($response.json.problems) -notcontains 'hard-link-outside-target: a.txt (2 links)') { throw 'The name outside the tree was not reported.' }
        Assert-Refused (Invoke-Entry @('-Mode', 'Check', '-TargetPath', (Join-Path $tree 'a.txt'), '-AllowInternalHardLinks')) 'tree-not-recyclable'
    }

    Assert-Case 'plan refuses paths the shell cannot move' {
        [void][IO.Directory]::CreateDirectory($longTree)
        $name = 'x' * (262 - $longTree.Length - 1)
        $script:longFile = Join-Path $longTree $name
        [IO.File]::WriteAllText($script:longFile, 'long', $utf8)
        $response = Invoke-Plan $longTree
        Assert-Refused $response 'path-too-long'
        if ($response.json.longestPath -le 259) { throw 'The longest path was not measured.' }
        $binDirectory = 'D:\$Recycle.Bin\' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($response.json.inPlaceLongestPath -ne 262 -or $response.json.inBinLongestPath -ne $binDirectory.Length + 10 + $name.Length) {
            throw 'The in-place and in-bin lengths were not reported.'
        }
        if ($response.json.tooLongCount -ne 1 -or [string]::Join('|', $response.json.tooLong) -cne $name) { throw 'The entry over the limit was not named.' }
    }

    Assert-Case 'check refuses entries this process cannot open for delete and names them' {
        # The way an installer leaves Users with read and execute only: no DELETE on sub and no FILE_DELETE_CHILD on its
        # parent, so neither route grants the delete the shell needs; the shell would fail the recycle with 0x78.
        $tree = New-Tree 'tree-delete-denied'
        $sub = Join-Path $tree 'sub'
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $denyDelete = [Security.AccessControl.FileSystemAccessRule]::new($user, 'Delete', 'Deny')
        $denyChild = [Security.AccessControl.FileSystemAccessRule]::new($user, 'DeleteSubdirectoriesAndFiles', 'Deny')
        $subAcl = Get-Acl -LiteralPath $sub
        $subAcl.AddAccessRule($denyDelete)
        Set-Acl -LiteralPath $sub -AclObject $subAcl
        $treeAcl = Get-Acl -LiteralPath $tree
        $treeAcl.AddAccessRule($denyChild)
        Set-Acl -LiteralPath $tree -AclObject $treeAcl
        try {
            $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree)
            Assert-Refused $response 'delete-access-denied'
            if ($response.json.deleteDeniedCount -ne 1 -or @($response.json.deleteDenied) -cne @('sub') -or $null -eq $response.json.elevated) {
                throw "The refusal does not name exactly sub or omits elevated: $($response.stdout)"
            }
        }
        finally {
            $subAcl = Get-Acl -LiteralPath $sub
            [void]$subAcl.RemoveAccessRule($denyDelete)
            Set-Acl -LiteralPath $sub -AclObject $subAcl
            $treeAcl = Get-Acl -LiteralPath $tree
            [void]$treeAcl.RemoveAccessRule($denyChild)
            Set-Acl -LiteralPath $tree -AclObject $treeAcl
        }
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree)
        if ($response.exitCode -ne 0 -or $response.json.status -ne 'checked') { throw "Check failed after the ACL was restored: $($response.stdout)" }
    }

    Assert-Case 'plan requires purpose and authorization' {
        $tree = New-Tree 'tree-unauthorized'
        Assert-Refused (Invoke-Entry @('-Mode', 'Plan', '-TargetPath', $tree, '-Purpose', 'managed recycle test')) 'purpose-and-authorization-required'
        if (@(Get-ChildItem -LiteralPath $entryEvidence -Filter 'plan.json' -Recurse).Count -ne 0) { throw 'A refused plan wrote plan.json.' }
    }

    Assert-Case 'check shares the preflight without purpose or authorization' {
        Assert-Refused (Invoke-Entry @('-Mode', 'Check', '-TargetPath', (Join-Path $fixtures 'missing'))) 'target-missing'
        Assert-Refused (Invoke-Entry @('-Mode', 'Check', '-TargetPath', 'D:\agents\projects')) 'protected-location'
    }

    Assert-Case 'check and plan refuse a target that a knowledge-base page lists as a source, and name the page' {
        $tree = New-Tree 'tree-kb-cited'
        $pages = Join-Path $knowledgeBase 'wiki\topics'
        $inline = Join-Path $pages 'cites-a-file-inside.md'
        $block = Join-Path $pages 'cites-the-tree.md'
        # Inline JSON list with a page-relative file inside the target and a web source; block list with the target
        # itself as an absolute path and a sibling whose name only starts with the target's name; a page elsewhere.
        [IO.File]::WriteAllText($inline, "---`ntype: topic`nsources: [""../../../fixtures/tree-kb-cited/sub/b.bin"", ""https://example.com/x""]`n---`nbody`n", $utf8)
        [IO.File]::WriteAllText($block, "---`ntype: topic`nsources:`n  - $tree`n  - ../../../fixtures/tree-kb-cited-sibling/a.txt`n---`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $pages 'cites-elsewhere.md'), "---`ntype: topic`nsources: [""../../../fixtures/never-a-target/a.txt""]`n---`n", $utf8)
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree)
        Assert-Refused $response 'kb-cited'
        $named = @($response.json.kbCitations | ForEach-Object { "$($_.page) <- $($_.source)" } | Sort-Object)
        $expected = @("wiki/topics/cites-a-file-inside.md <- ../../../fixtures/tree-kb-cited/sub/b.bin", "wiki/topics/cites-the-tree.md <- $tree" | Sort-Object)
        if ($response.json.kbCitationCount -ne 2 -or ($named -join '|') -ne ($expected -join '|')) { throw "Citations named wrongly: $($named -join '; ')" }
        Assert-Refused (Invoke-Plan $tree) 'kb-cited'
        # Repointing the pages, which the knowledge base requires before a source goes away, clears the refusal.
        [IO.File]::WriteAllText($inline, "---`ntype: topic`nsources: [""https://example.com/x""]`n---`nbody`n", $utf8)
        [IO.File]::WriteAllText($block, "---`ntype: topic`nsources:`n  - ../../../fixtures/tree-kb-cited-sibling/a.txt`n---`n", $utf8)
        $cleared = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree)
        if ($cleared.exitCode -ne 0 -or $cleared.json.status -ne 'checked') { throw "Check still refused after the pages were repointed: $($cleared.stdout)" }
    }

    Assert-Case 'check and plan refuse git work the recycle would lose, and apply rechecks with the authorization the plan recorded' {
        $remote = Join-Path $fixtures 'git-remote.git'
        $repo = New-Tree 'tree-git'
        Invoke-FixtureGit $fixtures @('init', '-q', '--bare', '-b', 'main', $remote)
        Invoke-FixtureGit $repo @('init', '-q', '-b', 'main')
        [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), "ignored/`n", $utf8)
        Invoke-FixtureGit $repo @('add', '-A')
        Invoke-FixtureGit $repo @('commit', '-q', '-m', 'fixture')
        Invoke-FixtureGit $repo @('remote', 'add', 'origin', ([Uri]$remote).AbsoluteUri)
        Invoke-FixtureGit $repo @('push', '-q', 'origin', 'main')
        # Clean and pushed, with gitignored content and a clean nested clone: nothing to lose.
        [void][IO.Directory]::CreateDirectory((Join-Path $repo 'ignored'))
        [IO.File]::WriteAllText((Join-Path $repo 'ignored\cache.bin'), 'x', $utf8)
        Invoke-FixtureGit $repo @('clone', '-q', ([Uri]$remote).AbsoluteUri, 'vendor/lib')
        $clean = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $repo)
        if ($clean.exitCode -ne 0 -or $clean.json.status -ne 'checked' -or $clean.stderr) { throw "Check refused a clean, pushed repository: $($clean.stdout)" }
        # A commit no remote has, a stash and an untracked file.
        [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'changed', $utf8)
        Invoke-FixtureGit $repo @('commit', '-q', '-am', 'local only')
        [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'stashed', $utf8)
        Invoke-FixtureGit $repo @('stash', '-q')
        [IO.File]::WriteAllText((Join-Path $repo 'notes.txt'), 'draft', $utf8)
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $repo)
        Assert-Refused $response 'git-unsaved-work'
        $work = @($response.json.gitUnsavedWork)
        if ($work.Count -ne 2 -or $work[0].workTree -ne $repo -or $work[0].uncommitted -ne 1 -or (@($work[0].uncommittedPaths) -join '|') -ne 'notes.txt' -or
            $work[1].gitDir -ne (Join-Path $repo '.git') -or $work[1].unpushedCommits -ne 1 -or $work[1].stashes -ne 1) { throw "Unsaved work named wrongly: $($response.stdout)" }
        # Inside the work tree only the target's own files count; the repository and its commits stay.
        $subTarget = Join-Path $repo 'sub'
        $sub = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $subTarget)
        if ($sub.exitCode -ne 0 -or $sub.json.status -ne 'checked') { throw "Check refused a clean subdirectory: $($sub.stdout)" }
        [IO.File]::WriteAllText((Join-Path $subTarget 'new.txt'), 'draft', $utf8)
        $subDirty = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $subTarget)
        Assert-Refused $subDirty 'git-unsaved-work'
        $subWork = @($subDirty.json.gitUnsavedWork)
        if ($subWork.Count -ne 1 -or $subWork[0].workTree -ne $repo -or $subWork[0].uncommitted -ne 1 -or $subWork[0].Contains('gitDir')) {
            throw "A subdirectory counted the repository's commits: $($subDirty.stdout)"
        }
        Assert-Refused (Invoke-Plan $repo) 'git-unsaved-work'
        $words = 'fixture: lose the local commit, the stash and the drafts'
        $planned = Invoke-Entry @('-Mode', 'Plan', '-TargetPath', $repo, '-Purpose', 'managed recycle test', '-Authorization', 'test fixture created by this run', '-GitLossAuthorization', $words)
        if ($planned.exitCode -ne 0 -or $planned.json.status -ne 'planned' -or $planned.stderr) { throw "Plan with the git loss authorization failed: $($planned.stdout)" }
        $plan = [IO.File]::ReadAllText($planned.json.planPath) | ConvertFrom-Json -AsHashtable
        if ($plan.gitLossAuthorization -cne $words -or @($plan.gitUnsavedWork).Count -ne 2 -or $plan.gitUnsavedWork[0].uncommitted -ne 2) {
            throw 'The plan did not record the git work and the authorization to lose it.'
        }
        # A same-size edit to a clean tracked file leaves the manifest as planned but adds git work the user did not agree to
        # lose. Refusing for that rather than for the git work as such proves Apply reran the preflight with the plan's authorization.
        $ones = [byte[]]::new(1024)
        [Array]::Fill($ones, [byte]1)
        [IO.File]::WriteAllBytes((Join-Path $repo 'sub\b.bin'), $ones)
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $planned.json.planPath, '-ApprovedPlanSha256', $planned.json.planSha256, '-ConfirmRecycle')) 'git-unsaved-work-changed'
    }

    Assert-Case 'check counts commits that only a tag or a detached HEAD holds, bare repositories, a target inside a git directory, and remotes inside the target' {
        $remote = Join-Path $fixtures 'git-remote-refs.git'
        Invoke-FixtureGit $fixtures @('init', '-q', '--bare', '-b', 'main', $remote)
        $repo = New-Tree 'tree-git-refs'
        Invoke-FixtureGit $repo @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $repo @('add', '-A')
        Invoke-FixtureGit $repo @('commit', '-q', '-m', 'fixture')
        Invoke-FixtureGit $repo @('remote', 'add', 'origin', ([Uri]$remote).AbsoluteUri)
        Invoke-FixtureGit $repo @('push', '-q', 'origin', 'main')
        # No branch holds either commit: one is only on a tag, the other only on the detached HEAD.
        Invoke-FixtureGit $repo @('checkout', '-q', '--detach')
        [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'tagged', $utf8)
        Invoke-FixtureGit $repo @('commit', '-q', '-am', 'tagged')
        Invoke-FixtureGit $repo @('tag', 'kept-by-tag')
        Invoke-FixtureGit $repo @('checkout', '-q', 'main')
        Invoke-FixtureGit $repo @('checkout', '-q', '--detach')
        [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'detached', $utf8)
        Invoke-FixtureGit $repo @('commit', '-q', '-am', 'detached')
        foreach ($target in @($repo, (Join-Path $repo '.git\objects'))) {
            $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $target)
            Assert-Refused $response 'git-unsaved-work'
            $work = @($response.json.gitUnsavedWork)
            if ($work.Count -ne 1 -or $work[0].gitDir -ne (Join-Path $repo '.git') -or $work[0].unpushedCommits -ne 2 -or $work[0].stashes -ne 0) {
                throw "Commits off every branch were not counted for $target`: $($response.stdout)"
            }
        }
        # A bare repository and a clone that pushed to it go together: the bare one has no remote-tracking branches, and the
        # clone's remote lies inside the target, so neither copy survives the recycle.
        $holder = Join-Path $fixtures 'tree-git-bare'
        [void][IO.Directory]::CreateDirectory($holder)
        $central = Join-Path $holder 'central.git'
        Invoke-FixtureGit $holder @('init', '-q', '--bare', '-b', 'main', $central)
        Invoke-FixtureGit $holder @('clone', '-q', ([Uri]$central).AbsoluteUri, 'clone')
        $clone = Join-Path $holder 'clone'
        [IO.File]::WriteAllText((Join-Path $clone 'shared.txt'), 'shared', $utf8)
        Invoke-FixtureGit $clone @('add', '-A')
        Invoke-FixtureGit $clone @('commit', '-q', '-m', 'shared')
        Invoke-FixtureGit $clone @('push', '-q', 'origin', 'main')
        $bare = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $holder)
        Assert-Refused $bare 'git-unsaved-work'
        $bareWork = @($bare.json.gitUnsavedWork)
        if ($bareWork.Count -ne 2 -or $bareWork[0].gitDir -ne $central -or $bareWork[0].unpushedCommits -ne 1 -or
            $bareWork[1].gitDir -ne (Join-Path $clone '.git') -or $bareWork[1].unpushedCommits -ne 1) {
            throw "The bare repository and the clone that pushed to it were not both counted: $($bare.stdout)"
        }
    }

    Assert-Case 'check fails closed on a nested repository git cannot read instead of reading the outer one' {
        $outer = New-Tree 'tree-git-broken'
        [IO.File]::WriteAllText((Join-Path $outer '.gitignore'), "vendor/`n", $utf8)
        Invoke-FixtureGit $outer @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $outer @('add', '-A')
        Invoke-FixtureGit $outer @('commit', '-q', '-m', 'outer')
        $inner = Join-Path $outer 'vendor\inner'
        [void][IO.Directory]::CreateDirectory($inner)
        Invoke-FixtureGit $inner @('init', '-q', '-b', 'main')
        [IO.File]::WriteAllText((Join-Path $inner 'work.txt'), 'only here', $utf8)
        Invoke-FixtureGit $inner @('add', '-A')
        Invoke-FixtureGit $inner @('commit', '-q', '-m', 'inner')
        [IO.File]::WriteAllText((Join-Path $inner '.git\HEAD'), '', $utf8)
        $broken = Invoke-Entry @('-Mode', 'Check', '-TargetPath', (Join-Path $outer 'vendor'))
        Assert-Refused $broken 'git-unsaved-work'
        $errors = @($broken.json.gitUnsavedWork | Where-Object { $_.Contains('error') })
        if ($errors.Count -eq 0 -or @($errors | Where-Object { -not "$($_['workTree'])$($_['gitDir'])".StartsWith($inner) }).Count) {
            throw "The unreadable nested repository was not reported as an error: $($broken.stdout)"
        }
    }

    Assert-Case 'check reads a target typed in another letter case and a nested repository whose name has a space' {
        $remote = Join-Path $fixtures 'git-remote-space.git'
        Invoke-FixtureGit $fixtures @('init', '-q', '--bare', '-b', 'main', $remote)
        $repo = New-Tree 'tree-git-case'
        $mixed = Join-Path $repo 'Mixed'
        [void][IO.Directory]::CreateDirectory($mixed)
        [IO.File]::WriteAllText((Join-Path $mixed 'c.txt'), 'tracked', $utf8)
        Invoke-FixtureGit $repo @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $repo @('add', '-A')
        Invoke-FixtureGit $repo @('commit', '-q', '-m', 'outer')
        $nested = Join-Path $mixed 'vendor lib'
        [void][IO.Directory]::CreateDirectory($nested)
        [IO.File]::WriteAllText((Join-Path $nested 'lib.txt'), 'lib', $utf8)
        Invoke-FixtureGit $nested @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $nested @('add', '-A')
        Invoke-FixtureGit $nested @('commit', '-q', '-m', 'lib')
        Invoke-FixtureGit $nested @('remote', 'add', 'origin', ([Uri]$remote).AbsoluteUri)
        Invoke-FixtureGit $nested @('push', '-q', 'origin', 'main')
        $clean = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $mixed)
        if ($clean.exitCode -ne 0 -or $clean.json.status -ne 'checked') { throw "Check refused a clean directory holding a clean, pushed repository whose name has a space: $($clean.stdout)" }
        [IO.File]::WriteAllText((Join-Path $mixed 'c.txt'), 'edited', $utf8)
        $lower = Invoke-Entry @('-Mode', 'Check', '-TargetPath', (Join-Path $repo 'mixed'))
        Assert-Refused $lower 'git-unsaved-work'
        $work = @($lower.json.gitUnsavedWork)
        if ($work.Count -ne 1 -or $work[0].workTree -ne $repo -or (@($work[0].uncommittedPaths) -join '|') -ne 'Mixed/c.txt') {
            throw "A target typed in lower case missed the tracked edit: $($lower.stdout)"
        }
    }

    Assert-Case 'check runs nothing the repository config names and counts edits that git status is told to skip' {
        $repo = New-Tree 'tree-git-config'
        [IO.File]::WriteAllText((Join-Path $repo '.gitattributes'), "*.dat filter=probe`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $repo 'x.dat'), 'one', $utf8)
        Invoke-FixtureGit $repo @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $repo @('add', '-A')
        Invoke-FixtureGit $repo @('commit', '-q', '-m', 'fixture')
        # a.txt is edited after being marked assume-unchanged, so git status does not report it; x.dat is edited, so
        # status would run the clean filter to compare it.
        Invoke-FixtureGit $repo @('update-index', '--assume-unchanged', 'a.txt')
        [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'edited', $utf8)
        [IO.File]::WriteAllText((Join-Path $repo 'x.dat'), 'two', $utf8)
        # Set last, so no fixture git call runs them: an fsmonitor hook and a clean filter that each leave a marker.
        $marker = (Join-Path $runRoot 'git-config-marker.txt').Replace('\', '/')
        $hook = Join-Path $runRoot 'git-fsmonitor-hook.sh'
        [IO.File]::WriteAllText($hook, "#!/bin/sh`necho fsmonitor >> $marker`nexit 1`n", $utf8)
        Invoke-FixtureGit $repo @('config', 'core.fsmonitor', $hook.Replace('\', '/'))
        Invoke-FixtureGit $repo @('config', 'filter.probe.clean', "sh -c 'echo filter >> $marker; cat'")
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $repo)
        if ([IO.File]::Exists($marker)) { throw "Check ran a command from the repository config: $([IO.File]::ReadAllText($marker).Trim())" }
        Assert-Refused $response 'git-unsaved-work'
        $tree = @($response.json.gitUnsavedWork | Where-Object { $_['workTree'] -eq $repo })
        if ($tree.Count -ne 1 -or $tree[0].hiddenFromStatus -ne 1 -or (@($tree[0].hiddenFromStatusPaths) -join '|') -ne 'a.txt' -or
            (@($tree[0].uncommittedPaths) -join '|') -ne 'x.dat') { throw "Edits hidden from git status were not counted: $($response.stdout)" }
    }

    Assert-Case 'check reads submodules whose gitfile is relative and counts files in a submodule folder that is not checked out' {
        $libRemote = Join-Path $fixtures 'git-remote-sublib.git'
        $superRemote = Join-Path $fixtures 'git-remote-super.git'
        Invoke-FixtureGit $fixtures @('init', '-q', '--bare', '-b', 'main', $libRemote)
        Invoke-FixtureGit $fixtures @('init', '-q', '--bare', '-b', 'main', $superRemote)
        $lib = New-Tree 'git-sublib-source'
        Invoke-FixtureGit $lib @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $lib @('add', '-A')
        Invoke-FixtureGit $lib @('commit', '-q', '-m', 'lib')
        Invoke-FixtureGit $lib @('remote', 'add', 'origin', ([Uri]$libRemote).AbsoluteUri)
        Invoke-FixtureGit $lib @('push', '-q', 'origin', 'main')
        $super = New-Tree 'tree-git-super'
        Invoke-FixtureGit $super @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $super @('add', '-A')
        Invoke-FixtureGit $super @('commit', '-q', '-m', 'super')
        # git submodule add writes lib\.git as "gitdir: ../.git/modules/lib", relative to that file.
        Invoke-FixtureGit $super @('-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', ([Uri]$libRemote).AbsoluteUri, 'lib')
        Invoke-FixtureGit $super @('commit', '-q', '-m', 'add lib')
        Invoke-FixtureGit $super @('remote', 'add', 'origin', ([Uri]$superRemote).AbsoluteUri)
        Invoke-FixtureGit $super @('push', '-q', 'origin', 'main')
        $clean = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $super)
        if ($clean.exitCode -ne 0 -or $clean.json.status -ne 'checked' -or $clean.stderr) { throw "Check refused a clean, pushed superproject with a submodule: $($clean.stdout)" }
        # Cloned without its submodule, lib is a folder git status does not look into.
        Invoke-FixtureGit $fixtures @('clone', '-q', ([Uri]$superRemote).AbsoluteUri, 'tree-git-superclone')
        $clone = Join-Path $fixtures 'tree-git-superclone'
        [void][IO.Directory]::CreateDirectory((Join-Path $clone 'lib\deep'))
        [IO.File]::WriteAllText((Join-Path $clone 'lib\notes.txt'), 'only here', $utf8)
        [IO.File]::WriteAllText((Join-Path $clone 'lib\deep\more.txt'), 'only here', $utf8)
        $expected = [ordered]@{ $clone = 'lib/deep/more.txt|lib/notes.txt'; (Join-Path $clone 'lib') = 'lib/deep/more.txt|lib/notes.txt'; (Join-Path $clone 'lib\deep') = 'lib/deep/more.txt' }
        foreach ($target in $expected.Keys) {
            $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $target)
            Assert-Refused $response 'git-unsaved-work'
            $work = @($response.json.gitUnsavedWork)
            if ($work.Count -ne 1 -or $work[0].workTree -ne $clone -or (@($work[0].uncommittedPaths | Sort-Object) -join '|') -ne $expected[$target]) {
                throw "Files in a submodule folder that is not checked out were missed for $target`: $($response.stdout)"
            }
        }
    }

    Assert-Case 'check matches index paths whose letter case differs from the disk' {
        $repo = New-Tree 'tree-git-index-case'
        $docs = Join-Path $repo 'Docs'
        [void][IO.Directory]::CreateDirectory($docs)
        [IO.File]::WriteAllText((Join-Path $docs 'x.txt'), 'x', $utf8)
        [IO.File]::WriteAllText((Join-Path $docs 'y.txt'), 'y', $utf8)
        Invoke-FixtureGit $repo @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $repo @('add', 'a.txt', 'sub', 'Docs/x.txt')
        # A commit made on a case-sensitive system can hold docs/y.txt beside Docs/x.txt; this disk keeps one Docs folder.
        $blob = "$(& git -C $repo hash-object -w -- Docs/y.txt)".Trim()
        Invoke-FixtureGit $repo @('update-index', '--add', '--cacheinfo', "100644,$blob,docs/y.txt")
        Invoke-FixtureGit $repo @('commit', '-q', '-m', 'two spellings of one folder')
        [IO.File]::WriteAllText((Join-Path $docs 'y.txt'), 'edited', $utf8)
        # The second call inherits GIT_LITERAL_PATHSPECS=1, which would make git read the pathspec magic as a file name.
        foreach ($literal in @($false, $true)) {
            if ($literal) { $env:GIT_LITERAL_PATHSPECS = '1' }
            try { $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $docs) }
            finally { Remove-Item -LiteralPath Env:GIT_LITERAL_PATHSPECS -ErrorAction Ignore }
            Assert-Refused $response 'git-unsaved-work'
            $work = @($response.json.gitUnsavedWork)
            if ($work.Count -ne 1 -or $work[0].workTree -ne $repo -or (@($work[0].uncommittedPaths) -join '|') -ne 'docs/y.txt') {
                throw "An edit to a file the index spells in another case was missed (GIT_LITERAL_PATHSPECS set: $literal): $($response.stdout)"
            }
        }
    }

    Assert-Case 'check reads a blobless partial clone without fetching from its remote' {
        $remote = Join-Path $fixtures 'git-remote-partial.git'
        Invoke-FixtureGit $fixtures @('init', '-q', '--bare', '-b', 'main', $remote)
        Invoke-FixtureGit $remote @('config', 'uploadpack.allowFilter', 'true')
        Invoke-FixtureGit $remote @('config', 'uploadpack.allowAnySHA1InWant', 'true')
        $seed = New-Tree 'git-partial-seed'
        $text = (1..40 | ForEach-Object { "line $_ of a file renamed later" }) -join "`n"
        [IO.File]::WriteAllText((Join-Path $seed 'a.txt'), "$text`n", $utf8)
        Invoke-FixtureGit $seed @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $seed @('add', '-A')
        Invoke-FixtureGit $seed @('commit', '-q', '-m', 'seed')
        Invoke-FixtureGit $seed @('remote', 'add', 'origin', ([Uri]$remote).AbsoluteUri)
        Invoke-FixtureGit $seed @('push', '-q', 'origin', 'main')
        Invoke-FixtureGit $seed @('mv', 'a.txt', 'r.txt')
        [IO.File]::WriteAllText((Join-Path $seed 'r.txt'), "$text`none more line`n", $utf8)
        Invoke-FixtureGit $seed @('commit', '-q', '-am', 'rename and edit')
        Invoke-FixtureGit $seed @('push', '-q', 'origin', 'main')
        Invoke-FixtureGit $fixtures @('clone', '-q', '--filter=blob:none', ([Uri]$remote).AbsoluteUri, 'tree-git-partial')
        $clone = Join-Path $fixtures 'tree-git-partial'
        # The index keeps the renamed file while HEAD goes back one commit, so rename detection would need the old blob,
        # which this clone never downloaded.
        Invoke-FixtureGit $clone @('reset', '-q', '--soft', 'HEAD~1')
        # Set last: an upload-pack that leaves a marker before it serves, so any fetch shows.
        $marker = (Join-Path $runRoot 'git-upload-pack-marker.txt').Replace('\', '/')
        $uploadPack = Join-Path $runRoot 'git-upload-pack-marker.sh'
        [IO.File]::WriteAllText($uploadPack, "#!/bin/sh`necho upload-pack >> $marker`nexec git-upload-pack ""`$@""`n", $utf8)
        Invoke-FixtureGit $clone @('config', 'remote.origin.uploadpack', $uploadPack.Replace('\', '/'))
        $packDirectory = Join-Path $clone '.git\objects\pack'
        $packs = @([IO.Directory]::GetFiles($packDirectory, '*.pack')).Count
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $clone)
        if ([IO.File]::Exists($marker) -or @([IO.Directory]::GetFiles($packDirectory, '*.pack')).Count -ne $packs) {
            throw "Check fetched from the partial clone's remote: $($response.stdout)"
        }
        Assert-Refused $response 'git-unsaved-work'
        $work = @($response.json.gitUnsavedWork)
        if ($work.Count -ne 1 -or $work[0].workTree -ne $clone -or (@($work[0].uncommittedPaths) -join '|') -ne 'a.txt|r.txt') {
            throw "The staged rename was not counted: $($response.stdout)"
        }
    }

    Assert-Case 'check reads work trees whose git directory lives elsewhere: one that core.worktree names and a linked worktree' {
        $remote = Join-Path $fixtures 'git-remote-worktrees.git'
        Invoke-FixtureGit $fixtures @('init', '-q', '--bare', '-b', 'main', $remote)
        # A git directory and the work tree its core.worktree names, side by side in the target.
        $holder = Join-Path $fixtures 'tree-git-coreworktree'
        $store = Join-Path $holder 'store'
        $src = Join-Path $holder 'src'
        [void][IO.Directory]::CreateDirectory($src)
        [IO.File]::WriteAllText((Join-Path $src 'a.txt'), 'a', $utf8)
        Invoke-FixtureGit $holder @("--git-dir=$store", "--work-tree=$src", 'init', '-q', '-b', 'main')
        Invoke-FixtureGit $src @("--git-dir=$store", 'add', '-A')
        Invoke-FixtureGit $src @("--git-dir=$store", 'commit', '-q', '-m', 'fixture')
        Invoke-FixtureGit $src @("--git-dir=$store", 'remote', 'add', 'origin', ([Uri]$remote).AbsoluteUri)
        Invoke-FixtureGit $src @("--git-dir=$store", 'push', '-q', 'origin', 'main')
        $clean = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $holder)
        if ($clean.exitCode -ne 0 -or $clean.json.status -ne 'checked') { throw "Check refused a clean work tree that core.worktree names: $($clean.stdout)" }
        [IO.File]::WriteAllText((Join-Path $src 'a.txt'), 'edited', $utf8)
        $dirty = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $holder)
        Assert-Refused $dirty 'git-unsaved-work'
        $work = @($dirty.json.gitUnsavedWork)
        if ($work.Count -ne 1 -or $work[0].workTree -ne $src -or (@($work[0].uncommittedPaths) -join '|') -ne 'a.txt') {
            throw "The work tree that core.worktree names was not read: $($dirty.stdout)"
        }
        # A linked worktree keeps its HEAD in the main repository, which stays; once the worktree folder is gone, git
        # worktree prune drops that HEAD and with it a commit nothing else holds.
        $mainRemote = Join-Path $fixtures 'git-remote-linked.git'
        Invoke-FixtureGit $fixtures @('init', '-q', '--bare', '-b', 'main', $mainRemote)
        $main = New-Tree 'git-linked-main'
        Invoke-FixtureGit $main @('init', '-q', '-b', 'main')
        Invoke-FixtureGit $main @('add', '-A')
        Invoke-FixtureGit $main @('commit', '-q', '-m', 'fixture')
        Invoke-FixtureGit $main @('remote', 'add', 'origin', ([Uri]$mainRemote).AbsoluteUri)
        Invoke-FixtureGit $main @('push', '-q', 'origin', 'main')
        $linked = Join-Path $fixtures 'tree-git-linked'
        Invoke-FixtureGit $main @('worktree', 'add', '-q', '--detach', $linked)
        $linkedClean = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $linked)
        if ($linkedClean.exitCode -ne 0 -or $linkedClean.json.status -ne 'checked') { throw "Check refused a clean linked worktree: $($linkedClean.stdout)" }
        [IO.File]::WriteAllText((Join-Path $linked 'a.txt'), 'only here', $utf8)
        Invoke-FixtureGit $linked @('commit', '-q', '-am', 'detached in the linked worktree')
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $linked)
        Assert-Refused $response 'git-unsaved-work'
        $linkedWork = @($response.json.gitUnsavedWork)
        if ($linkedWork.Count -ne 1 -or $linkedWork[0].workTree -ne $linked -or $linkedWork[0].headOnlyCommits -ne 1 -or $linkedWork[0].uncommitted -ne 0) {
            throw "The commit only the linked worktree's HEAD holds was not counted: $($response.stdout)"
        }
    }

    Assert-Case 'check reports a recyclable tree and writes no evidence' {
        $tree = New-Tree 'tree-check'
        $before = @(Get-ChildItem -LiteralPath $entryEvidence -Recurse).Count
        if ($resetBinSettings -and (Test-BinSettings)) {
            $settings = Get-ItemProperty -LiteralPath $binSettingsKey
            $binSettingsCheck.removed = [ordered]@{ MaxCapacity = $settings.MaxCapacity; NukeOnDelete = $settings.NukeOnDelete }
            Remove-Item -LiteralPath $binSettingsKey -Recurse
            $binSettingsCheck.reset = $true
        }
        $binSettingsCheck.beforeCheck = Test-BinSettings
        $response = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $tree)
        $binSettingsCheck.afterCheck = Test-BinSettings
        if ($response.exitCode -ne 0 -or $response.json.status -ne 'checked' -or $response.stderr) { throw "Check failed: $($response.stdout)" }
        if ($response.json.fileCount -ne 2 -or $response.json.directoryCount -ne 2 -or $response.json.totalBytes -ne 1029) { throw 'Check totals changed.' }
        if (@($response.json.topLevel).Count -ne 3 -or $response.json.ContainsKey('planPath')) { throw 'Check did not report the top level, or reported a plan.' }
        if (@(Get-ChildItem -LiteralPath $entryEvidence -Recurse).Count -ne $before) { throw 'Check wrote evidence.' }
    }

    Assert-Case 'plan writes the exact manifest pinned by the plan hash' {
        $tree = New-Tree 'tree-plan'
        $response = Invoke-Plan $tree
        if ($response.exitCode -ne 0 -or $response.json.status -ne 'planned' -or $response.stderr) { throw "Plan failed: $($response.stdout)" }
        $planPath = $response.json.planPath
        if ((Split-Path -Parent (Split-Path -Parent $planPath)) -ne $entryEvidence) { throw 'plan.json is not directly under a run directory.' }
        if ((Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash -ne $response.json.planSha256) { throw 'planSha256 is not the plan file hash.' }
        $plan = [IO.File]::ReadAllText($planPath) | ConvertFrom-Json -AsHashtable
        if ([string]::Join('|', $plan.manifest) -cne [string]::Join('|', $expectedManifest)) { throw 'The manifest is not exact.' }
        if ($plan.target -ne $tree -or $plan.fileCount -ne 2 -or $plan.directoryCount -ne 2 -or $plan.totalBytes -ne 1029) { throw 'Plan totals changed.' }
        if ($plan.authorization -cne 'test fixture created by this run' -or $plan.purpose -cne 'managed recycle test') { throw 'Plan lost its authorization.' }
        if ($plan.allowInternalHardLinks -ne $false) { throw 'A plan without the switch did not record it as off.' }
        $single = Invoke-Plan (Join-Path $tree 'a.txt')
        $singlePlan = [IO.File]::ReadAllText($single.json.planPath) | ConvertFrom-Json -AsHashtable
        if ($single.json.kind -ne 'file' -or [string]::Join('|', $singlePlan.manifest) -cne "F`t`t5") { throw 'A single-file plan is not exact.' }
        $script:planned = $response.json
    }

    Assert-Case 'apply requires confirmation, the approved hash and a plan inside its evidence root' {
        if (-not $script:planned) { throw 'No plan from the previous case.' }
        $plan = $script:planned
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $plan.planPath, '-ApprovedPlanSha256', $plan.planSha256)) 'confirm-recycle-required'
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $plan.planPath, '-ApprovedPlanSha256', ('0' * 64), '-ConfirmRecycle')) 'plan-sha256-mismatch'
        $outside = Join-Path $fixtures 'plan.json'
        [IO.File]::Copy($plan.planPath, $outside)
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $outside, '-ApprovedPlanSha256', $plan.planSha256, '-ConfirmRecycle')) 'plan-outside-evidence-root'
        if (-not [IO.Directory]::Exists($plan.target)) { throw 'A refused apply touched the target.' }
    }

    Assert-Case 'apply refuses an expired plan' {
        $plan = [IO.File]::ReadAllText($script:planned.planPath) | ConvertFrom-Json -AsHashtable
        $plan.createdUnixMs = [DateTimeOffset]::UtcNow.AddMinutes(-31).ToUnixTimeMilliseconds()
        $runDir = Join-Path $entryEvidence 'expired-plan'
        [void][IO.Directory]::CreateDirectory($runDir)
        $bytes = $utf8.GetBytes(($plan | ConvertTo-Json -Depth 6))
        [IO.File]::WriteAllBytes((Join-Path $runDir 'plan.json'), $bytes)
        $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', (Join-Path $runDir 'plan.json'), '-ApprovedPlanSha256', $hash, '-ConfirmRecycle')) 'plan-expired'
    }

    Assert-Case 'apply records a changed tree once and refuses to replay the plan' {
        $tree = New-Tree 'tree-drift'
        $planned = Invoke-Plan $tree
        if ($planned.exitCode -ne 0) { throw "Plan failed: $($planned.stdout)" }
        [IO.File]::WriteAllText((Join-Path $tree 'extra.txt'), 'drift', $utf8)
        $apply = @('-Mode', 'Apply', '-PlanPath', $planned.json.planPath, '-ApprovedPlanSha256', $planned.json.planSha256, '-ConfirmRecycle')
        Assert-Refused (Invoke-Entry $apply) 'manifest-changed'
        $recorded = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $planned.json.planPath) 'result.json')) | ConvertFrom-Json -AsHashtable
        if ($recorded.reason -ne 'manifest-changed' -or -not [IO.File]::Exists((Join-Path $tree 'extra.txt'))) { throw 'The drift refusal was not recorded or touched the tree.' }
        Assert-Refused (Invoke-Entry $apply) 'plan-already-applied'
    }

    Assert-Case 'plan records -AllowInternalHardLinks and apply rechecks the tree with it' {
        $tree = New-Tree 'tree-internal-plan'
        $null = New-Item -ItemType HardLink -Path (Join-Path $tree 'sub\a-twin.txt') -Target (Join-Path $tree 'a.txt')
        $planned = Invoke-Entry @('-Mode', 'Plan', '-TargetPath', $tree, '-Purpose', 'managed recycle test', '-Authorization', 'test fixture created by this run', '-AllowInternalHardLinks')
        if ($planned.exitCode -ne 0 -or $planned.json.status -ne 'planned' -or $planned.stderr) { throw "Plan failed: $($planned.stdout)" }
        $plan = [IO.File]::ReadAllText($planned.json.planPath) | ConvertFrom-Json -AsHashtable
        if ($plan.allowInternalHardLinks -ne $true -or $plan.internalHardLinkFiles -ne 2) { throw 'The plan did not record the internal hard links.' }
        # Drift after the plan: refusing for the drift rather than for the hard links proves Apply reran the preflight with the plan's setting.
        [IO.File]::WriteAllText((Join-Path $tree 'extra.txt'), 'drift', $utf8)
        Assert-Refused (Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $planned.json.planPath, '-ApprovedPlanSha256', $planned.json.planSha256, '-ConfirmRecycle')) 'manifest-changed'
    }

    if ($SkipLiveRecycle) { $cases.Add([pscustomobject]@{ name = $liveCase; status = 'skipped'; reason = 'SkipLiveRecycle' }) }
    else {
        Assert-Case $liveCase {
            $tree = New-Tree 'tree-live'
            $planned = Invoke-Plan $tree
            if ($planned.exitCode -ne 0) { throw "Plan failed: $($planned.stdout)" }
            $applied = Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $planned.json.planPath, '-ApprovedPlanSha256', $planned.json.planSha256, '-ConfirmRecycle')
            if ($applied.exitCode -ne 0 -or $applied.json.status -ne 'recycled' -or $applied.stderr) { throw "Recycle failed: $($applied.stdout)" }
            $record = $applied.json.binRecord
            $binDir = 'D:\$Recycle.Bin\' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + '\'
            if ([IO.Directory]::Exists($tree) -or -not [IO.Directory]::Exists($record.contentPath) -or -not [IO.File]::Exists($record.indexPath) -or
                -not $record.indexPath.StartsWith($binDir, [StringComparison]::OrdinalIgnoreCase)) { throw 'The bin record does not match the recycled tree.' }
            $saved = [IO.File]::ReadAllText($applied.json.resultPath) | ConvertFrom-Json -AsHashtable
            if ($saved.status -ne 'recycled' -or $saved.binManifestSha256 -ne $planned.json.manifestSha256) { throw 'result.json does not prove the bin copy.' }
            # The second tree's readback walks every $I record: the first tree's, held here without sharing, and a decoy
            # for another path dated after every real record, which only the original-path match rules out.
            $second = New-Tree 'tree-live-second'
            $secondPlanned = Invoke-Plan $second
            if ($secondPlanned.exitCode -ne 0) { throw "Plan failed: $($secondPlanned.stdout)" }
            $lock = Invoke-BinStep { [IO.File]::Open($record.indexPath, 'Open', 'Read', 'None') }
            $decoy = $null
            try {
                $decoy = New-BinDecoy $binDir (Join-Path $fixtures 'decoy')
                $secondApplied = Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $secondPlanned.json.planPath, '-ApprovedPlanSha256', $secondPlanned.json.planSha256, '-ConfirmRecycle')
            }
            finally {
                $lock.Dispose()
                if ($decoy) { Invoke-BinStep { [IO.File]::Move($decoy, (Join-Path $runRoot 'restored-bin-decoy.bin')) } }
            }
            [IO.Directory]::Move($record.contentPath, $tree)
            Invoke-BinStep { [IO.File]::Move($record.indexPath, (Join-Path $runRoot 'restored-bin-index.bin')) }
            if ($secondApplied.exitCode -ne 0 -or $secondApplied.json.status -ne 'recycled' -or $secondApplied.stderr) { throw "Recycle past a locked record failed: $($secondApplied.stdout)" }
            if (@($secondApplied.json.unreadableBinRecords) -notcontains $record.indexPath) { throw 'The locked record was not reported as skipped.' }
            $secondRecord = $secondApplied.json.binRecord
            if ($secondRecord.indexPath -eq $decoy) { throw 'The readback took the decoy record for another path.' }
            [IO.Directory]::Move($secondRecord.contentPath, $second)
            Invoke-BinStep { [IO.File]::Move($secondRecord.indexPath, (Join-Path $runRoot 'restored-bin-index-second.bin')) }
            $replanned = Invoke-Plan $tree
            if ($replanned.exitCode -ne 0 -or $replanned.json.manifestSha256 -ne $planned.json.manifestSha256) { throw 'The restored tree differs from the plan.' }
            $replanned = Invoke-Plan $second
            if ($replanned.exitCode -ne 0 -or $replanned.json.manifestSha256 -ne $secondPlanned.json.manifestSha256) { throw 'The restored second tree differs from its plan.' }
            # Both names of an internal hard link move into the bin with the tree and come back still linked.
            $linked = New-Tree 'tree-live-internal-hardlink'
            $null = New-Item -ItemType HardLink -Path (Join-Path $linked 'sub\a-twin.txt') -Target (Join-Path $linked 'a.txt')
            $linkedPlanned = Invoke-Entry @('-Mode', 'Plan', '-TargetPath', $linked, '-Purpose', 'managed recycle test', '-Authorization', 'test fixture created by this run', '-AllowInternalHardLinks')
            if ($linkedPlanned.exitCode -ne 0) { throw "Plan failed: $($linkedPlanned.stdout)" }
            $linkedApplied = Invoke-Entry @('-Mode', 'Apply', '-PlanPath', $linkedPlanned.json.planPath, '-ApprovedPlanSha256', $linkedPlanned.json.planSha256, '-ConfirmRecycle')
            if ($linkedApplied.exitCode -ne 0 -or $linkedApplied.json.status -ne 'recycled' -or $linkedApplied.stderr) { throw "Recycle with internal hard links failed: $($linkedApplied.stdout)" }
            $linkedRecord = $linkedApplied.json.binRecord
            [IO.Directory]::Move($linkedRecord.contentPath, $linked)
            Invoke-BinStep { [IO.File]::Move($linkedRecord.indexPath, (Join-Path $runRoot 'restored-bin-index-internal-hardlink.bin')) }
            $rechecked = Invoke-Entry @('-Mode', 'Check', '-TargetPath', $linked, '-AllowInternalHardLinks')
            if ($rechecked.exitCode -ne 0 -or $rechecked.json.internalHardLinkFiles -ne 2) { throw 'The restored tree lost its internal hard links.' }
        }
    }
}
finally {
    # Leave fixtures as evidence, minus the two shapes later tools trip on: junction links and a path over MAX_PATH.
    foreach ($link in $junctions) { if ([IO.Directory]::Exists($link)) { [IO.Directory]::Delete($link) } }
    if ($longFile -and [IO.File]::Exists($longFile)) { [IO.File]::Move($longFile, (Join-Path $longTree 'long-name-renamed.txt')) }
}

$failed = @($cases | Where-Object status -eq 'failed')
$skipped = @($cases | Where-Object status -eq 'skipped')
$report = [ordered]@{
    status = if ($failed.Count) { 'failed' } elseif ($skipped.Count) { 'passed-with-skips' } else { 'passed' }
    cases = $cases.Count
    failures = $failed.Count
    skipped = $skipped.Count
    fixture = $runRoot
    binSettingsAtStart = $binSettingsAtStart
    binSettingsCheck = $binSettingsCheck
    runtime = $PSVersionTable.PSVersion.ToString()
    entrySha256 = (Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash
    testSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
    results = $cases.ToArray()
}
$json = $report | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $runRoot 'ManagedRecycle-results.json'), $json, $utf8)
$json
if ($failed.Count) { exit 1 }
exit 0
