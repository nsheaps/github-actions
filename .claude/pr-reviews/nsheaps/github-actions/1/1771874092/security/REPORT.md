# Security Review

**Score: 52/100**

This action has several meaningful security concerns that should be addressed before merging. While some good practices are present (use of `set -euo pipefail`, `jq --arg` for safe JSON construction, temp file cleanup), the script has critical gaps: the git token is never masked, the `env-vars` input is vulnerable to `GITHUB_ENV` injection, there is no URL scheme validation on `arcane-url` (SSRF risk), and multiple user-controlled inputs flow into shell contexts without sanitization. The action also passes secrets through the `env` block in `action.yml` without masking them before the script runs, meaning framework-level log exposure is possible before `::add-mask::` is called in the script body.

## Detailed Findings

### Critical Issues

**C1. Git token (`git-token`) is never masked** (`action.sh` lines 14, 146-154, 159-165)

The API key is masked on line 307 with `::add-mask::${API_KEY}`, but the git token -- which is equally sensitive -- is never masked. It is sent in JSON payloads to the Arcane API and could appear in error output (line 57: `cat "${tmp_body}" >&2` dumps the full API response body on failure, which could echo back the token). The `claude-auth` reference action masks its secret immediately. The git token should be masked with `::add-mask::${GIT_TOKEN}` right alongside the API key mask on line 307.

**C2. `GITHUB_ENV` injection via `env-vars` input** (`action.sh` lines 260-278)

The `export_env_vars` function writes user-supplied `KEY=VALUE` lines directly to `$GITHUB_ENV` (line 275). A malicious or misconfigured input can exploit the multiline GITHUB_ENV delimiter syntax to inject arbitrary environment variables into subsequent workflow steps. For example, an `env-vars` value like:

```
BENIGN=value
GITHUB_TOKEN<<EOF
malicious-token
EOF
```

could overwrite `GITHUB_TOKEN` or any other environment variable for later steps. There is no validation that `key` contains only safe characters (alphanumeric and underscore), no check that `value` doesn't contain newlines or delimiter sequences, and no use of the safer heredoc-style `GITHUB_ENV` writing pattern with a randomized delimiter. This is a well-documented class of GitHub Actions vulnerability.

**C3. No URL scheme validation on `arcane-url` -- SSRF risk** (`action.sh` line 5, `action.yml` line 11)

The `arcane-url` input is used directly in `curl` calls (line 42: `${ARCANE_URL}/api${path}`) with no validation that it uses HTTPS (or even HTTP). A value like `file:///etc/passwd` or an internal network address like `http://169.254.169.254/latest/meta-data/` could be supplied. The action should validate that the URL starts with `https://` (or at minimum `http://`) and should ideally reject non-HTTPS URLs for an action handling API keys.

### Warnings

**W1. Late masking of API key -- potential exposure window** (`action.sh` line 307, `action.yml` lines 107-108)

The API key is passed via the `env` block in `action.yml` (line 108: `INPUT_ARCANE_API_KEY: ${{ inputs.arcane-api-key }}`). The `::add-mask::` call doesn't happen until line 307 of `action.sh`, which is after several `log_info` calls that print configuration (lines 282-286). If the script were to fail before reaching line 307 (e.g., an unrelated bash error between lines 1-306), or if GitHub's composite action framework logs the environment variables during step setup, the API key would not yet be masked. The mask should be the very first operation in the script, before any other logic or logging. The same applies to the git token (which is not masked at all -- see C1).

**W2. API error responses dumped to stderr may contain secrets** (`action.sh` line 57)

When an API call fails, `cat "${tmp_body}" >&2` dumps the entire response body. API error responses sometimes echo back request headers or body content, which could include the API key (sent in `X-Api-Key` header) or the git token (sent in JSON payloads). This output will appear in workflow logs. The response body should be sanitized or truncated before logging.

