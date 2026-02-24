# Pattern Matching Review

**Score: 62/100**

The `arcane-deploy` action follows many of the repo's structural conventions -- composite action with `action.yml` + `action.sh`, kebab-case inputs, `INPUT_` env var mapping, and branding metadata -- but it deviates from the established shell scripting patterns in several notable ways. The existing `claude-auth/action.sh` is the closest comparable script (the only other standalone `.sh` file), and it establishes conventions for colored output, `set -e` (not `set -euo pipefail`), dedicated helper functions (`mask_value()`, `set_output()`, `export_env_var()`), and 4-space indentation. The new action diverges on all of these without comment or justification, which fragments the codebase's internal consistency. Additionally, the second commit message lacks a conventional-commit prefix, breaking the repo's commit convention. The action does introduce a well-crafted per-action `README.md` pattern that is a net positive but would benefit from adoption guidance.

## Detailed Findings

### Consistent Patterns

1. **Composite action structure**: Uses `using: 'composite'` with a `steps` block and `shell: bash`, matching every other action in the repo (`claude-auth`, `github-app-auth`, `interpolate-prompt`, `claude-debug`, all `lint-*` actions).

2. **File organization (`action.yml` + `action.sh`)**: The only other action that externalizes its script is `claude-auth`. The new action follows this same `action.yml` + `action.sh` separation pattern, which is appropriate given its 345-line script length.

3. **`INPUT_` env var mapping**: Inputs are passed from `action.yml` to the shell script via `INPUT_*` environment variables (e.g., `INPUT_ARCANE_URL: ${{ inputs.arcane-url }}`). This matches the pattern in `claude-auth/action.yml` exactly.

4. **Kebab-case input names**: All inputs use kebab-case (`arcane-url`, `compose-dir`, `sync-name-prefix`), consistent with every other action in the repo.

5. **`branding` block**: Includes `icon` and `color`, matching `claude-auth`, `github-app-auth`, `interpolate-prompt`, and `claude-debug`.

6. **`author` field**: Includes `author: 'nsheaps'`, matching `claude-auth`.

7. **Output mechanism**: Uses `echo "key=value" >> "$GITHUB_OUTPUT"`, consistent with how `claude-auth`, `claude-debug`, `github-app-auth`, and `interpolate-prompt` set outputs.

8. **`::add-mask::` usage**: Masks the API key on line 307 of `action.sh`, matching how `claude-auth` uses `mask_value()` (which wraps the same `::add-mask::` call).

9. **`log_info()` and `log_error()` function naming**: Matches the function names used in `claude-auth/action.sh` (lines 11-17).

10. **`::group::` / `::endgroup::` usage**: Used in `action.sh` lines 132, 174, 265, 277, 313, 320, 326, 337. This matches the usage in `claude-debug/action.yml` (line 81, 206). Good for log readability.

### Pattern Deviations

1. **`set -euo pipefail` vs `set -e`** (Severity: Medium)
   - Existing: `claude-auth/action.sh` line 2 uses `set -e`
   - New: `arcane-deploy/action.sh` line 2 uses `set -euo pipefail`
   - Assessment: `set -euo pipefail` is arguably more robust (catches unset variables and pipe failures), but it introduces an inconsistency. If this is the desired direction, `claude-auth/action.sh` should be updated to match. Without that follow-up, it is an unjustified divergence.

2. **No colored output** (Severity: Medium)
   - Existing: `claude-auth/action.sh` defines `RED`, `GREEN`, `YELLOW`, `NC` color variables and uses `echo -e` with color codes throughout (lines 5-8, 12-21).
   - New: `arcane-deploy/action.sh` uses plain `echo` with a `[Arcane Deploy]` prefix (lines 27-28) and `::error::` annotations (line 31).
   - Assessment: The `::error::` annotation approach is actually better for GitHub Actions (it surfaces errors in the Actions UI), but the lack of colored `log_info` output is inconsistent. In practice, `echo -e` with ANSI colors does render in Actions logs, so there is visible user-facing inconsistency.

3. **No `set_output()` / `mask_value()` / `export_env_var()` helper functions** (Severity: Medium)
   - Existing: `claude-auth/action.sh` defines reusable helpers `mask_value()` (line 24), `set_output()` (line 30), `export_env_var()` (line 37), and `claude-debug` defines an inline `set_output()` (line 84).
   - New: `arcane-deploy/action.sh` inlines `::add-mask::` (line 307), `>> "$GITHUB_OUTPUT"` (lines 340-342), and `>> "$GITHUB_ENV"` (line 275) directly.
   - Assessment: This is a missed opportunity for consistency. If the repo had a shared library, these would be imported; absent that, at least defining the same helper functions would improve readability and make future refactoring easier.

4. **Indentation: 2 spaces vs 4 spaces** (Severity: Low)
   - Existing: `claude-auth/action.sh` uses 4-space indentation throughout (e.g., lines 12-13, 25-27, 31-33).
   - New: `arcane-deploy/action.sh` uses 2-space indentation throughout.
   - Assessment: The repo's `.editorconfig` or `.prettierrc` may have a preference. Without a `.editorconfig` rule for `.sh` files, this is a minor but noticeable inconsistency. The 2-space style is common in bash scripts, but consistency within a repo matters more than community convention.

5. **`log_warning()` absent** (Severity: Low)
   - Existing: `claude-auth/action.sh` defines `log_warning()` (line 19).
   - New: `arcane-deploy/action.sh` only defines `log_info()` and `log_error()`, no `log_warning()`.
   - Assessment: Minor, but if the action needed warnings it would need to add one later. A complete set of logging functions is better.

