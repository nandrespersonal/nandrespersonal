$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Invoke-PrivateRepoStaging.ps1'
$testRoot = Join-Path $env:TEMP "private-repo-staging-test-$([guid]::NewGuid().ToString('N'))"
$reposRoot = Join-Path $testRoot 'repos'
$stateRoot = Join-Path $testRoot 'state'

function New-TestRepository {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Files
    )

    $path = Join-Path $reposRoot $Name
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    git -C $path init --quiet
    git -C $path config user.name 'Staging Test'
    git -C $path config user.email 'staging-test@example.invalid'
    foreach ($entry in $Files.GetEnumerator()) {
        $filePath = Join-Path $path $entry.Key
        New-Item -ItemType Directory -Path (Split-Path -Parent $filePath) -Force | Out-Null
        Set-Content -LiteralPath $filePath -Value $entry.Value -Encoding utf8
    }
    git -C $path add .
    git -C $path commit --quiet -m 'Fixture'
    return $path
}

try {
    New-Item -ItemType Directory -Path $reposRoot -Force | Out-Null
    $safePath = New-TestRepository -Name 'safe-project' -Files @{
        'README.md' = '# Safe project https://github.com/nandres_microsoft/safe-project'
        'src/app.txt' = 'safe content'
    }
    $blockedPath = New-TestRepository -Name 'blocked-project' -Files @{
        'README.md' = '# Blocked project'
        '.env' = 'EXAMPLE_ONLY=true'
    }
    $identityPath = New-TestRepository -Name 'identity-project' -Files @{
        'README.md' = '# Identity project'
        'src/owner.txt' = 'owner=nandres_microsoft'
    }

    $inventory = & $scriptPath -Mode Inventory -LocalRoot $reposRoot -StateRoot $stateRoot
    if (@($inventory.repositories).Count -ne 3) {
        throw 'Inventory did not find all fixture repositories.'
    }

    $manifestPath = Join-Path $stateRoot 'repositories.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($repository in $manifest.repositories) {
        $repository.decision = 'stage_approved'
        $repository.ownershipApproved = $true
        $repository.stageApproved = $true
        $repository.contentTransformApproved = $true
    }
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    $safeHeadBefore = git -C $safePath rev-parse HEAD
    $safeResult = & $scriptPath -Mode Stage -StateRoot $stateRoot -ManifestPath $manifestPath -RepositoryName 'safe-project'
    if ($safeResult.validation.status -ne 'passed') {
        throw 'Safe fixture did not pass validation.'
    }
    $stagedReadme = Get-Content -LiteralPath (Join-Path $safeResult.snapshotPath 'README.md') -Raw
    if ($stagedReadme -notlike '*https://github.com/nandrespersonal/safe-project*' -or $stagedReadme -like '*nandres_microsoft*') {
        throw 'Default GitHub owner transformation was not applied.'
    }
    if (@($safeResult.transformations).Count -ne 1 -or $safeResult.transformations[0].replacements -ne 1) {
        throw 'Transformation audit did not record the expected replacement.'
    }
    $sourceReadme = Get-Content -LiteralPath (Join-Path $safePath 'README.md') -Raw
    if ($sourceReadme -notlike '*nandres_microsoft*') {
        throw 'Source content was unexpectedly transformed.'
    }
    if ((git -C $safePath rev-parse HEAD) -cne $safeHeadBefore -or @(git -C $safePath status --porcelain).Count -ne 0) {
        throw 'Safe source repository changed during staging.'
    }

    $blocked = $false
    try {
        & $scriptPath -Mode Stage -StateRoot $stateRoot -ManifestPath $manifestPath -RepositoryName 'blocked-project' | Out-Null
    }
    catch {
        $blocked = $_.Exception.Message -like "Staged snapshot validation blocked*"
    }
    if (-not $blocked) {
        throw 'Sensitive-path fixture was not blocked.'
    }
    if (@(git -C $blockedPath status --porcelain).Count -ne 0) {
        throw 'Blocked source repository changed during staging.'
    }

    $identityBlocked = $false
    try {
        & $scriptPath -Mode Stage -StateRoot $stateRoot -ManifestPath $manifestPath -RepositoryName 'identity-project' | Out-Null
    }
    catch {
        $identityBlocked = $_.Exception.Message -like "Staged snapshot validation blocked*"
    }
    if (-not $identityBlocked) {
        throw 'Unresolved corporate identity fixture was not blocked.'
    }
    if ((Get-Content -LiteralPath (Join-Path $identityPath 'src/owner.txt') -Raw) -notlike '*nandres_microsoft*') {
        throw 'Identity source repository content changed during staging.'
    }

    Write-Output 'PRIVATE_REPO_STAGING_TESTS_PASSED'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
