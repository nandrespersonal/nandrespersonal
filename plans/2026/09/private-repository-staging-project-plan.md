# Private Repository Staging

## Status

Phases 1 and 2 implemented and validated: metadata inventory, local approval state, tracked snapshot export, snapshot-only identity abstraction, locking, and fail-closed validation. No GitHub repository creation or source-code upload is authorized by this plan.

## Intake

- **Desired outcome:** Reflect approved local AIRepos projects in the `nandrespersonal` GitHub account without materially changing the local repositories.
- **Why now:** The personal profile has partial coverage, while many local folders share names with repositories under a different GitHub identity.
- **Deliverable:** A deterministic staging workflow that can inventory, export, validate, and later publish approved snapshots as private repositories.
- **Constraints:** Local repositories remain authoritative and read-only to the publisher. Existing public repositories remain unchanged. Corporate or otherwise restricted source is never uploaded without explicit authorization.
- **Definition of done:** Every eligible local repository has a reviewable staging record, approved repositories can be exported without modifying their source, and any GitHub publication is private, identity-verified, non-force, and SHA-verified.

## Intake decision

- **Disposition:** `execute_now`, limited to architecture and local-only staging controls.
- **Rationale:** The need is recurring and cross-repository, but the first phase is reversible and does not require remote mutation.
- **Durable owner:** `nandrespersonal`
- **Immediate executor:** This dedicated personal publishing session.
- **AI authority:** Design and local-only scaffolding. Repository creation and source upload remain gated by per-repository approval.

## Recommended execution path

### Primary path

Use a deterministic PowerShell workflow owned by this repository:

1. Inventory immediate Git repositories under a caller-supplied local root.
2. Store machine-specific inventory only in an ignored local state directory.
3. Require an explicit per-repository decision before staging or publishing.
4. Export the tracked `HEAD` snapshot into a separate staging directory; do not copy `.git`, untracked files, local configuration, or original history.
5. Apply explicitly approved identity transformations only to the staged snapshot and record file-level replacement counts.
6. Run source-safety checks against the staged snapshot and block any remaining corporate identity reference.
7. Publish only approved snapshots to private `nandrespersonal/staging-<slug>` repositories.
8. Use a dedicated personal GitHub CLI profile and a command-local Git credential helper.
9. Verify the remote repository is private and its remote SHA equals the staged commit.

### Fallback path

Produce local snapshot bundles and validation reports without creating GitHub repositories. This preserves reviewability when ownership, privacy, or authorization is unresolved.

### Escalation path

Nick decides whether an approved staging repository should later replace, merge into, or remain separate from an existing public repository. Existing public visibility is never changed automatically.

### Avoid paths

- Adding a second remote to each source repository.
- Repointing existing `origin` remotes.
- Copying complete Git history by default.
- Publishing untracked files, ignored files, submodules, or Git LFS content implicitly.
- Bulk-uploading repositories whose origin or content may be work-owned, confidential, licensed, or otherwise restricted.
- Force pushes, repository deletion, visibility changes, or automated public promotion.

## Naming and visibility

- Every new staging destination is private.
- Default destination: `nandrespersonal/staging-<local-folder-slug>`.
- The prefix prevents collisions with existing public repositories and makes staging intent explicit.
- Existing public repositories remain unchanged until a separate per-repository promotion decision.

## Dependencies and sequencing

1. Build metadata-only inventory and local decision manifest.
2. Add local snapshot export and validation.
3. Pilot with the current personal portfolio repository.
4. Review each remaining repository for ownership, privacy, licensing, secrets, large files, submodules, and Git LFS.
5. Enable private publication for approved entries.
6. Add a single-run lock and scheduled execution only after the pilot is verified.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Work or third-party source is copied to a personal account | Default every repository to blocked; require explicit source-ownership approval. |
| Historical secrets are published | Export only the tracked current snapshot with fresh staging history. |
| Current local work is changed | Treat source repositories as read-only; write only to dedicated staging directories. |
| Existing public repositories are overwritten or made private | Use `staging-` destinations and prohibit automatic visibility changes. |
| Wrong GitHub identity is used | Require API viewer `nandrespersonal` and command-local personal Git credentials before every remote operation. |
| Concurrent sessions publish conflicting state | Use a single-run lock, immutable source SHA capture, dry-run push, and remote-SHA verification. |
| Automation silently skips failures | Fail closed, retain a local report, and continue with no further remote mutation. |

## Verification and closure

- Inventory contains no source contents and is stored outside version control.
- Source repository status and remotes are unchanged after staging.
- Staged file list matches `git archive HEAD`.
- Validation report records the exact source SHA and all blockers.
- GitHub API confirms destination owner and `private=true`.
- A normal non-force dry-run succeeds before publication.
- Published remote SHA equals the staged commit SHA.
- Closure owner: Nick.

## Communication and tracking

- The Markdown plan owns the execution contract.
- The personal portfolio repository owns the publisher design.
- Live run results remain local and source-safe.
- Material scope or authority changes require an updated plan before implementation.

## Next action

Review the ignored local inventory, approve one source-safe repository and its transformation rules, and run the first real local snapshot pilot. Do not create additional GitHub repositories until that pilot report is reviewed.
