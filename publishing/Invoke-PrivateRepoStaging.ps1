[CmdletBinding()]
param(
    [ValidateSet('Inventory', 'Stage', 'Validate')]
    [string]$Mode = 'Inventory',

    [string]$LocalRoot = (Join-Path $env:USERPROFILE 'AIRepos'),

    [string]$StateRoot = (Join-Path $PSScriptRoot 'state'),

    [string]$ManifestPath,

    [string]$RepositoryName,

    [string]$StagePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [string[]]$GitArguments
    )

    $output = & git -C $RepositoryPath @GitArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArguments -join ' ') failed in '$RepositoryPath': $($output -join [Environment]::NewLine)"
    }

    return @($output | ForEach-Object { "$_" })
}

function ConvertTo-SafeSlug {
    param([Parameter(Mandatory)][string]$Value)

    $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-'
    $slug = $slug.Trim('-', '.', '_')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw "Cannot derive a destination slug from '$Value'."
    }

    return $slug
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$resolvedPath' is outside the allowed root '$resolvedRoot'."
    }

    return $resolvedPath
}

function Get-RepositoryInventory {
    param([Parameter(Mandatory)][string]$Root)

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $repositories = foreach ($directory in Get-ChildItem -LiteralPath $resolvedRoot -Directory | Sort-Object Name) {
        if ($directory.Name.StartsWith('.') -or $directory.Name.StartsWith('_')) {
            continue
        }

        if (-not (Test-Path -LiteralPath (Join-Path $directory.FullName '.git'))) {
            continue
        }

        $insideOutput = @(Invoke-Git -RepositoryPath $directory.FullName -GitArguments @('rev-parse', '--is-inside-work-tree'))
        $inside = $insideOutput[0]
        if ($inside -ne 'true') {
            continue
        }

        $origin = ''
        $originOutput = & git -C $directory.FullName remote get-url origin 2>$null
        if ($LASTEXITCODE -eq 0) {
            $origin = "$originOutput"
        }

        $branchOutput = & git -C $directory.FullName branch --show-current 2>$null
        $branch = if ($LASTEXITCODE -eq 0) { "$branchOutput" } else { '' }
        $headOutput = @(Invoke-Git -RepositoryPath $directory.FullName -GitArguments @('rev-parse', 'HEAD'))
        $head = $headOutput[0]
        $dirty = @(& git -C $directory.FullName status --porcelain).Count -gt 0
        $slug = ConvertTo-SafeSlug -Value $directory.Name

        [ordered]@{
            name = $directory.Name
            sourcePath = $directory.FullName
            sourceHead = $head
            sourceBranch = $branch
            sourceOrigin = $origin
            sourceDirty = $dirty
            destinationOwner = 'nandrespersonal'
            destinationName = "staging-$slug"
            visibility = 'private'
            decision = 'review_required'
            ownershipApproved = $false
            stageApproved = $false
            contentTransformApproved = $false
            publishApproved = $false
            contentTransforms = @(
                [ordered]@{
                    from = 'https://github.com/nandres_microsoft/'
                    to = 'https://github.com/nandrespersonal/'
                    rationale = 'Rewrite GitHub HTTPS owner references in the isolated snapshot.'
                },
                [ordered]@{
                    from = 'git@github.com:nandres_microsoft/'
                    to = 'git@github.com:nandrespersonal/'
                    rationale = 'Rewrite GitHub SSH owner references in the isolated snapshot.'
                }
            )
            reviewNotes = ''
        }
    }

    return [ordered]@{
        schemaVersion = '1.0.0'
        generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        localRoot = $resolvedRoot
        repositories = @($repositories)
    }
}

function Get-TransformableFiles {
    param([Parameter(Mandatory)][string]$Root)

    $textExtensions = @(
        '',
        '.config',
        '.cs',
        '.csproj',
        '.css',
        '.go',
        '.html',
        '.ini',
        '.java',
        '.js',
        '.json',
        '.jsx',
        '.md',
        '.props',
        '.ps1',
        '.psd1',
        '.psm1',
        '.py',
        '.rb',
        '.rs',
        '.sh',
        '.sln',
        '.sql',
        '.targets',
        '.toml',
        '.ts',
        '.tsx',
        '.txt',
        '.xml',
        '.yaml',
        '.yml'
    )

    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse |
            Where-Object { $_.Length -le 2MB -and $textExtensions -contains $_.Extension.ToLowerInvariant() }
    )
}

function Invoke-SnapshotTransforms {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][object[]]$Transforms
    )

    $audit = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-TransformableFiles -Root $Root)

    foreach ($transform in $Transforms) {
        $from = "$($transform.from)"
        $to = "$($transform.to)"
        if ([string]::IsNullOrEmpty($from)) {
            throw 'Content transformation source text cannot be empty.'
        }
        if ($from -ceq $to) {
            throw "Content transformation '$from' has identical source and destination values."
        }

        foreach ($file in $files) {
            $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($null -eq $content -or -not $content.Contains($from, [StringComparison]::Ordinal)) {
                continue
            }

            $count = 0
            $offset = 0
            while (($offset = $content.IndexOf($from, $offset, [StringComparison]::Ordinal)) -ge 0) {
                $count++
                $offset += $from.Length
            }

            $updated = $content.Replace($from, $to, [StringComparison]::Ordinal)
            Set-Content -LiteralPath $file.FullName -Value $updated -Encoding utf8 -NoNewline
            $audit.Add([ordered]@{
                path = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
                from = $from
                to = $to
                replacements = $count
                rationale = "$($transform.rationale)"
            })
        }
    }

    return @($audit)
}

