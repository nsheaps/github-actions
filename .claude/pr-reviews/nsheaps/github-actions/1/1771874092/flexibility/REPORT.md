# Flexibility Review

**Score: 62/100**

The action provides a solid foundation for the most common use case -- deploying a mono-repo of Docker Compose stacks to a single Arcane environment via HTTP-authenticated git -- and it exposes a good set of inputs with sensible defaults. However, several design choices introduce hard limits that will frustrate users with more complex or non-standard setups: the `maxdepth 2` directory scan, the sync naming scheme that collapses nested paths into a single directory name, the lack of support for SSH key material, the inability to target multiple environments, and the absence of a dry-run or plan mode. The action covers the 80% case well but falls short on the remaining 20% of real-world scenarios.

## Detailed Findings

### Strengths

**1. Dual compose file discovery (good)**
Users can choose between directory scanning (`compose-dir`) and an explicit list (`compose-files`), and these two modes can be combined (action.sh:71-97). This is a well-designed flexibility point -- auto-discovery for convention-based repos, explicit lists for everything else.

**2. Sensible defaults derived from GitHub context (good)**
Branch defaults to `GITHUB_REF_NAME`, repository URL defaults to `https://github.com/${GITHUB_REPOSITORY}.git`, sync name prefix defaults to the repo name (action.sh:10-19). Users deploying from a standard GitHub Actions workflow need to provide only the three required inputs plus at least one compose source to get started.

**3. Every meaningful knob is exposed as an input (good)**
Auto-sync, sync interval, trigger-sync, auth type, sync-name-prefix, env-vars -- the action does not hard-code behavioral choices (action.yml:59-84). Users who want to disable auto-sync polling or change the interval can do so.

**4. Idempotent upsert matched by composePath + repositoryId (good)**
The sync matching logic (action.sh:186-189) uses compose path and repository ID rather than name, which means renames of the sync-name-prefix do not create duplicates. This is a pragmatic design choice.

**5. Outputs for downstream integration (good)**
The action exports `syncs-created`, `syncs-updated`, and `repository-id` (action.yml:86-97, action.sh:340-342), allowing subsequent steps to make conditional decisions (e.g., post a Slack notification if syncs-created > 0).

### Weaknesses

**6. `maxdepth 2` is too restrictive and not configurable (significant)**
The `find` command at action.sh:91 uses `-maxdepth 2`. This means only compose files at `<compose-dir>/` and `<compose-dir>/<one-level>/` are discovered. A repo structured as `stacks/team-a/service-foo/compose.yml` (depth 3) will be silently missed. There is no input to override the max depth. Users must fall back to the explicit `compose-files` list to work around this, which defeats the convenience of auto-discovery.

**7. Sync naming collapses nested paths, risking collisions (significant)**
`sync_name_from_path` (action.sh:111-127) extracts only `basename(dirname(path))`. Given two compose files `frontend/web/compose.yml` and `backend/web/compose.yml`, both would produce the sync name `<prefix>-web`, causing the second to overwrite the first during upsert. There is no input to provide a custom naming function or template. The only workaround is to use `compose-files` and ensure directory names are globally unique, which is a constraint the action imposes rather than documenting.

**8. SSH auth type is declared but not actually supported (moderate)**
`auth-type` accepts `ssh` (action.yml:49-52), but the action never handles SSH key material. There is no `ssh-key` input. The `create_payload` at action.sh:160-165 passes `authType: "ssh"` with an empty token, which will likely fail on the Arcane API side or produce a non-functional repository. Users who need SSH-based cloning (e.g., for private repos behind a bastion or deploy key setup) have no path forward without modifying the action.

**9. No support for multiple environments in a single invocation (moderate)**
The action takes a single `environment-id`. Organizations that deploy the same stacks to staging and production in a single workflow must call the action twice, duplicating the compose discovery and repository-ensure steps. A list of environment IDs (or a matrix-friendly design that outputs the discovered files for reuse) would be more flexible.

**10. env-vars are exported to GITHUB_ENV, not to Arcane (moderate)**
The `env-vars` input (action.sh:260-278) writes to `$GITHUB_ENV`, which means the variables are available to subsequent steps in the GitHub workflow but are NOT sent to Arcane as stack-level environment variables. The README (README.md:56-59) shows `DOMAIN=example.com` as if it will be available inside compose, but those variables only exist in the runner process. If Arcane does not interpolate compose files at clone time using the repo's `.env` file, these variables will have no effect on the deployed stacks. This is a flexibility gap and potentially misleading documentation.

**11. No dry-run or plan mode (moderate)**
There is no way to preview what the action would do without actually creating or updating syncs. A `dry-run: true` input that logs the planned API calls without executing them would make the action much safer to adopt and debug in CI pipelines.

**12. No way to remove stale syncs (minor-to-moderate)**
The action creates and updates syncs but never deletes them (action README.md:10 explicitly states "never deletes"). If a compose file is removed from the repo, the corresponding Arcane sync becomes orphaned. There is no `prune: true` flag or lifecycle management. While "never delete" is safe, it pushes cleanup onto the user with no tooling support.

**13. Compose file discovery does not deduplicate (minor)**
If a user provides both `compose-dir: stacks` and `compose-files: stacks/myapp/compose.yml`, the same file appears twice in the list. The upsert logic will process it twice, with the second call being a no-op update, but it wastes an API call and produces confusing log output.

**14. Repository URL matching is exact-string, not normalized (minor)**
`ensure_repository` (action.sh:138-140) matches repositories by exact URL string comparison. `https://github.com/org/repo.git` and `https://github.com/org/repo` (without `.git`) would be treated as different repositories, potentially creating duplicates in Arcane.

**15. No support for custom compose file name patterns (minor)**
The `find` command (action.sh:91-96) only matches `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, and `compose.yaml`. Users who name their files differently (e.g., `docker-compose.prod.yml`, `compose.override.yml`) have no way to extend the pattern without using the explicit file list.

**16. sync-interval has no validation (minor)**
The `sync-interval` input is passed through as-is. Non-numeric values or values below a minimum threshold (if Arcane enforces one) will produce opaque API errors rather than a clear validation message.

### Edge Cases and Scenarios Not Handled

- **Monorepo with 50+ services at depth 3+**: Must use explicit file list; auto-discovery will not work.
- **Two teams with identically named services**: Sync name collision with no override mechanism.
- **Self-hosted Arcane behind VPN with SSH-only git**: `auth-type: ssh` is accepted but non-functional.
- **Deploying same stacks to dev/staging/prod**: Requires three separate action invocations with full input duplication.
- **Removing a service from the repo**: Orphaned sync in Arcane with no automated cleanup.
- **Compose files with non-standard names** (`docker-compose.prod.yml`): Not discoverable via directory scan.
- **Repository URL with or without `.git` suffix**: May create duplicate repositories in Arcane.

## References

- Action shell script: `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`
  - Compose file discovery: lines 67-105
  - Sync naming logic: lines 111-127
  - `maxdepth 2` limitation: line 91
  - Repository URL matching: lines 138-140
  - Env var export to GITHUB_ENV: lines 260-278
  - Outputs: lines 340-342
- Action metadata: `/home/user/github-actions/.github/actions/arcane-deploy/action.yml`
  - Input definitions: lines 9-84
  - Output definitions: lines 86-97
  - Composite step execution: lines 99-121
- Action README: `/home/user/github-actions/.github/actions/arcane-deploy/README.md`
  - "Never deletes" statement: line 10
  - Sync naming documentation: line 97
