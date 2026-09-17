Set-StrictMode -Version Latest

function New-CodexSafeTreeDeleteRetiredEvidenceRootFixture {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot
    )

    $scratchHelperPath = Join-Path $PSScriptRoot 'New-CodexSafeTreeDeleteTestScratchRoot.ps1'
    . $scratchHelperPath
    $scratchRoot = New-CodexSafeTreeDeleteTestScratchRoot `
        -ProjectRoot $ProjectRoot `
        -SuiteName 'retiredevidenceroot'
    [void][IO.Directory]::CreateDirectory($scratchRoot)

    $capabilityRoot = Join-Path $scratchRoot 'run-evidence-analog'
    $protectedEvidenceRoot = Join-Path $capabilityRoot 'safe-tree-delete'
    $approvedA = Join-Path $capabilityRoot 'approved-retired-evidence-a'
    $approvedB = Join-Path $capabilityRoot 'approved-retired-evidence-b'
    $approvedC = Join-Path $capabilityRoot 'approved-retired-evidence-c'
    $approvedD = Join-Path $capabilityRoot 'approved-retired-evidence-d'
    $unregisteredSibling = Join-Path $capabilityRoot 'unregistered-sibling'

    foreach ($dir in @(
            $protectedEvidenceRoot, $approvedA, $approvedB, $approvedC, $approvedD, $unregisteredSibling
        )) {
        [void][IO.Directory]::CreateDirectory($dir)
        $leaf = Split-Path -Leaf $dir
        [IO.File]::WriteAllText(
            (Join-Path $dir 'payload.txt'),
            "payload-$leaf",
            [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::WriteAllText(
        (Join-Path $approvedD 'z-interrupt.txt'),
        'payload-approved-retired-evidence-d-interrupt',
        [Text.UTF8Encoding]::new($false))

    $grantPolicyPath = Join-Path $scratchRoot 'grant-policy.json'
    $grantPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'fixture-run-evidence-analog'
                capabilityRoot = $capabilityRoot
                minimumDescendantDepth = 2
                rootDeletionPurpose = 'none'
                deniedExactPaths = [string[]]@($protectedEvidenceRoot)
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-a'
                capabilityRoot = $approvedA
                minimumDescendantDepth = 0
                rootDeletionPurpose = 'retired-evidence-root'
                deniedExactPaths = [string[]]@()
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-b'
                capabilityRoot = $approvedB
                minimumDescendantDepth = 0
                rootDeletionPurpose = 'retired-evidence-root'
                deniedExactPaths = [string[]]@()
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-c'
                capabilityRoot = $approvedC
                minimumDescendantDepth = 0
                rootDeletionPurpose = 'retired-evidence-root'
                deniedExactPaths = [string[]]@()
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-d'
                capabilityRoot = $approvedD
                minimumDescendantDepth = 0
                rootDeletionPurpose = 'retired-evidence-root'
                deniedExactPaths = [string[]]@()
            }
        )
    }
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($grantPolicyPath, ($grantPolicy | ConvertTo-Json -Depth 10), $utf8)

    $operationEvidenceRoot = Join-Path $scratchRoot 'operation-evidence'
    [void][IO.Directory]::CreateDirectory($operationEvidenceRoot)
    $parentOnlyPolicyPath = Join-Path $scratchRoot 'parent-only-policy.json'
    $parentOnlyPolicy = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-policy'
        schemaVersion = 4
        entries = @(
            [pscustomobject][ordered]@{
                id = 'fixture-run-evidence-analog'
                capabilityRoot = $capabilityRoot
                minimumDescendantDepth = 2
                rootDeletionPurpose = 'none'
                deniedExactPaths = [string[]]@($protectedEvidenceRoot)
            }
        )
    }
    [IO.File]::WriteAllText($parentOnlyPolicyPath, ($parentOnlyPolicy | ConvertTo-Json -Depth 10), $utf8)

    $libraryPath = Join-Path $ProjectRoot 'scripts/lib/CodexSafeTreeDelete.ps1'
    . $libraryPath
    $originalIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $approvedB
    $originalHex = [BitConverter]::ToString([byte[]]$originalIdentity.FileId128)
    $payloadPath = Join-Path $approvedB 'payload.txt'
    $payloadText = [IO.File]::ReadAllText($payloadPath)
    [IO.Directory]::Delete($approvedB, $true)
    [void][IO.Directory]::CreateDirectory($approvedB)
    [IO.File]::WriteAllText($payloadPath, $payloadText, $utf8)
    $rebuiltIdentity = Get-CodexSafeTreeDeleteFileIdentityV2 -LiteralPath $approvedB
    $rebuiltHex = [BitConverter]::ToString([byte[]]$rebuiltIdentity.FileId128)
    if ($originalHex -ceq $rebuiltHex) {
        throw "rebuild fixture 未能改变目录身份: $approvedB fileId=$originalHex"
    }

    $manifestPath = Join-Path $scratchRoot 'fixture-manifest.json'
    $rebuild = [pscustomobject][ordered]@{
        path = $approvedB
        originalFileIdHex = $originalHex
        rebuiltFileIdHex = $rebuiltHex
        identitiesDiffer = $true
    }
    $manifest = [pscustomobject][ordered]@{
        artifactType = 'env-governance.codex-safe-tree-delete-retired-evidence-root-fixture'
        schemaVersion = 1
        scratchRoot = $scratchRoot
        capabilityRoot = $capabilityRoot
        protectedEvidenceRoot = $protectedEvidenceRoot
        grantPolicyPath = $grantPolicyPath
        parentOnlyPolicyPath = $parentOnlyPolicyPath
        operationEvidenceRoot = $operationEvidenceRoot
        approvedTargets = @(
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-a'
                path = $approvedA
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-b'
                path = $approvedB
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-c'
                path = $approvedC
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-d'
                path = $approvedD
            }
        )
        unregisteredSibling = [pscustomobject][ordered]@{
            path = $unregisteredSibling
        }
        rebuild = $rebuild
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 10), $utf8)

    return [pscustomobject][ordered]@{
        scratchRoot = $scratchRoot
        capabilityRoot = $capabilityRoot
        protectedEvidenceRoot = $protectedEvidenceRoot
        grantPolicyPath = $grantPolicyPath
        parentOnlyPolicyPath = $parentOnlyPolicyPath
        operationEvidenceRoot = $operationEvidenceRoot
        manifestPath = $manifestPath
        approvedTargets = @(
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-a'
                path = $approvedA
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-b'
                path = $approvedB
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-c'
                path = $approvedC
            },
            [pscustomobject][ordered]@{
                id = 'approved-retired-evidence-d'
                path = $approvedD
            }
        )
        unregisteredSibling = [pscustomobject][ordered]@{
            path = $unregisteredSibling
        }
        rebuild = $rebuild
    }
}