function Get-StagedFindings {
    param([Parameter(Mandatory)][string]$Root)

    $findings = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse)
    $sensitivePatterns = @(
        '.env',
        '.env.*',
        '*.key',
        '*.pem',
        '*.pfx',
        '*.p12',
        'id_rsa*',
        'credentials*.json',
        'secrets.*'
    )

    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')

        if ($file.Length -gt 50MB) {
            $findings.Add([ordered]@{
                type = 'large_file'
                path = $relative
                detail = 'File exceeds the 50 MB staging limit.'
            })
        }

        foreach ($pattern in $sensitivePatterns) {
            if ($file.Name -like $pattern) {
                $findings.Add([ordered]@{
                    type = 'sensitive_path'
                    path = $relative
                    detail = "File name matches blocked pattern '$pattern'."
                })
                break
            }
        }

        if ($file.Name -eq '.gitmodules') {
            $findings.Add([ordered]@{
                type = 'submodule'
                path = $relative
                detail = 'Submodules require an explicit publication decision.'
            })
        }

        if ($file.Length -le 2MB) {
            $extension = $file.Extension.ToLowerInvariant()
            $textExtensions = @('', '.config', '.cs', '.csproj', '.css', '.env', '.go', '.html', '.ini', '.java', '.js', '.json', '.jsx', '.md', '.props', '.ps1', '.psd1', '.psm1', '.py', '.rb', '.rs', '.sh', '.sln', '.sql', '.targets', '.toml', '.ts', '.tsx', '.txt', '.xml', '.yaml', '.yml')
            if ($textExtensions -contains $extension) {
                $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction SilentlyContinue
                if ($null -ne $content) {
                    $checks = @(
                        @{ Type = 'corporate_identity_reference'; Pattern = '(?i)nandres_microsoft'; Detail = 'Unresolved corporate GitHub identity reference detected.' },
                        @{ Type = 'private_key'; Pattern = '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'; Detail = 'Private-key material detected.' },
                        @{ Type = 'github_token'; Pattern = 'gh[pousr]_[A-Za-z0-9]{20,}'; Detail = 'GitHub token-like value detected.' },
                        @{ Type = 'aws_access_key'; Pattern = 'AKIA[0-9A-Z]{16}'; Detail = 'AWS access-key-like value detected.' },
                        @{ Type = 'assigned_secret'; Pattern = '(?i)(client_secret|api[_-]?key|password)\s*[:=]\s*[''"][^''"\r\n]{8,}'; Detail = 'Assigned secret-like value detected.' },
                        @{ Type = 'git_lfs_pointer'; Pattern = '^version https://git-lfs.github.com/spec/v1'; Detail = 'Git LFS pointer requires explicit handling.' }
                    )

                    foreach ($check in $checks) {
                        if ($content -match $check.Pattern) {
                            $findings.Add([ordered]@{
                                type = $check.Type
                                path = $relative
                                detail = $check.Detail
                            })
                        }
                    }
                }
            }
        }
    }

    return @($findings)
}

