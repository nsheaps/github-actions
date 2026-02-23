# Best Practices Review

**Score: 86/100**

This PR demonstrates strong adherence to best practices across shell scripting, GitHub Actions design, and API integration. The code is well-structured with clear separation of concerns, consistent error handling, idempotent API operations, and proper use of GitHub Actions workflow commands. The main areas for improvement involve a few defensive coding gaps in the shell script, a missing trap-based cleanup pattern for temp files, and a second commit that does not follow conventional commit format.

## Detailed Findings

### Excellent Practices

**Shell Scripting (Strong)**
- `set -euo pipefail` is present on line 2 of `action.sh`, ensuring fail-fast behavior for unset variables, non-zero exits, and pipeline failures.
- Variables are consistently and correctly double-quoted throughout the entire script (e.g., `"${ARCANE_URL}"`, `"${compose_path}"`), preventing word splitting and globbing issues.
- `local` variable declarations are used in every function (`local method`, `local path`, `local files=()`, `local http_code`, etc.), preventing variable leakage into the global scope.
- `jq` is used consistently for all JSON construction and parsing (lines 138, 148, 160, 186, 198, 225, 247), avoiding fragile string interpolation for JSON payloads. The use of `--arg` and `--argjson` is correct and avoids injection risks.
- The `find` command uses `-print0` with `read -r -d ''` (lines 88-96), correctly handling filenames with spaces or special characters.
- Whitespace trimming uses pure bash parameter expansion (lines 73-74, 267-268), avoiding unnecessary subprocess calls.

**GitHub Actions Structure (Strong)**
- The composite action in `action.yml` is cleanly organized with descriptive input names, good descriptions, sensible defaults, and clear groupings via comments.
- Branding is properly configured with `icon: 'upload-cloud'` and `color: 'purple'` (lines 5-7 of `action.yml`).
- Outputs are properly wired from the step ID to the action outputs (lines 86-97 of `action.yml`).
- The step has a clear `name: Deploy to Arcane` and an explicit `id: deploy` for output references.
- Environment variables are passed explicitly from inputs to the shell script via the `env:` block (lines 107-121 of `action.yml`), which is the correct pattern for composite actions rather than relying on `${{ inputs.* }}` in shell code.

**GitHub Actions Workflow Commands (Strong)**
- `::error::` is used in `log_error()` (line 31), causing errors to appear as annotations in the Actions UI.
- `::group::` / `::endgroup::` is used for logical sections: "Ensuring git repository" (line 132/174), "Discovering compose files" (line 313/320), "Syncing compose stacks" (line 326/337), and "Setting shared environment variables" (line 265/277).
- `::add-mask::` is used for the API key (line 307), preventing it from leaking in logs.

**API Integration (Strong)**
- The `arcane_api()` helper (lines 37-64) centralizes all HTTP requests with consistent authentication, error handling, and HTTP status code checking (`http_code -ge 400`).
- The upsert pattern in `upsert_sync()` (lines 179-257) matches by `composePath` + `repositoryId`, making the operation fully idempotent on re-runs.
- `ensure_repository()` (lines 131-175) follows the same find-or-create pattern, and also updates credentials on existing repos to keep tokens current.
- Error responses include both the HTTP status code and the response body (lines 56-58), which aids debugging.

**Documentation (Strong)**
- The `README.md` provides usage examples for all three patterns (directory scan, explicit list, environment variables), a complete inputs/outputs table, and a clear "How It Works" explanation.
- The root `README.md` is updated with a concise entry and a link to the detailed docs.

**Input Validation (Good)**
- Required inputs are validated early (lines 289-304) with descriptive error messages and `exit 1`.
- The mutual requirement of `compose-dir` or `compose-files` is explicitly checked (lines 301-304).

### Areas for Improvement