**W3. Path traversal / injection via `compose-dir` and `compose-files`** (`action.sh` lines 8-9, 82, 91)

The `compose-dir` input is concatenated into a `find` command target path (line 91) and the `compose-files` values are used as-is. While `find` itself is not vulnerable to injection here (it's not passed through `eval`), a path like `../../etc` could cause the action to scan outside the repository workspace. Similarly, the compose file paths are sent to the Arcane API, and a crafted path could potentially cause Arcane to read unexpected files from the repository. Consider validating that resolved paths stay within `$GITHUB_WORKSPACE`.

**W4. No input sanitization for values written to `GITHUB_OUTPUT`** (`action.sh` lines 340-342)

The values for `syncs-created`, `syncs-updated`, and `repository-id` are written to `$GITHUB_OUTPUT`. While `syncs-created` and `syncs-updated` are controlled integers, `repository-id` comes from an API response parsed through `jq`. If the API were compromised, a crafted `id` value containing newlines could inject additional output parameters. Using the heredoc delimiter pattern for GITHUB_OUTPUT would be safer.

**W5. `sync-interval` is not validated as a number** (`action.sh` line 16, line 203)

`SYNC_INTERVAL` comes from user input and is passed to `jq` with `--argjson` (line 203). If a non-numeric value is supplied, `jq` will fail, but a crafted JSON literal (e.g., `{"__proto__":1}`) could potentially be injected since `--argjson` parses its value as JSON. The input should be validated as a positive integer before use.

**W6. `curl` does not enforce HTTPS** (`action.sh` line 47)

The `curl` calls do not use `--proto '=https'` to enforce HTTPS-only connections. While the URL is user-configured, adding `--proto '=https'` (or at least validating the URL scheme) would prevent accidental or malicious use of plaintext HTTP, which would expose the API key in transit. The `claude-auth` action uses `--proto "=https"` in its Doppler curl call (claude-auth `action.sh` line 75), setting a precedent in this repository.

### Good Practices

**G1. `set -euo pipefail` is used** (`action.sh` line 2) -- This ensures the script fails fast on errors, unset variables, and pipe failures. This is stricter than the `claude-auth` action which only uses `set -e`.

**G2. `jq --arg` is used for JSON construction** (`action.sh` lines 139, 148-150, 160-165, 187-189, 198-203, 225-231) -- All user-controlled values are passed to `jq` via `--arg`, which properly escapes them as JSON strings. This prevents JSON injection. This is a strong security pattern.

**G3. API key is masked (even if late)** (`action.sh` line 307) -- The `::add-mask::` workflow command is used for the API key, which prevents it from appearing in subsequent log output.

**G4. Temp files are cleaned up** (`action.sh` lines 58, 63) -- The `arcane_api` function creates a temp file and removes it in both the error and success paths.

**G5. `find -print0` with `read -d ''` for safe filename handling** (`action.sh` lines 88-96) -- Null-delimited output from `find` is correctly consumed, preventing issues with spaces or special characters in file paths.

**G6. No use of `eval` or unsafe shell expansion** -- The script avoids `eval`, backtick command substitution, and unquoted variable expansions in dangerous positions. Variables are consistently double-quoted.

## References

- `/home/user/github-actions/.github/actions/arcane-deploy/action.sh` -- Main deployment script (all line references above)
- `/home/user/github-actions/.github/actions/arcane-deploy/action.yml` -- Composite action definition, env block at lines 106-121
- `/home/user/github-actions/.github/actions/claude-auth/action.sh` -- Reference action for security pattern comparison (masking at line 179, `--proto "=https"` at line 75)
- GitHub Security Advisory: [Untrusted input flowing into GITHUB_ENV](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#using-an-intermediate-environment-variable)
- GitHub Docs: [Understanding the risk of script injections](https://docs.github.com/en/actions/security-for-github-actions/security-guides/security-hardening-for-github-actions#understanding-the-risk-of-script-injections)