function Test-StagedSnapshot {
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        [string[]]$ExpectedFiles = @()
    )

    $resolvedSnapshot = (Resolve-Path -LiteralPath $SnapshotPath).Path
    $actualFiles = @(
        Get-ChildItem -LiteralPath $resolvedSnapshot -File -Recurse |
            ForEach-Object { [IO.Path]::GetRelativePath($resolvedSnapshot, $_.FullName).Replace('\', '/') } |
            Sort-Object
    )
    $normalizedExpected = @($ExpectedFiles | ForEach-Object { $_.Replace('\', '/') } | Sort-Object)
    $fileListMatches = $true
    if ($normalizedExpected.Count -gt 0) {
        $differences = @(Compare-Object -ReferenceObject $normalizedExpected -DifferenceObject $actualFiles)
        $fileListMatches = $differences.Count -eq 0
    }

    $findings = @(Get-StagedFindings -Root $resolvedSnapshot)
    if (-not $fileListMatches) {
        $findings += [ordered]@{
            type = 'file_list_mismatch'
            path = '.'
            detail = 'The staged files do not match the tracked source snapshot.'
        }
    }

    return [ordered]@{
        validatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        snapshotPath = $resolvedSnapshot
        fileCount = $actualFiles.Count
        fileListMatches = $fileListMatches
        status = if ($findings.Count -eq 0) { 'passed' } else { 'blocked' }
        findings = @($findings)
    }
}

New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $StateRoot 'repositories.json'
}

$lockPath = Join-Path $StateRoot 'publisher.lock'
$lockStream = $null
try {
    $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $lockWriter = [IO.StreamWriter]::new($lockStream)
    $lockWriter.WriteLine("pid=$PID")
    $lockWriter.WriteLine("startedAt=$([DateTimeOffset]::UtcNow.ToString('o'))")
    $lockWriter.Flush()

    switch ($Mode) {
        'Inventory' {
            $inventory = Get-RepositoryInventory -Root $LocalRoot
            Write-JsonFile -Value $inventory -Path $ManifestPath
            $inventory
        }

        'Stage' {
            if (-not (Test-Path -LiteralPath $ManifestPath)) {
                throw "Manifest '$ManifestPath' does not exist. Run Inventory first."
            }
            if ([string]::IsNullOrWhiteSpace($RepositoryName)) {
                throw 'RepositoryName is required for Stage mode.'
            }

            $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
            $entries = @($manifest.repositories | Where-Object { $_.name -ceq $RepositoryName })
            if ($entries.Count -ne 1) {
                throw "Expected exactly one manifest entry named '$RepositoryName'; found $($entries.Count)."
            }

            $entry = $entries[0]
            if (-not $entry.ownershipApproved -or -not $entry.stageApproved -or $entry.decision -notin @('stage_approved', 'publish_approved')) {
                throw "Repository '$RepositoryName' is not approved for staging."
            }
            if (-not $entry.contentTransformApproved) {
                throw "Repository '$RepositoryName' is not approved for content transformation."
            }
            if ($entry.visibility -ne 'private') {
                throw "Repository '$RepositoryName' does not declare private visibility."
            }

            $sourcePath = Assert-PathWithinRoot -Path $entry.sourcePath -Root $manifest.localRoot
            if (-not (Test-Path -LiteralPath (Join-Path $sourcePath '.git'))) {
                throw "Source '$sourcePath' is not a Git worktree."
            }

            $statusBefore = @(& git -C $sourcePath status --porcelain)
            if ($statusBefore.Count -gt 0) {
                throw "Source repository '$RepositoryName' is not clean; staging is blocked."
            }

            $headBeforeOutput = @(Invoke-Git -RepositoryPath $sourcePath -GitArguments @('rev-parse', 'HEAD'))
            $headBefore = $headBeforeOutput[0]
            if ($entry.sourceHead -and $entry.sourceHead -cne $headBefore) {
                throw "Source HEAD changed after inventory for '$RepositoryName'. Run Inventory again."
            }

            $trackedFiles = @(Invoke-Git -RepositoryPath $sourcePath -GitArguments @('ls-tree', '-r', '--name-only', 'HEAD'))
            $timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
            $stagingRoot = Join-Path $StateRoot 'staging'
            $repositoryStagingRoot = Join-Path $stagingRoot (ConvertTo-SafeSlug -Value $RepositoryName)
            $snapshotPath = Join-Path $repositoryStagingRoot $timestamp
            New-Item -ItemType Directory -Path $snapshotPath -Force | Out-Null
            $archivePath = Join-Path $repositoryStagingRoot "$timestamp.tar"

            Invoke-Git -RepositoryPath $sourcePath -GitArguments @('archive', '--format=tar', '-o', $archivePath, 'HEAD') | Out-Null
            & tar -xf $archivePath -C $snapshotPath
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract snapshot archive '$archivePath'."
            }
            Remove-Item -LiteralPath $archivePath

            $transformAudit = @(Invoke-SnapshotTransforms -Root $snapshotPath -Transforms @($entry.contentTransforms))

            $headAfterOutput = @(Invoke-Git -RepositoryPath $sourcePath -GitArguments @('rev-parse', 'HEAD'))
            $headAfter = $headAfterOutput[0]
            $statusAfter = @(& git -C $sourcePath status --porcelain)
            if ($headAfter -cne $headBefore -or $statusAfter.Count -ne 0) {
                throw "Source repository '$RepositoryName' changed during staging."
            }

            $validation = Test-StagedSnapshot -SnapshotPath $snapshotPath -ExpectedFiles $trackedFiles
            $report = [ordered]@{
                schemaVersion = '1.0.0'
                repositoryName = $RepositoryName
                sourcePath = $sourcePath
                sourceHead = $headBefore
                destinationOwner = $entry.destinationOwner
                destinationName = $entry.destinationName
                visibility = $entry.visibility
                snapshotPath = $snapshotPath
                sourceUnchanged = $true
                transformations = $transformAudit
                validation = $validation
            }
            $reportPath = Join-Path (Join-Path $StateRoot 'reports') "$($RepositoryName)-$timestamp.json"
            Write-JsonFile -Value $report -Path $reportPath
            $report

            if ($validation.status -ne 'passed') {
                throw "Staged snapshot validation blocked '$RepositoryName'. See '$reportPath'."
            }
        }

        'Validate' {
            if ([string]::IsNullOrWhiteSpace($StagePath)) {
                throw 'StagePath is required for Validate mode.'
            }

            Test-StagedSnapshot -SnapshotPath $StagePath
        }
    }
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
    if (Test-Path -LiteralPath $lockPath) {
        Remove-Item -LiteralPath $lockPath
    }
}
