# nsheaps/github-actions

Shared GitHub Actions and reusable workflows for the nsheaps organization.

## Actions

### Authentication Actions

#### `github-app-auth`

Authenticate as a GitHub App and configure git user settings for automated commits.

```yaml
- name: Authenticate as GitHub App
  uses: nsheaps/github-actions/.github/actions/github-app-auth@main
  with:
    app-id: ${{ secrets.AUTOMATION_GITHUB_APP_ID }}
    private-key: ${{ secrets.AUTOMATION_GITHUB_APP_PRIVATE_KEY }}
```

**Outputs:**

- `token` - GitHub App token
- `app-slug` - GitHub App slug name
- `user-id` - Bot user ID
- `user-name` - Bot user name (slug with [bot] suffix)

#### `claude-auth`

Authenticate with Claude API using various secret providers (Doppler, 1Password, or raw secrets).

```yaml
# Using raw secrets (GitHub Secrets)
- name: Authenticate with Claude
  uses: nsheaps/github-actions/.github/actions/claude-auth@main
  with:
    provider: raw
    api-key: ${{ secrets.ANTHROPIC_API_KEY }}

# Using Doppler
- name: Authenticate with Claude
  uses: nsheaps/github-actions/.github/actions/claude-auth@main
  with:
    provider: doppler
    doppler-token: ${{ secrets.DOPPLER_TOKEN }}
    doppler-project: my-project
    doppler-config: prd

# Using 1Password
- name: Authenticate with Claude
  uses: nsheaps/github-actions/.github/actions/claude-auth@main
  with:
    provider: 1password
    onepassword-service-account-token: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
    onepassword-vault: Engineering
    onepassword-item: Claude API Key
```

### Claude Code Actions

#### `claude-debug`

Extract debugging information from Claude Code CLI sessions.

```yaml
- name: Get Claude Code Debug Info
  uses: nsheaps/github-actions/.github/actions/claude-debug@main
  id: debug
  with:
    continue: true
    extract-logs: true

- name: Display Session ID
  run: echo "Session ID: ${{ steps.debug.outputs.session-id }}"
```

#### `claude-stream-shim`

Beautify `anthropics/claude-code-action` output by streaming Claude's
`stream-json` through `claude-stream` (from `nsheaps/claude-utils`) so the
workflow log shows a live chatroom view as Claude works. Installs the
`claude` CLI and `claude-stream`, then writes a shim binary that tees
Claude's stdout through `claude-stream` to stderr. Set
`show_full_output: false` on the underlying action so the raw JSON dump
is suppressed and only the chatroom view appears.

> [!NOTE]
> `claude-code-action@v1` calls the Claude Agent SDK in-process and does not
> exercise `path_to_claude_code_executable`, so this shim is presently a
> no-op against v1. Use `claude-stream-tail` (below) with
> `qoomon/actions--parallel-steps@v1` to get a live chatroom view against v1.

```yaml
- name: Setup Claude stream shim
  uses: nsheaps/github-actions/.github/actions/claude-stream-shim@main
  id: shim

- name: Run Claude Code
  uses: anthropics/claude-code-action@v1
  with:
    path_to_claude_code_executable: ${{ steps.shim.outputs.shim-path }}
    show_full_output: false
    # ... rest of inputs unchanged
```

**Outputs:**

- `shim-path` - Absolute path to the shim binary
- `real-claude-path` - Absolute path to the underlying `claude` binary

#### `claude-stream-tail`

Sidecar action that pretty-prints a live Claude Code session as a chatroom
view in the workflow log. Waits for a fresh session JSONL to appear under
`~/.claude/projects/`, tails it through `claude-stream`, and exits when
the SDK writes its terminal `result` message (or on timeout).

Designed to run in parallel with `anthropics/claude-code-action@v1` via
`qoomon/actions--parallel-steps@v1`, since v1 uses the Claude Agent SDK
in-process and no longer spawns the `claude` CLI (making CLI-wrapper
approaches impossible).

```yaml
- name: Run review + live chatroom in parallel
  uses: qoomon/actions--parallel-steps@v1
  with:
    steps: |
      - uses: anthropics/claude-code-action@v1
        id: review
        with:
          show_full_output: false
          # ... rest of claude-code-action inputs
      - uses: nsheaps/github-actions/.github/actions/claude-stream-tail@main
        id: chatroom
```

**Inputs:**

