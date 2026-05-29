# apply-repo-settings

An ephemeral, in-workflow alternative to the [repository-settings GitHub App](https://github.com/repository-settings/app).

Reads `.github/settings.yml` from the current repo and applies the supported sections to the target repo via the GitHub API, using a GitHub App token (so the action runs only when invoked — no always-on bot, no third-party service).

## Why not self-host the upstream app?

The upstream app is a Probot webhook server — it's designed to listen for `push` events on a long-running process. Adapting it for ephemeral one-shot runs is more invasive than building a minimal applier from scratch. This action covers the two sections we actually use (`repository:` config and `rulesets:`) in ~170 lines of bash + `gh api`. Other sections (`labels`, `collaborators`, `teams`, `environments`, legacy `branches`) are not yet implemented — labels are managed via a separate sync today.

## Inputs

| Input           | Required | Default                | Description                                                                                                           |
| --------------- | -------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `token`         | yes      | —                      | GitHub token with `Administration: write` on the target repo (typically from `checkout-as-app` or `github-app-auth`). |
| `owner`         | no       | current owner          | Target repo owner.                                                                                                    |
| `repo`          | no       | current repo           | Target repo name.                                                                                                     |
| `settings-file` | no       | `.github/settings.yml` | Path to the YAML to apply.                                                                                            |
| `dry-run`       | no       | `false`                | Print what would change without applying.                                                                             |
| `sections`      | no       | `repository,rulesets`  | Comma-separated section names to apply.                                                                               |

The action does **not** do any templating or placeholder substitution on `settings-file` — it applies the YAML as-is. If you need env-var-based substitution (e.g. resolving a GitHub App ID into `bypass_actors[].actor_id`), render the file upstream (e.g. with `envsubst`) before invoking this action.

## Outputs

- `summary` — JSON object: `{ repository, rulesets_created, rulesets_updated, rulesets_unchanged }`.

## Setting up the GitHub App

Use the hosted setup helper:

**→ https://nsheaps.github.io/github-actions/?preset=apply-repo-settings**

It builds a [GitHub App manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest) with exactly the permissions this action needs (`administration:write` + `contents:read` + `metadata:read`), submits to `github.com/.../apps/new`, then exchanges the returned code for the App ID + private key client-side. The page is generic — a dropdown selects which app to create (preset auto-selected via the `?preset=` qparam above; every form field also supports query-param prefill, e.g. `&org=nsheaps&appname=my-settings-app`). Accordion sections cover hosting, troubleshooting, and a no-manifest manual setup path.

Source: [`pages/index.html`](../../../pages/index.html). Deployed by [`.github/workflows/pages.yaml`](../../workflows/pages.yaml).

After creating the app:

1. Install it on every repo you want to manage.
2. Add `APPLY_REPO_SETTINGS_APP_ID` and `APPLY_REPO_SETTINGS_PRIVATE_KEY` as secrets (consumed by `checkout-as-app` / `github-app-auth` — this action only takes the resulting token).

## Example workflow

```yaml
name: Apply Repo Settings

on:
  workflow_dispatch:
    inputs:
      dry-run:
        description: "Render only; don't apply"
        type: boolean
        default: false
  repository_dispatch:
    types: [apply-repo-settings]
  push:
    branches: [main]
    paths:
      - '.github/settings.yml'

permissions:
  contents: read

jobs:
  apply:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout as GitHub App
        id: checkout
        uses: nsheaps/github-actions/.github/actions/checkout-as-app@main
        with:
          app-id: ${{ secrets.APPLY_REPO_SETTINGS_APP_ID }}
          private-key: ${{ secrets.APPLY_REPO_SETTINGS_PRIVATE_KEY }}
      - uses: nsheaps/github-actions/.github/actions/apply-repo-settings@main
        with:
          token: ${{ steps.checkout.outputs.token }}
          dry-run: ${{ inputs.dry-run || false }}
```

## What it actually does

- **`repository:` block** → single `PATCH /repos/{owner}/{repo}` with the JSON body of `.repository`.
- **`rulesets:` list** → lists current rulesets, then for each entry in the YAML:
  - if no ruleset with that name exists → `POST /repos/{owner}/{repo}/rulesets`
  - if one exists and content matches → no-op (logged as `unchanged`)
  - if one exists and content differs → `PUT /repos/{owner}/{repo}/rulesets/{id}`

Rulesets that exist on the repo but are absent from the YAML are **not deleted** (safer default — repos may have UI-created rulesets we don't want to wipe). If you want destructive sync, add a `--prune` mode in a follow-up.

## Limitations

- The upstream repository-settings app reads from the default branch only. This action reads from the workflow's checkout, so it works on any branch — useful for testing changes in a PR before merging.
- No support yet for `labels`, `collaborators`, `teams`, `environments`. Those are tracked separately.
- `bypass_actors[].actor_id` for `RepositoryRole` must be the role's numeric ID (community-documented: 1=read, 2=triage, 3=write, 4=maintain, 5=admin). Custom roles have user-assigned IDs.