**1. Temp File Cleanup via Trap (Medium Impact)**
In `arcane_api()` (lines 43-63), a temp file is created with `mktemp` and cleaned up manually with `rm -f`. If the function is interrupted between `mktemp` and `rm -f` (e.g., by a signal or `set -e` triggering on `cat`), the temp file will be leaked. Best practice is to use a `trap` for cleanup:
```bash
local tmp_body
tmp_body=$(mktemp)
trap "rm -f '${tmp_body}'" RETURN
```
Alternatively, a global trap at the top of the script could manage a temp directory.

**2. Second Commit Does Not Follow Conventional Commits (Low-Medium Impact)**
The first commit (`feat: add arcane-deploy action for Docker Compose GitOps sync`) follows conventional commit format correctly. The second commit (`Move arcane-deploy detailed docs to action README`) does not use a conventional prefix. It should be something like `docs: move arcane-deploy detailed docs to action README`. While not a blocking issue, consistency with conventional commits is a stated best practice for this repository given the first commit's format.

**3. Missing `::add-mask::` for `GIT_TOKEN` (Medium Impact)**
The API key is masked on line 307 with `::add-mask::`, but `GIT_TOKEN` (which contains a git authentication credential) is never masked. If it appears in any log output (e.g., in an error response from the API), it would be visible in plain text. A mask should be added:
```bash
if [[ -n "${GIT_TOKEN}" ]]; then
  echo "::add-mask::${GIT_TOKEN}"
fi
```

**4. `curl` Failure Suppressed with `|| true` (Low-Medium Impact)**
On line 53, `|| true` suppresses curl's own exit code (e.g., DNS resolution failure, connection refused, timeout). This means a network-level failure would result in an empty `http_code` rather than a caught error. The subsequent `[[ "${http_code}" -ge 400 ]]` comparison would fail unpredictably on an empty string. A more robust approach:
```bash
http_code=$(curl -s -w "%{http_code}" ... -o "${tmp_body}" "$@" "${url}") || {
  log_error "API ${method} ${path} - curl failed (network error)"
  rm -f "${tmp_body}"
  return 1
}
```

**5. No Retry Logic for Transient API Failures (Low Impact)**
API calls are single-shot with no retry. For a deployment action, transient 5xx errors or network blips could cause unnecessary failures. While not strictly required, a simple retry with backoff (even just 1-2 retries) would improve reliability. This is a nice-to-have rather than a requirement.

**6. `export_env_vars` Uses `local` Outside a Function Context Concern (Low Impact)**
In `export_env_vars()` on line 272, `local key` and `local value` are declared inside a `while` loop that is itself inside a function, which is fine. However, the values written to `GITHUB_ENV` (line 275) are not masked. If sensitive values are passed via `env-vars`, they could appear in logs. The function logs `${key}=***` which is good, but consider also masking the values:
```bash
echo "::add-mask::${value}"
```

**7. Composite Action Has a Single Step (Informational)**
The action runs all logic in a single composite step. While this is perfectly functional, some best practice guides suggest splitting validation, discovery, and API operations into separate steps for better observability in the Actions UI. The use of `::group::` within the script mitigates this well, but separate steps would give individual step-level timing and status indicators.

**8. `action.sh` Line Count (Informational)**
At 345 lines, the script is at the upper bound of comfortable single-file shell script size. If more features are added, consider splitting into helper modules sourced from the main script.

## References

- `/home/user/github-actions/.github/actions/arcane-deploy/action.sh` - Main shell script (345 lines)
- `/home/user/github-actions/.github/actions/arcane-deploy/action.yml` - Composite action definition (122 lines)
- `/home/user/github-actions/.github/actions/arcane-deploy/README.md` - Action documentation (97 lines)
- `/home/user/github-actions/README.md` - Root repository README (179 lines)
- [GitHub Actions - Creating a composite action](https://docs.github.com/en/actions/sharing-automations/creating-actions/creating-a-composite-action)
- [GitHub Actions - Workflow commands](https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/workflow-commands-for-github-actions)
- [Conventional Commits specification](https://www.conventionalcommits.org/en/v1.0.0/)
- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