- `claude-utils-version` - Tag of `nsheaps/claude-utils` to install (default `0.12.13`)
- `timeout-seconds` - Max seconds to wait for / follow the session (default `1800`)
- `poll-interval-seconds` - Polling cadence while waiting for session file (default `1`)
- `projects-dir` - Override for the SDK projects directory (default `$HOME/.claude/projects`)

#### `interpolate-prompt`

Read a prompt template file and interpolate environment variables using envsubst.

```yaml
- name: Interpolate prompt template
  uses: nsheaps/github-actions/.github/actions/interpolate-prompt@main
  id: prompt
  with:
    template-file: .github/prompts/code-review.md

- name: Use interpolated prompt
  run: echo "${{ steps.prompt.outputs.prompt }}"
```

### Deployment Actions

#### `arcane-deploy`

Deploy Docker Compose stacks to [Arcane](https://github.com/getarcaneapp/arcane) via GitOps sync. Auto-discovers compose files and creates/updates syncs. See [action README](.github/actions/arcane-deploy/README.md) for full docs.

```yaml
- name: Deploy stacks to Arcane
  uses: nsheaps/github-actions/.github/actions/arcane-deploy@main
  with:
    arcane-url: ${{ secrets.ARCANE_URL }}
    arcane-api-key: ${{ secrets.ARCANE_API_KEY }}
    environment-id: '1'
    compose-dir: stacks
    git-token: ${{ secrets.REPO_TOKEN }}
```

### Secret Management Actions

#### `1password-secret-sync`

Sync secrets from 1Password to GitHub repository secrets. Reads a YAML config defining source `op://` URIs and target repos. Supports dry-run mode for validation.

```yaml
- name: Sync 1Password secrets to GitHub
  uses: nsheaps/github-actions/.github/actions/1password-secret-sync@main
  with:
    config-file: .github/secret-sync.yaml
    op-service-account-token: ${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}
    github-token: ${{ secrets.SECRET_SYNC_PAT }}
    dry-run: 'false'
```

**Outputs:**

- `synced-count` - Number of secrets successfully synced
- `skipped-count` - Number of secrets skipped (dry-run or errors)

### Security Linter Actions

All security linters are designed to run in parallel for comprehensive security scanning.

| Action            | Description                             |
| ----------------- | --------------------------------------- |
| `lint-checkov`    | IaC security scanner                    |
| `lint-gitleaks`   | Secret detection in git history         |
| `lint-grype`      | Vulnerability scanner                   |
| `lint-kics`       | Checkmarx IaC scanner (Docker-based)    |
| `lint-secretlint` | Secret detection using secretlint       |
| `lint-syft`       | SBOM generation (CycloneDX format)      |
| `lint-trivy`      | Vulnerability scanner + SBOM generation |
| `lint-trufflehog` | Filesystem secret detection             |

Example usage with parallel execution:

```yaml
- name: Install mise and tools
  uses: jdx/mise-action@v2
  with:
    install_args: 'grype trivy syft gitleaks trufflehog checkov aqua:secretlint/secretlint'

- name: Run security linters
  uses: qoomon/actions--parallel-steps@v1
  with:
    steps: |
      - uses: nsheaps/github-actions/.github/actions/lint-secretlint@main
      - uses: nsheaps/github-actions/.github/actions/lint-syft@main
      - uses: nsheaps/github-actions/.github/actions/lint-trivy@main
      - uses: nsheaps/github-actions/.github/actions/lint-trufflehog@main
      - uses: nsheaps/github-actions/.github/actions/lint-checkov@main
      - uses: nsheaps/github-actions/.github/actions/lint-kics@main
      - uses: nsheaps/github-actions/.github/actions/lint-grype@main
      - uses: nsheaps/github-actions/.github/actions/lint-gitleaks@main
```

## Local Development

This repository uses [mise](https://mise.jdx.dev/) for tool management.

```bash
# Install mise (if not already installed)
curl https://mise.run | sh

# Install tools
mise install

# Run formatters
mise run format
```

## CI/CD

The repository includes a check workflow (`.github/workflows/check.yaml`) that runs:

1. **Format Job**: Auto-formats code and commits fixes
2. **Security Job**: Runs all 8 security linters in parallel

## Configuration Files

- `mise.toml` - Tool versions and task definitions
- `.editorconfig` - Editor formatting rules
- `.prettierrc` - Prettier configuration
- `.secretlintrc.json` - Secretlint rules
- `.trufflehog-exclude` - TruffleHog exclusion patterns

## License

MIT
