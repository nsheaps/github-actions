# Overall PR Review: arcane-deploy GitHub Action

## Score Summary

| Category          | Score      | Status             |
| ----------------- | ---------- | ------------------ |
| Simplicity        | 42/100     | :rotating_light:   |
| Flexibility       | 62/100     | :rotating_light:   |
| Usability         | 72/100     | :warning:          |
| Documentation     | 82/100     | :warning:          |
| Security          | 52/100     | :rotating_light:   |
| Patterns          | 62/100     | :rotating_light:   |
| Best Practices    | 86/100     | :white_check_mark: |
| Quality Assurance | 52/100     | :rotating_light:   |
| **Overall**       | **64/100** | :rotating_light:   |

## Executive Summary

This PR introduces a well-intentioned `arcane-deploy` GitHub Action that automates Docker Compose stack deployment to Arcane via its GitOps sync API. The action follows the repo's structural conventions (composite action, `action.yml` + `action.sh`, `INPUT_*` env mapping) and demonstrates strong engineering in several areas: idempotent upsert logic, safe JSON construction via `jq --arg`, proper use of `::group::` logging, and comprehensive README documentation.

However, the action has significant issues across multiple dimensions that warrant a round of revisions before merge:

### Critical Issues (Must Fix)

1. **Security: `git-token` is never masked** (`action.sh:14`) -- The git token secret is never passed through `::add-mask::`, creating a real risk of secret leakage in workflow logs. The API key is masked (line 307) but too late in the script.

2. **Security: `GITHUB_ENV` injection via `env-vars`** (`action.sh:260-278`) -- User-supplied `KEY=VALUE` lines are written directly to `$GITHUB_ENV` with no sanitization. Multiline values or delimiter manipulation can overwrite arbitrary environment variables for subsequent workflow steps.

3. **Security: No URL scheme validation** (`action.sh:5`) -- `arcane-url` feeds directly into `curl` with no HTTPS enforcement, enabling SSRF risk.

4. **Correctness: `sync_name_from_path` produces collisions** (`action.sh:111-127`) -- `basename(dirname(path))` naming causes two compose files in sibling directories with the same leaf name (e.g., `web/frontend/compose.yml` and `api/frontend/compose.yml`) to produce identical sync names, with the second silently overwriting the first.

5. **Correctness: `curl || true` swallows connection errors** (`action.sh:53`) -- Network failures produce empty `http_code`, which passes the `>= 400` check as "success", sending empty data to `jq` and causing confusing downstream parse errors.

### Important Issues (Should Fix)

6. **Flexibility: `maxdepth 2` is hardcoded and undocumented** (`action.sh:91`) -- Deeper directory structures are silently missed with no way to override.

7. **Flexibility: SSH auth is declared but non-functional** (`action.yml:49-52`) -- `auth-type: ssh` is accepted but no SSH key handling exists.

8. **Usability: `env-vars` semantics are misleading** (`action.yml:81-84`) -- Description implies compose-level injection, but it only writes to `GITHUB_ENV` for subsequent workflow steps.

9. **Patterns: Multiple deviations from repo conventions** -- `set -euo pipefail` vs `set -e`, no colored output, no helper functions (`set_output`, `mask_value`), 2-space vs 4-space indent, second commit lacks conventional commit prefix.

10. **QA: No curl timeout** -- Missing `--connect-timeout`/`--max-time` means the action hangs indefinitely if Arcane is unreachable.

### What's Done Well

- Idempotent upsert pattern matched by `composePath + repositoryId`
- Safe JSON construction with `jq --arg` throughout (no JSON injection)
- Comprehensive action README with three usage examples, inputs table, and "How It Works" section
- Clean four-phase `::group::` structure for readable logs
- Smart defaults derived from GitHub context (`GITHUB_REF_NAME`, `GITHUB_REPOSITORY`)
- First action in the repo with a dedicated README -- a good pattern to adopt

## Detailed Category Reports

Individual detailed reports are available in:

- [Simplicity](./simplicity/REPORT.md)
- [Flexibility](./flexibility/REPORT.md)
- [Usability](./usability/REPORT.md)
- [Documentation](./documentation/REPORT.md)
- [Security](./security/REPORT.md)
- [Patterns](./patterns/REPORT.md)
- [Best Practices](./best-practices/REPORT.md)
- [Quality Assurance](./quality-assurance/REPORT.md)
