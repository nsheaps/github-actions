# Usability Review

**Score: 72/100**

This action delivers a solid first-time user experience with clear documentation, sensible defaults, and well-structured log output using GitHub Actions grouping. However, several usability gaps reduce confidence during failure scenarios: the API key is masked after it may already have been logged, `git-token` is never masked at all, error messages from the Arcane API are dumped as raw JSON without interpretation, the `env-vars` feature has confusing semantics that could mislead users, and there is no validation for several inputs where invalid values would cause cryptic downstream failures. A new user can get a basic deployment running quickly, but when something goes wrong, debugging will require significant Arcane API knowledge that the action does not surface.

## Detailed Findings

### Secret Masking (Critical)

1. **API key masked too late.** At `action.sh:307`, `::add-mask::` is called for the API key, but lines 283-286 have already logged `ARCANE_URL`, `ENV_ID`, and other configuration values. While the API key itself is not logged in those lines, the mask call occurs after the script has already begun executing and emitting output. If any error or debug trace were to include the key before line 307, it would be exposed. Best practice is to mask secrets as the very first operation.
   - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, line 307

2. **`git-token` is never masked.** The `git-token` input is a secret credential used for repository authentication, but `::add-mask::` is never called for it. If any error message, API response body, or debug output includes the token value, it will be visible in plain text in the workflow logs. This is a significant security/usability concern since users would reasonably expect all secret inputs to be protected.
   - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, lines 14, 149-150, 165

3. **`env-vars` values are never masked.** Environment variable values set via `env-vars` may contain secrets (database passwords, API keys, etc.), but only the key names are logged (line 274 shows `KEY=***`). However, the values are written to `GITHUB_ENV` without masking, so downstream steps could inadvertently log them. The action should call `::add-mask::` on each value.
   - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, lines 260-278

### Error Messages and Debugging

4. **API error bodies are dumped as raw JSON.** When an API call fails (HTTP >= 400), line 57 runs `cat "${tmp_body}" >&2`, which dumps the raw Arcane API response to stderr. This could be an opaque JSON blob that means nothing to a user unfamiliar with the Arcane API. A more usable approach would be to extract a human-readable message (e.g., using `jq` to pull a `.message` or `.error` field) and provide guidance on common errors (401 = bad API key, 404 = invalid environment ID, etc.).
   - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, lines 55-59

5. **No validation of `auth-type` values.** The `auth-type` input accepts any string, but only `none`, `http`, and `ssh` are valid. If a user typos this as `https` or `token`, the action will silently pass the invalid value to the Arcane API and fail with an unhelpful API error.
   - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, line 13; `action.yml`, line 49-51

6. **No validation of `sync-interval` as a number.** The `sync-interval` input is passed directly to `--argjson` in `jq` (lines 203, 237). If a user provides a non-numeric value like `"five"`, `jq` will fail with a cryptic error about invalid JSON rather than a clear message like "sync-interval must be a number."
   - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, lines 203, 237

7. **No warning when `auth-type` is `http` but `git-token` is empty.** Lines 146-155 only update credentials if `auth-type` is `http` AND `git-token` is non-empty, but there is no warning emitted if a user sets `auth-type: http` (the default) without providing a `git-token`. This will likely cause Arcane to fail when cloning the repository, with no indication from this action that the configuration is incomplete.
   - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, lines 146, 163-165; `action.yml`, line 55-57

8. **`jq` dependency is assumed but not checked.** The script relies heavily on `jq` (lines 138, 148, 160, 170, 186, 198, 225, 247) but never verifies that `jq` is available. If run on a runner image without `jq`, the error will be a shell "command not found" error, which is not actionable. A pre-flight check or a note in the README about dependencies would improve usability.
   - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, multiple lines

### Logging and GitHub Actions Groups

9. **Good use of `::group::` sections.** The action uses four well-scoped groups: "Discovering compose files" (lines 313-320), "Ensuring git repository in Arcane" (lines 132-174), "Syncing compose stacks" (lines 326-337), and "Setting shared environment variables" (lines 265-277). These collapse nicely in the GitHub Actions UI and make it easy to expand only the relevant section during debugging. This is well done.

