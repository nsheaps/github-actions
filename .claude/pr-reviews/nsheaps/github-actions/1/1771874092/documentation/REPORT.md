# Documentation & Comments Review

**Score: 82/100**

This PR delivers strong, well-structured documentation that significantly exceeds the baseline set by existing actions in the repository. The action README is comprehensive, covering inputs, outputs, usage examples, and a "How It Works" section. Inline code comments in the shell script are appropriate and well-organized. The main gaps are the absence of troubleshooting guidance, prerequisite/dependency documentation, and a few places where the "How It Works" section could more accurately reflect edge-case behavior in the script.

## Detailed Findings

### Action README (`.github/actions/arcane-deploy/README.md`) -- Excellent

**Strengths:**

- The README is the only action-specific README in the entire repository. No other action under `.github/actions/` has its own README, making `arcane-deploy` the best-documented action by a wide margin. This sets a positive precedent.
- The Features section (lines 6-13) gives a quick, scannable summary of capabilities.
- Three distinct usage examples (lines 16-60) cover the most common patterns: directory scan, explicit file list, and shared environment variables. Each is realistic and uses proper secrets references.
- The Inputs table (lines 62-80) is complete -- all 14 inputs from `action.yml` are represented with accurate descriptions and defaults.
- The Outputs table (lines 82-89) matches the three outputs defined in `action.yml`.
- The "How It Works" section (lines 90-97) explains the four-phase pipeline clearly: discover, ensure repository, upsert syncs, trigger sync.

**Gaps and issues:**

1. **Missing prerequisite documentation.** The script depends on `curl`, `jq`, and `find` being available on the runner. While these are standard on `ubuntu-latest`, the README does not mention runner requirements. A one-line note like "Requires a Linux runner with `curl` and `jq` installed" would help users on custom or minimal runners.

2. **No troubleshooting section.** Common failure modes (invalid API key, unreachable Arcane URL, no compose files found, `compose-dir` not existing) produce specific error messages in the script but are not documented. A brief troubleshooting or "Common Errors" section would improve self-service debugging.

3. **No mention of the "never deletes" policy beyond the Features bullet.** The Features section states "Creates or updates gitops syncs (never deletes)" (line 11), which is an important operational detail. However, the "How It Works" section does not reinforce this, nor does it explain what happens to syncs that were previously created but whose compose files have since been removed. This is a meaningful edge case for users managing evolving stacks.

4. **Sync naming edge cases not fully documented.** The README says (line 97): `stacks/myapp/compose.yml` becomes `<prefix>-myapp`. But the script at lines 117-124 has additional logic: if the directory basename already equals the prefix, it does not double-prefix (the `name != SYNC_NAME_PREFIX` check). And if the file is at the root (`dir == "."`), the sync name is just the prefix. The root-case is not documented at all, and the deduplication logic is not mentioned.

5. **`maxdepth 2` limitation not documented.** The script's `find` at line 91 uses `-maxdepth 2`, meaning deeply nested compose files will not be discovered. The README says "Directory to scan for compose files" but does not specify that scanning only goes two levels deep.

6. **Missing information about what `env-vars` actually does.** The README says env vars are "for the workflow" and the input description says "Use these in your compose files via variable interpolation or .env files in your repo." But the script (lines 260-278) exports them to `$GITHUB_ENV`, making them available to subsequent steps in the workflow -- it does not directly inject them into the Arcane environment or compose files. This distinction could confuse users.

### action.yml (`.github/actions/arcane-deploy/action.yml`) -- Very Good

**Strengths:**

- Input descriptions (lines 9-84) are clear and actionable. The `arcane-api-key` description helpfully includes "(from Settings > API Keys)" guiding users to where to find the value.
- Inputs are logically grouped with YAML comments: compose file discovery (line 22), git repository configuration (line 33), sync behavior (line 59), shared environment variables (line 80). This is a pattern not used by other actions in the repo (`github-app-auth`, `claude-debug`, `claude-auth`) and improves scanability.
- The `compose-dir` description (line 24) includes the glob pattern hint `compose.y[a]ml or docker-compose.y[a]ml`, matching exactly what the script searches for.
- Output descriptions (lines 86-97) are concise and clear.
- Branding is set (lines 5-7), which is good practice and not done by all actions in the repo.

**Gaps:**

1. **No `author` field on comparable actions.** The `action.yml` includes `author: 'nsheaps'` (line 3), which only `claude-auth` among existing actions also does. This is a minor positive for attribution.

2. **`auth-type` does not document valid values in enough detail.** Line 50 says `'Git authentication type: none, http, or ssh'` but does not explain what each implies (e.g., `http` requires `git-token`, `ssh` presumably requires keys configured elsewhere, `none` means public repo). The README's Inputs table similarly just says `none`, `http`, or `ssh` without elaboration.

3. **`sync-interval` units.** The description says "Minutes between auto-sync polls" (line 66), which is good. However, it does not mention valid ranges or whether there is a minimum/maximum enforced by the Arcane API.

### action.sh (`.github/actions/arcane-deploy/action.sh`) -- Good

**Strengths:**

