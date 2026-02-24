# Simplicity Review

**Score: 42/100**

The arcane-deploy action is a moderately over-engineered bash script that tries to be a full-featured API client for the Arcane platform rather than a focused, minimal deployment step. At 345 lines of bash and 15 inputs, it carries significant cognitive overhead for what could be a simpler interaction. The script contains a custom API client abstraction, compose file discovery with two different strategies (directory scanning and explicit listing), an environment variable export mechanism, a sync naming derivation scheme, and a full repository upsert flow. While each individual piece is readable, the aggregate complexity is high for a composite GitHub Action, and several features feel like they belong in the Arcane platform itself or in a dedicated CLI tool rather than in a bash script passed through environment variables.

## Detailed Findings

### Input Surface Area is Large (15 inputs)

The action defines 15 inputs in `action.yml` (lines 9-84). Compare this to the existing actions in the repo: `claude-auth` has 12 inputs but supports three entirely different secret providers (Doppler, 1Password, raw), and `interpolate-prompt` has 1 input. For a single deployment target (Arcane), 15 inputs is a lot. Many of these have sensible defaults derived from GitHub context, which is good, but the sheer count creates a wide surface area that users need to understand.

Inputs that add questionable value:

- **`sync-name-prefix`** (`action.yml:75-78`): A naming customization that could simply default to the repo name with no override needed for the common case.
- **`sync-interval`** (`action.yml:66-68`): Exposing polling interval at the action level is a deployment concern that most users will never change from the default of 5 minutes.
- **`env-vars`** (`action.yml:80-84`): This input writes KEY=VALUE pairs into `$GITHUB_ENV` (see `action.sh:260-278`). This is a workflow-level concern, not a deployment concern. Users can already set environment variables using the native `env:` key in their workflow YAML. Bundling this into the action conflates responsibilities.
- **`repository-name`** (`action.yml:39-42`) and **`repository-url`** (`action.yml:35-37`): These already default to the GitHub context values and are rarely needed. They add clutter.

### Dual Compose File Discovery is an Unnecessary Abstraction

The script supports two modes of discovering compose files: directory scanning (`compose-dir`, `action.sh:80-97`) and explicit listing (`compose-files`, `action.sh:71-78`). Supporting both is more complex than necessary. The directory scanning uses `find` with `-maxdepth 2` and matches four different filename patterns (`action.sh:91-96`). The explicit list requires newline-separated input with manual whitespace trimming (`action.sh:72-76`).

A simpler approach: just accept an explicit list of compose file paths. If users want directory scanning, they can do that in a preceding workflow step and pass the result. This would cut out the `discover_compose_files` function entirely (lines 67-105) and simplify the required validation at lines 301-304.

### The `env-vars` Feature Does Not Belong Here

The `export_env_vars` function (`action.sh:260-278`) parses a multiline string of KEY=VALUE pairs and writes them to `$GITHUB_ENV`. This is orthogonal to the deployment logic. It also includes its own comment-stripping logic (`action.sh:270`) and whitespace trimming (`action.sh:267-268`). Users can achieve the same result natively in GitHub Actions:

```yaml
env:
  DOMAIN: example.com
  NETWORK: traefik
```

This feature adds complexity without adding capability that does not already exist in the platform.

### The API Helper is Reasonable but Uses Temp Files Unnecessarily

The `arcane_api` function (`action.sh:37-64`) is a clean abstraction for making authenticated curl requests. However, it uses `mktemp` to capture the body (`action.sh:44`), then `cat`s the result (`action.sh:62`), then `rm`s the file (`action.sh:63`). This temp-file dance could be replaced with process substitution or a simpler variable capture. On the positive side, the separation of HTTP status code from body is a useful pattern, and the error handling at lines 55-60 is clear.

### Sync Naming Logic is Fragile

The `sync_name_from_path` function (`action.sh:111-127`) derives a sync name from a file path using `dirname` and `basename`. The special case where the directory name already matches the prefix (`action.sh:121-123`) is a subtle behavior that would surprise users. The naming scheme is documented in `README.md:97`, but the implementation has an implicit collision risk: two compose files in sibling directories with the same name (e.g., `a/myapp/compose.yml` and `b/myapp/compose.yml`) would produce the same sync name.

### The Script is Linear but Long

At 345 lines, `action.sh` is the longest script among the actions in this repo. The `claude-auth/action.sh` is 196 lines but handles three completely different authentication providers. The arcane-deploy script handles one provider (Arcane) but does more things: discovery, repository management, sync upsert, env var export. Each function is reasonably clear in isolation, but the total is a lot to follow. The main flow (`action.sh:280-344`) is well-structured and reads top-to-bottom, which is a positive.

### Positive: Follows Repo Patterns Well

The action follows the established pattern of the repository: composite action with `action.yml` + `action.sh`, `INPUT_*` env vars passed from the YAML to the script, `set -euo pipefail`, logging helpers, and GitHub-native annotations (`::error::`, `::group::`, `::add-mask::`). This consistency with `claude-auth` and other actions is good for maintainability.

### Positive: Idempotent Upsert Pattern

The upsert logic in `upsert_sync` (`action.sh:179-257`) is well-designed. It matches existing syncs by compose path + repository ID (`action.sh:186-189`), which is a stable identity key. This means re-running the action does not create duplicates. The repository upsert in `ensure_repository` (`action.sh:131-175`) similarly checks by URL before creating. This is a good practice.

### Positive: Good README

The action README (`README.md`) is well-structured with clear usage examples for the three main modes (directory scan, explicit list, env vars). The inputs table at lines 64-80 and the "How It Works" section at lines 92-97 give users a quick orientation. The root `README.md` entry at lines 94-107 is appropriately brief and links to the detailed docs.

### Comparison Summary

| Metric        | `arcane-deploy` | `claude-auth`     | `interpolate-prompt` | `lint-trivy` |
| ------------- | --------------- | ----------------- | -------------------- | ------------ |
| Inputs        | 15              | 12                | 1                    | 0            |
| Script lines  | 345             | 196               | (inline, 18)         | (inline, 8)  |
| Functions     | 7               | 5                 | 0                    | 0            |
| External deps | curl, jq, find  | curl, doppler, op | envsubst             | trivy        |

The arcane-deploy action is roughly 2x the complexity of claude-auth while solving a narrower problem (one platform vs. three providers). This ratio suggests there is room for simplification.

## References

- `/home/user/github-actions/.github/actions/arcane-deploy/action.sh` - Main deployment script (345 lines)
- `/home/user/github-actions/.github/actions/arcane-deploy/action.yml` - Action definition with 15 inputs (122 lines)
- `/home/user/github-actions/.github/actions/arcane-deploy/README.md` - Action documentation (98 lines)
- `/home/user/github-actions/README.md` - Root README with arcane-deploy entry at lines 94-107
- `/home/user/github-actions/.github/actions/claude-auth/action.yml` - Comparable action for pattern reference (96 lines, 12 inputs)
- `/home/user/github-actions/.github/actions/claude-auth/action.sh` - Comparable script for pattern reference (196 lines)
- `/home/user/github-actions/.github/actions/interpolate-prompt/action.yml` - Simple action for contrast (43 lines, 1 input)
- `/home/user/github-actions/.github/actions/lint-trivy/action.yml` - Minimal action for contrast (25 lines, 0 inputs)
