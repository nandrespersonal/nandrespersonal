# Private Repository Staging

This directory defines a safe path for reflecting approved local repositories in the `nandrespersonal` GitHub account without modifying the source repositories.

## Core model

```text
local repository (read-only)
  -> tracked HEAD snapshot
  -> isolated local staging directory
  -> source-safety validation
  -> explicit per-repository approval
  -> private nandrespersonal/staging-<slug> repository
```

The staging destination is intentionally separate from existing public repositories. GitHub does not support private branches inside a public repository, so a separate private repository is required when the staged snapshot must remain private.

## Non-negotiable controls

- Source repositories are read-only.
- No source remote is added, removed, renamed, or repointed.
- Only tracked files from the selected commit are exported.
- Original Git history is excluded by default.
- Machine-specific inventory and reports are not committed.
- Every repository defaults to blocked until ownership and source-safety review are explicit.
- Every new GitHub repository is private.
- Existing public repositories are not changed automatically.
- GitHub identity must resolve through the API as exactly `nandrespersonal`.
- Git pushes use a command-local personal credential helper, never the app-injected default helper.
- Force pushes, deletes, visibility changes, and automatic public promotion are prohibited.

## Phases

1. **Inventory:** Record repository metadata and candidate destination names locally.
2. **Stage:** Export a tracked snapshot into an isolated directory.
3. **Validate:** Check ownership approval, sensitive paths, secret-like content, large files, submodules, and Git LFS.
4. **Pilot:** Publish one approved snapshot to a private `staging-` repository and verify it.
5. **Expand:** Approve and publish repositories individually.
6. **Schedule:** Run the same fail-closed process under a single-run lock.

## Repository decision states

| State | Meaning |
| --- | --- |
| `blocked` | No staging or publication is allowed. |
| `review_required` | Metadata is known, but ownership or source-safety review is incomplete. |
| `stage_approved` | A local snapshot may be created and validated. |
| `publish_approved` | A validated snapshot may be published to its declared private staging repository. |

Private visibility is not evidence that material is safe or authorized to upload. Ownership, confidentiality, licensing, and source-safety approval remain separate gates.

## Default destination

`nandrespersonal/staging-<local-folder-slug>`

This avoids collisions with existing public repositories and keeps later promotion a deliberate decision.

## Implemented local-only commands

Inventory repositories into ignored local state:

```powershell
.\publishing\Invoke-PrivateRepoStaging.ps1 -Mode Inventory
```

Review `publishing\state\repositories.json`, then explicitly change an entry to:

```json
{
  "decision": "stage_approved",
  "ownershipApproved": true,
  "stageApproved": true,
  "publishApproved": false
}
```

Create and validate a tracked snapshot:

```powershell
.\publishing\Invoke-PrivateRepoStaging.ps1 `
  -Mode Stage `
  -RepositoryName "approved-repository"
```

The script currently contains **no GitHub repository creation or push path**. It inventories metadata, exports `HEAD` with `git archive`, validates the isolated snapshot, writes an ignored report, and confirms that the source repository remained unchanged.

Validation blocks:

- dirty source worktrees;
- source commits that changed after inventory;
- unapproved repositories;
- non-private destination declarations;
- tracked sensitive file names;
- private-key, token, access-key, or assigned-secret patterns;
- files larger than 50 MB;
- submodules;
- Git LFS pointers;
- staged file lists that differ from the tracked source snapshot.