- Well-structured section comments using `# --- Section Name ---` pattern (lines 4, 25, 34, 66, 107, 129, 177, 259, 280). This makes the 345-line script easy to navigate.
- The `arcane_api` function has a clear docstring: "Make an authenticated API request to Arcane." with a usage line (lines 35-36).
- The `sync_name_from_path` function includes concrete examples in its comment (lines 108-110): `"stacks/myapp/compose.yml" -> "${prefix}-myapp"` and `"compose.yml" (root) -> "${prefix}"`. This is excellent.
- The `ensure_repository` function has a one-line docstring (line 130): "Find an existing Arcane git repository by URL, or create one."
- The `upsert_sync` function has a one-line docstring (line 178): "Create or update a gitops sync for a single compose file."
- Inline comments at critical decision points: "Update credentials so the token stays current" (line 145), "Match by compose path + repository ID" (line 185), "Mask the API key" (line 306).
- Uses GitHub Actions log grouping (`::group::` / `::endgroup::`) for organized CI output (lines 132, 174, 265, 277, 313, 320, 326, 337).

**Gaps:**

1. **Whitespace trimming is uncommented.** Lines 73-74 and 267-268 use a bash parameter expansion pattern for trimming whitespace that is not immediately obvious: `file="${file#"${file%%[![:space:]]*}"}"`. While this is a known bash idiom, a brief comment like `# trim leading whitespace` (which does appear conceptually in the trailing-trim comment `# trim trailing`) would help. Actually, looking again, line 73 does have `# trim leading` and line 74 has `# trim trailing` -- these are present but placed as end-of-line comments that are easy to miss. This is acceptable.

2. **`discover_compose_files` lacks a function-level docstring.** Unlike `arcane_api`, `sync_name_from_path`, `ensure_repository`, and `upsert_sync`, the `discover_compose_files` function (line 67) has only the section header `# --- Compose File Discovery ---` but no docstring explaining what it returns or its behavior when both `COMPOSE_FILES_INPUT` and `COMPOSE_DIR` are set (it processes both and concatenates results).

3. **`export_env_vars` lacks a function-level docstring.** Line 260 similarly only has the section header. A brief note explaining that it writes to `$GITHUB_ENV` for subsequent steps would be helpful.

4. **No comment explaining the `|| true` on curl.** Line 53 has `"${url}") || true` -- the `|| true` prevents the `set -e` from aborting when curl returns a non-zero exit code (which it does for certain network errors). This is a subtle but important pattern that warrants a brief comment.

5. **No comment on why `sort -z` is used.** Line 96 uses `sort -z` for null-delimited sorting. While correct, a brief note on deterministic ordering would help readers unfamiliar with null-delimited pipelines.

### Root README (`README.md`) -- Appropriate

**Strengths:**

- The `arcane-deploy` entry (lines 94-107) follows the established pattern of the other actions: a heading, one-line description, one usage example.
- It correctly links to the full docs: `See [action README](.github/actions/arcane-deploy/README.md) for full docs` (line 96). No other action in the root README links to a separate README (because none exist), making this a new pattern that is cleanly introduced.
- The entry is placed under a new "Deployment Actions" section (line 92), which is a logical categorization that keeps the root README organized as the action count grows.

**Gaps:**

1. **No outputs listed in the root README entry.** Other actions like `github-app-auth` (lines 21-26) list their outputs in the root README. The `arcane-deploy` entry omits outputs, relying on the linked README instead. This is a reasonable choice given the "See full docs" link, but is a slight inconsistency with the existing pattern.

### Commit Messages -- Good

- The first commit (`02dbdd6`) uses conventional commit format (`feat: add arcane-deploy action for Docker Compose GitOps sync`) with a descriptive body that covers the key capabilities. This is well-structured.
- The second commit (`99bae8b`) explains the doc restructuring clearly: "The root README now has a brief entry matching the style of other actions, with a link to the full docs."
- Both commits include the Claude session link, which is consistent with the repository's apparent convention.

### Discoverability -- Very Good

- A user browsing the root README would find the action under "Deployment Actions" with a link to full docs.
- A user browsing the `.github/actions/` directory would find the README alongside `action.yml` and `action.sh`.
- The `action.yml` descriptions are detailed enough to serve as inline documentation in workflow editors that display input descriptions.
- The only gap is the lack of any search-friendly keywords or tags. GitHub does not natively support action tags, but mentioning "Portainer" (which Arcane appears to be related to or forked from) or "Docker Compose GitOps" in the README would help users searching for solutions.

### Summary of Deductions

| Category | Deduction | Reason |
|----------|-----------|--------|
| Missing troubleshooting/error docs | -5 | No guidance on common failure modes |
| Missing prerequisites | -2 | No runner/dependency requirements noted |
| Incomplete edge-case docs | -4 | maxdepth 2 limit, root-path sync naming, never-deletes implications |
| env-vars behavior mismatch | -2 | README implies compose-level injection, script does GITHUB_ENV export |
| auth-type values underdocumented | -2 | No explanation of what each auth type requires |
| Missing function docstrings | -2 | `discover_compose_files` and `export_env_vars` lack docstrings |
| Minor inline comment gaps | -1 | `|| true` on curl, `sort -z` rationale |

## References

- `.github/actions/arcane-deploy/action.sh` -- Main deployment script (345 lines)
- `.github/actions/arcane-deploy/action.yml` -- Action definition with 14 inputs, 3 outputs
- `.github/actions/arcane-deploy/README.md` -- Comprehensive action documentation (98 lines)
- `README.md` -- Root repository README with arcane-deploy entry at lines 92-107
- `.github/actions/github-app-auth/action.yml` -- Comparison action (no README, simpler descriptions)
- `.github/actions/claude-debug/action.yml` -- Comparison action (no README, inline script)
- `.github/actions/claude-auth/action.yml` -- Comparison action (no README, grouped inputs with comments)
- Commit `02dbdd6` -- feat: add arcane-deploy action for Docker Compose GitOps sync
- Commit `99bae8b` -- Move arcane-deploy detailed docs to action README
