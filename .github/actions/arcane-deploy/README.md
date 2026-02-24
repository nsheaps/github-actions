# Arcane Docker Compose Deploy

Deploy Docker Compose stacks to [Arcane](https://github.com/getarcaneapp/arcane) via GitOps sync. Automatically discovers compose files and creates or updates syncs in Arcane — no manual git sync setup required.

## Features

- Auto-discover compose files from a directory
- Explicit compose file list for full control
- Creates the git repository in Arcane if it doesn't exist
- Creates or updates gitops syncs (never deletes)
- Workflow environment variables for subsequent steps
- Triggers immediate sync after changes

## Usage

**Directory scan** — automatically finds compose files in a directory:

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

**Explicit file list** — deploy specific compose files:

```yaml
- name: Deploy stacks to Arcane
  uses: nsheaps/github-actions/.github/actions/arcane-deploy@main
  with:
    arcane-url: ${{ secrets.ARCANE_URL }}
    arcane-api-key: ${{ secrets.ARCANE_API_KEY }}
    environment-id: '1'
    compose-files: |
      services/web/compose.yml
      services/api/compose.yml
      services/db/compose.yml
    git-token: ${{ secrets.REPO_TOKEN }}
```

**With workflow environment variables** (available to subsequent steps, not inside containers):

```yaml
- name: Deploy stacks to Arcane
  uses: nsheaps/github-actions/.github/actions/arcane-deploy@main
  with:
    arcane-url: ${{ secrets.ARCANE_URL }}
    arcane-api-key: ${{ secrets.ARCANE_API_KEY }}
    environment-id: '1'
    compose-dir: stacks
    git-token: ${{ secrets.REPO_TOKEN }}
    env-vars: |
      DOMAIN=example.com
      NETWORK=traefik
      TZ=America/New_York
```

## Inputs

| Input              | Required | Default               | Description                                                                     |
| ------------------ | -------- | --------------------- | ------------------------------------------------------------------------------- |
| `arcane-url`       | Yes      |                       | Base URL of the Arcane instance                                                 |
| `arcane-api-key`   | Yes      |                       | API key (from Arcane Settings > API Keys)                                       |
| `environment-id`   | Yes      |                       | Arcane environment ID                                                           |
| `compose-dir`      | No       |                       | Directory to scan for compose files                                             |
| `compose-files`    | No       |                       | Newline-separated list of compose file paths                                    |
| `repository-url`   | No       | GitHub repo HTTPS URL | Git URL for Arcane to clone                                                     |
| `repository-name`  | No       | GitHub repo name      | Display name in Arcane                                                          |
| `branch`           | No       | Triggering branch     | Branch to sync from                                                             |
| `auth-type`        | No       | `http`                | Git auth type: `none` or `http`                                                 |
| `git-token`        | No       |                       | Token for HTTP git auth. Required when auth-type=http.                          |
| `auto-sync`        | No       | `true`                | Enable Arcane auto-sync polling                                                 |
| `sync-interval`    | No       | `5`                   | Minutes between auto-sync polls                                                 |
| `trigger-sync`     | No       | `true`                | Trigger immediate sync after create/update                                      |
| `sync-name-prefix` | No       | GitHub repo name      | Prefix for sync names in Arcane                                                 |
| `env-vars`         | No       |                       | Runner env vars (`KEY=VALUE` per line) for subsequent steps. Values are masked. |

## Outputs

| Output          | Description                      |
| --------------- | -------------------------------- |
| `syncs-created` | Number of new syncs created      |
| `syncs-updated` | Number of existing syncs updated |
| `repository-id` | Arcane git repository ID used    |

## How It Works

1. **Discovers** compose files from `compose-dir` (scanning for `compose.y[a]ml` / `docker-compose.y[a]ml`) and/or the explicit `compose-files` list
2. **Ensures** a git repository exists in Arcane matching your repo URL (creates one if needed, updates credentials if it already exists)
3. **Upserts** a gitops sync for each compose file — matched by compose path + repository ID, so re-runs are idempotent
4. **Triggers** an immediate sync on each stack (unless `trigger-sync` is `false`)

Sync names are derived from the compose file's parent directory: `stacks/myapp/compose.yml` becomes `<prefix>-myapp`.
