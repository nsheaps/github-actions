# Quality Assurance & Engineering Review

**Score: 52/100**

This action demonstrates a solid understanding of the Arcane API workflow and follows reasonable bash scripting conventions (`set -euo pipefail`, structured functions, GitHub Actions logging groups). However, it has significant correctness bugs that will cause failures in common scenarios, several robustness gaps around API error handling and edge cases, notable code duplication, and no test coverage or testable structure. The action would likely work in the happy path for a simple single-directory layout, but would fail or behave unexpectedly in many realistic edge cases.

## Detailed Findings

### Correctness Analysis

**Critical: `sync_name_from_path` produces collisions for deeply nested paths (lines 111-127)**

The naming logic uses only `basename` of the parent directory. Given these files:
- `stacks/web/frontend/compose.yml` -> name: `prefix-frontend`
- `stacks/api/frontend/compose.yml` -> name: `prefix-frontend`

Both produce the same sync name, meaning the second will silently overwrite the first in the upsert logic. This is a data-loss scenario. The function should incorporate the full relative path into the name (e.g., slugifying the directory path) rather than only the immediate parent.

**Critical: `sync_name_from_path` loses uniqueness when prefix matches directory name (lines 121-123)**

If `SYNC_NAME_PREFIX` is `myapp` and the compose file is at `myapp/compose.yml`, `dirname` returns `myapp`, `basename` returns `myapp`, and the condition `name != SYNC_NAME_PREFIX` is false, so the name is just `myapp`. But if there is also a root `compose.yml`, that also gets the name `myapp` (from the `dir == "."` branch). Two distinct compose files produce the same sync name.

**Bug: `jq` filter `first // empty` behavior with `.id` (lines 138-140, 186-189)**

The jq expression `[.[] | select(...)] | first // empty | .id` has a subtle issue. If `first` returns an object, `.id` works fine. But if the array is empty, `first` returns `null`, then `// empty` produces nothing, and `.id` on nothing produces nothing -- which works correctly here. However, if the API ever returns an entry where `.id` is `null` or `0`, the `// empty` alternative operator would incorrectly activate because `null // empty` triggers the alternative. This is a minor concern but worth noting.

**Bug: `repositoryId` field type mismatch potential (line 189)**

The `existing_id` and `REPOSITORY_ID` values are extracted with `jq -r`, which returns string representations. If the Arcane API uses integer IDs, the jq `select` comparing `.repositoryId == $repoId` compares a number to a string and will never match, meaning syncs will always be created, never updated. This would cause duplicate syncs on every run. The fix would be to use `--argjson` for numeric IDs or convert within the jq filter using `tostring`.

**Issue: `mapfile` on empty `discover_compose_files` output (line 315)**

If `discover_compose_files` returns an empty string (which it does not, due to the early return 1), this would create an array with one empty element. The `[[ -z "${compose_path}" ]] && continue` guard on line 331 handles this, but only incidentally. More importantly, because `set -e` is active, the `return 1` on line 102 will cause the subshell on line 314 to fail and the script to exit -- but the error message alone may not be clear since the `::group::` was already opened on line 313 but never closed.

**Issue: Explicit compose files are not validated (lines 71-78)**

When using `compose-files` input, the paths are taken verbatim without checking they actually exist on disk. While the Arcane API might not need them to exist locally (it syncs via git), there is no validation or warning if a path is clearly wrong. This could lead to silent misconfiguration.

**Issue: `GITHUB_WORKSPACE` fallback to `.` (lines 82, 89)**

The fallback `${GITHUB_WORKSPACE:-.}` means if `GITHUB_WORKSPACE` is unset (e.g., local testing), the script uses the current directory. However, the relative path stripping on line 89 (`${file#"${GITHUB_WORKSPACE:-.}/"}`) depends on the prefix matching exactly. If `GITHUB_WORKSPACE` is set but `COMPOSE_DIR` results in a resolved symlink or different path representation, the prefix stripping will fail and full absolute paths will leak into the sync configuration.

**Issue: `::add-mask::` after logging (lines 282-286 vs 307)**

The API key is masked on line 307, but the script has already logged `ARCANE_URL`, `ENV_ID`, etc. on lines 282-286. While the API key itself is not logged before masking, the mask command should ideally come as early as possible -- before any output -- to ensure no accidental leakage in future code changes.

### Robustness

**No curl timeout (line 47)**

The `curl` command has no `--connect-timeout` or `--max-time` flags. If the Arcane instance is unreachable or hangs, the action will hang indefinitely (until the GitHub Actions job timeout, which defaults to 6 hours). Adding `--connect-timeout 10 --max-time 60` would make failures explicit and fast.

**No retry logic for transient failures**

API calls can fail due to transient network issues, rate limiting, or server errors (5xx). There is no retry mechanism. A single network blip will fail the entire deployment. At minimum, the `arcane_api` function should retry on 5xx responses or connection failures.

**`|| true` on curl swallows connection errors (line 53)**

The `|| true` after curl means that if curl itself fails (DNS resolution failure, connection refused, etc.), `http_code` will be empty or `000`. The subsequent `[[ "${http_code}" -ge 400 ]]` comparison will treat empty/000 as success (since `000 -ge 400` is false), and the function will `cat` an empty temp file and return success with empty output. Downstream `jq` calls on this empty output will then fail with parse errors, producing confusing error messages that do not point to the actual network failure.

A fix would be:
```bash
if [[ -z "${http_code}" || "${http_code}" == "000" ]]; then
  log_error "API ${method} ${path} failed (connection error)"
  rm -f "${tmp_body}"
  return 1
fi
```