10. **Initial configuration log is helpful.** Lines 282-286 log the Arcane URL, environment ID, repository URL, and branch at the top of the run, giving immediate visibility into what the action will do. This is good practice.

11. **Sync trigger failures are silently swallowed.** Lines 219 and 254 use `|| true` after triggering a sync, which means a failed sync trigger produces no output at all. The user would see "Triggering sync..." but never know whether it succeeded or failed. At minimum, the action should log whether the trigger succeeded.
    - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, lines 219, 254

### Documentation and Getting Started

12. **README provides three clear usage examples.** The action README (`README.md`) shows directory scan, explicit file list, and environment variables patterns. Each example is complete and copy-pasteable. The inputs table is comprehensive and well-formatted. This makes onboarding straightforward.
    - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/README.md`, lines 16-60

13. **Root README provides appropriate summary.** The root `README.md` includes the action under a "Deployment Actions" section with a concise description and a minimal example, then links to the detailed README. This two-level documentation approach is good.
    - **File:** `/home/user/github-actions/README.md`, lines 93-107

14. **`action.yml` input descriptions are clear and contextual.** The descriptions include examples (e.g., `e.g. https://arcane.example.com` for `arcane-url`, `from Settings > API Keys` for the API key) and explain defaults in natural language. The comments grouping inputs by category (`# Compose file discovery`, `# Git repository configuration`, etc.) aid readability even though they do not appear in the GitHub UI.
    - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.yml`, lines 9-84

15. **Missing: what to do when things go wrong.** Neither the action README nor the root README includes a troubleshooting section. Common failure modes (invalid API key, wrong environment ID, repository clone failures, compose file not found at the expected path) should be documented with suggested fixes.

16. **Missing: prerequisites section.** The README does not mention that users need an Arcane instance, an API key (and how to create one beyond "Settings > API Keys"), or what permissions are required. A brief "Prerequisites" section would help new users who are not yet Arcane administrators.

### `env-vars` Feature Semantics

17. **Confusing `env-vars` behavior.** The `env-vars` input writes variables to `GITHUB_ENV` (line 275), which makes them available to subsequent workflow steps but has no effect on the Arcane deployment itself. The `action.yml` description says "Use these in your compose files via variable interpolation or .env files in your repo," but environment variables exported to `GITHUB_ENV` are not sent to Arcane and are not available inside compose files on the Arcane host. This description is misleading and could cause confusion. A user might expect these variables to be injected into the remote Docker Compose environment.
    - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, line 275; `action.yml`, lines 81-84

### Outputs

18. **Outputs are useful but minimal.** The three outputs (`syncs-created`, `syncs-updated`, `repository-id`) enable basic downstream logic (e.g., conditional steps based on whether anything changed). However, the action does not output sync IDs, sync names, or a list of compose files processed, which limits more advanced workflows. For example, a user wanting to add a deployment status comment to a PR would need the individual sync names/IDs.
    - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.yml`, lines 86-97

### Minor Issues

19. **`set -euo pipefail` combined with `|| true` patterns.** The script uses `set -euo pipefail` (line 2) but then uses `|| true` in several places (lines 53, 219, 254). While this is technically correct, the `|| true` on the curl command at line 53 means that network errors (DNS failures, timeouts) will not produce a non-zero HTTP code and will instead silently produce an empty response body that fails in `jq` later with a confusing error.
    - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, line 53

20. **Compose file discovery does not deduplicate.** If a user provides both `compose-dir` and `compose-files` with overlapping paths, the same file will be processed twice, creating duplicate syncs. There is no deduplication logic.
    - **File:** `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`, lines 67-105

## References

- Action script: `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`
- Action metadata: `/home/user/github-actions/.github/actions/arcane-deploy/action.yml`
- Action README: `/home/user/github-actions/.github/actions/arcane-deploy/README.md`
- Root README: `/home/user/github-actions/README.md`
