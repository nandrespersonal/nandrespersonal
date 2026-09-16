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
        'README.md' = '# Safe project'
        'src/app.txt' = 'safe content'
    }
    $blockedPath = New-TestRepository -Name 'blocked-project' -Files @{
        'README.md' = '# Blocked project'
        '.env' = 'EXAMPLE_ONLY=true'
    }

    $inventory = & $scriptPath -Mode Inventory -LocalRoot $reposRoot -StateRoot $stateRoot
    if (@($inventory.repositories).Count -ne 2) {
        throw 'Inventory did not find both fixture repositories.'
    }

    $manifestPath = Join-Path $stateRoot 'repositories.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($repository in $manifest.repositories) {
        $repository.decision = 'stage_approved'
        $repository.ownershipApproved = $true
        $repository.stageApproved = $true
    }
    $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    $safeHeadBefore = git -C $safePath rev-parse HEAD
    $safeResult = & $scriptPath -Mode Stage -StateRoot $stateRoot -ManifestPath $manifestPath -RepositoryName 'safe-project'
    if ($safeResult.validation.status -ne 'passed') {
        throw 'Safe fixture did not pass validation.'
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

    Write-Output 'PRIVATE_REPO_STAGING_TESTS_PASSED'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
