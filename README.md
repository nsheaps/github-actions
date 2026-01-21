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