6. **Error annotation style** (Severity: Low)
   - Existing: `claude-auth/action.sh` logs errors to stderr via `echo -e ... >&2` (line 17). `interpolate-prompt/action.yml` uses `echo "::error::..."` (line 29).
   - New: `arcane-deploy/action.sh` combines both: `echo "::error::[Arcane Deploy] $1"` (line 31), but `log_info` does not go through `::notice::`.
   - Assessment: The `::error::` approach is actually more useful in GitHub Actions as it creates annotations. This is a positive deviation for `log_error`, but inconsistent with `claude-auth`.

7. **Quoting style** (Severity: Low)
   - Existing: `claude-auth/action.sh` uses double quotes loosely (e.g., `echo "$name=$value"` without braces).
   - New: `arcane-deploy/action.sh` consistently uses `"${variable}"` brace-quoted form.
   - Assessment: The new action's style is more defensive and arguably better practice. Minor inconsistency.

### New Patterns Introduced

1. **Per-action `README.md`** (Merit: High)
   - This is the first action in the repo to have its own `README.md` file. None of the other 12 actions have one.
   - The README is well-structured: Features, Usage examples, Inputs table, Outputs table, and a "How It Works" section.
   - The root `README.md` links to it with "See [action README](.github/actions/arcane-deploy/README.md) for full docs."
   - Assessment: This is a strong positive pattern. The `arcane-deploy` action has 15 inputs -- far more than any other action -- so a dedicated README makes sense. For simpler actions like `lint-checkov` (0 inputs) this would be overkill, but for complex actions like `claude-auth` (12 inputs) or `claude-debug` (5 inputs), this pattern would be beneficial. **Recommendation**: Adopt this pattern for actions with more than ~5 inputs, and document this convention.

2. **Section comment headers** (Merit: Medium)
   - The script uses `# --- Section Name ---` comment blocks (lines 4, 25, 35, 66, 107, 129, 177, 259, 280) to organize the script into logical sections.
   - `claude-auth/action.sh` has no such structural comments.
   - Assessment: Good practice for a 345-line script. Makes navigation easier. Worth adopting.

3. **API helper abstraction** (Merit: High)
   - The `arcane_api()` function (lines 37-64) is a well-designed HTTP client abstraction that handles method, path, auth headers, error checking, and temp file cleanup in one place.
   - Assessment: This is good engineering. It avoids repeated curl boilerplate and centralizes error handling. Not directly reusable by other actions, but the pattern of abstracting external service calls is worth noting.

4. **`::group::` for logical sections** (Merit: Medium)
   - Uses `::group::` / `::endgroup::` to wrap logical phases: compose file discovery (line 313), repository setup (line 132), sync processing (line 326), env vars (line 265).
   - `claude-debug` uses this once (line 81).
   - Assessment: Good practice for actions with multi-phase output. Makes logs much more readable in the Actions UI. Worth adopting in `claude-auth`.

### Commit History

- **Commit 1**: `feat: add arcane-deploy action for Docker Compose GitOps sync` -- Follows conventional commit format (`feat:` prefix). Good.
- **Commit 2**: `Move arcane-deploy detailed docs to action README` -- **Does not** follow conventional commit format. Should be `docs: move arcane-deploy detailed docs to action README` or `refactor: move arcane-deploy detailed docs to action README`. This breaks the pattern established by prior commits (`chore: mise format`, `fix: use mise task scripts...`, `feat: add shared GitHub Actions...`).

## References

| File                                                                      | Role                               | Key Lines                                                                                                        |
| ------------------------------------------------------------------------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `/home/user/github-actions/.github/actions/arcane-deploy/action.sh`       | New action script                  | L2 (`set -euo pipefail`), L5-19 (config), L26-32 (logging), L37-64 (API helper), L307 (mask), L340-342 (outputs) |
| `/home/user/github-actions/.github/actions/arcane-deploy/action.yml`      | New action definition              | L1-7 (metadata+branding), L9-84 (inputs), L86-97 (outputs), L99-121 (runs+env mapping)                           |
| `/home/user/github-actions/.github/actions/arcane-deploy/README.md`       | New action docs                    | Only action with a dedicated README                                                                              |
| `/home/user/github-actions/.github/actions/claude-auth/action.sh`         | Existing comparable script         | L2 (`set -e`), L5-8 (colors), L11-21 (logging with colors), L24-41 (helpers), 4-space indent                     |
| `/home/user/github-actions/.github/actions/claude-auth/action.yml`        | Existing comparable action.yml     | L1-6 (metadata+branding), L9-69 (inputs), L71-74 (outputs), L76-96 (runs+env mapping)                            |
| `/home/user/github-actions/.github/actions/claude-debug/action.yml`       | Existing action with inline script | L79-222 (inline bash with `set_output()`, `::group::`)                                                           |
| `/home/user/github-actions/.github/actions/interpolate-prompt/action.yml` | Existing action                    | L29 (`::error::` usage)                                                                                          |
| `/home/user/github-actions/.github/actions/github-app-auth/action.yml`    | Existing action (no shell script)  | L1-2 (metadata without `author`), L7-8 (branding)                                                                |
| `/home/user/github-actions/README.md`                                     | Root docs                          | L92-107 (arcane-deploy section with link to action README)                                                       |