**No validation of jq output after repository creation (line 170)**

After creating a repository, `REPOSITORY_ID` is set from `jq -r '.id'`. If the API returns unexpected JSON (e.g., an error wrapped in 2xx), `.id` will be `null`, and `REPOSITORY_ID` will be the literal string `"null"`. All subsequent API calls will use `/environments/.../gitops-syncs/null/...`, which will likely return 404s with confusing errors.

**`GITHUB_ENV` and `GITHUB_OUTPUT` assumed to exist (lines 275, 340-342)**

If these environment files do not exist (e.g., when running outside GitHub Actions for testing), the script will fail with a confusing "No such file or directory" error. A guard like `[[ -n "${GITHUB_OUTPUT:-}" ]]` would improve local testability.

**Temp file cleanup on unexpected exit (line 44)**

The `mktemp` files in `arcane_api` are cleaned up in the normal flow, but if the script is killed (SIGTERM/SIGINT) between `mktemp` and `rm -f`, temp files will leak. A `trap` to clean up would be more robust, though this is a minor concern for ephemeral CI runners.

**No handling of API response pagination**

If the Arcane API paginates results (e.g., for repositories or syncs), the script only processes the first page. With many repositories or syncs, existing items might not be found, leading to duplicates.

### Code Quality

**Duplicated trigger-sync blocks (lines 217-220 and 252-255)**

The trigger sync logic appears identically in both the update and create branches of `upsert_sync`. This should be extracted into a helper function or moved after the if/else block using a variable for the sync ID:

```bash
local sync_id="${existing_id:-${new_id}}"
if [[ "${TRIGGER_SYNC}" == "true" ]]; then
  log_info "  Triggering sync..."
  arcane_api POST "/environments/${ENV_ID}/gitops-syncs/${sync_id}/sync" > /dev/null || true
fi
```

**Global mutable state (lines 21-23)**

`SYNCS_CREATED`, `SYNCS_UPDATED`, and `REPOSITORY_ID` are global variables mutated by functions. This makes the code harder to reason about and test. `REPOSITORY_ID` in particular is set as a side effect of `ensure_repository()` and then read by `upsert_sync()` via closure over the global. Returning values from functions via stdout (as `discover_compose_files` does) would be cleaner.

**`sync_name_from_path` only uses immediate parent directory (lines 111-127)**

As noted in correctness, this is also a design concern. The naming scheme is too simplistic for real-world use. A slugified full relative path would be more robust and predictable.

**Environment variable export side effect (lines 260-278)**

The `export_env_vars` function writes to `GITHUB_ENV`, which affects subsequent steps in the workflow. This is a side effect that is not clearly documented as affecting the broader workflow context, not just the current action. Users may be surprised that setting `env-vars` in this action pollutes the entire workflow's environment.

**No shellcheck annotations or CI validation**

The script does not appear to be validated by shellcheck in CI. Some patterns (like the whitespace trimming on lines 73-74) would benefit from shellcheck's analysis to confirm correctness.

**Hardcoded `-maxdepth 2` in find (line 91)**

The directory scan only goes 2 levels deep. This is undocumented behavior and will silently miss compose files in deeper directory structures. The README says "scans for compose files in a directory" without mentioning the depth limit.

### Testing

**No tests exist**

There are no unit tests, integration tests, or even a test workflow for this action. For a script that makes destructive API calls (creating repositories and syncs), this is a significant gap.

**Code is not structured for testability**

The script uses global state, direct API calls, and GitHub Actions-specific environment variables throughout. To make this testable, you would need:

1. Ability to mock `arcane_api` (currently a function, which is good, but it cannot be replaced without sourcing)
2. Ability to set `GITHUB_ENV`/`GITHUB_OUTPUT` to temp files
3. A way to run `discover_compose_files` in isolation against a test directory

**Recommended test approaches:**

- **Unit tests with BATS** (Bash Automated Testing System): Source the script's functions and test them individually. The function-based structure makes this partially feasible, but the global state and `set -euo pipefail` at the top complicate sourcing.
- **Integration tests with a mock Arcane API**: Use a simple HTTP server (e.g., `python3 -m http.server` or a purpose-built mock) to validate the full flow.
- **Dry-run mode**: Add a `dry-run` input that logs what would happen without making API calls. This would aid both testing and user confidence.

**No validation of API contract**

There is no schema validation of the Arcane API responses. If the API changes (field renames, type changes), failures will be cryptic jq errors rather than clear "API contract violated" messages.

## References

- `/home/user/github-actions/.github/actions/arcane-deploy/action.sh` -- Main script (345 lines)
  - Lines 47-53: `arcane_api` curl call with `|| true` swallowing connection errors
  - Lines 111-127: `sync_name_from_path` with collision risk
  - Lines 138-140: jq filter for repository lookup, potential type mismatch
  - Lines 186-189: jq filter for sync lookup, `$repoId` string-vs-number comparison risk
  - Lines 217-220, 252-255: Duplicated trigger-sync logic
  - Lines 21-23: Global mutable state variables
  - Line 91: Hardcoded `-maxdepth 2` depth limit
  - Line 307: `::add-mask::` called after initial logging
- `/home/user/github-actions/.github/actions/arcane-deploy/action.yml` -- Action definition (122 lines)
  - Lines 99-122: Composite action with env passthrough
- `/home/user/github-actions/.github/actions/arcane-deploy/README.md` -- Documentation (98 lines)
