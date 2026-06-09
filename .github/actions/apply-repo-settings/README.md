# apply-repo-settings

An ephemeral, in-workflow alternative to the [repository-settings GitHub App](https://github.com/repository-settings/app).

Reads `.github/settings.yml` from the current repo and applies the supported sections to the target repo via the GitHub API, using a GitHub App token (so the action runs only when invoked — no always-on bot, no third-party service).

It also runs in reverse: with `mode: export` it reads the repo's **live** state and writes it back into `settings.yml`, so manual changes made in the GitHub UI can be captured back into source control (see [Reverse sync](#reverse-sync-mode-export) below).

Supported sections: `repository`, `rulesets`, `labels`, `collaborators`, `teams`. **Apply is non-destructive for every section** — it creates/updates what's listed but never deletes rulesets/labels or revokes collaborator/team access that exists on the repo but isn't in `settings.yml`. (A future opt-in prune mode will let `settings.yml` be authoritative per section.) Not modeled: `environments` and classic branch protection (`branches:`) — this org uses rulesets.

## Why not self-host the upstream app?

The upstream app is a Probot webhook server — it's designed to listen for `push` events on a long-running process. Adapting it for ephemeral one-shot runs is more invasive than building a minimal applier from scratch. This action covers the sections we use in bash + `gh api`. The `labels` section **replaces** the previous `github-label-sync` flow — org-standard labels now live in the org settings template and flow through the same per-repo `settings.yml` pipeline as everything else.

## Inputs

| Input           | Required | Default                                          | Description                                                                                                           |
| --------------- | -------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- |
| `token`         | yes      | —                                                | GitHub token with `Administration: write` on the target repo (typically from `checkout-as-app` or `github-app-auth`). |
| `owner`         | no       | current owner                                    | Target repo owner.                                                                                                    |
| `repo`          | no       | current repo                                     | Target repo name.                                                                                                     |
| `settings-file` | no       | `.github/settings.yml`                           | Path to the YAML to apply (or write, in export mode).                                                                 |
| `dry-run`       | no       | `false`                                          | Print what would change without applying / writing.                                                                   |
| `mode`          | no       | `apply`                                          | `apply` (file → repo) or `export` (repo → file, reverse sync).                                                        |
| `sections`      | no       | `repository,rulesets,labels,collaborators,teams` | Comma-separated section names to sync.                                                                                |

The action does **not** do any templating or placeholder substitution on `settings-file` — it applies the YAML as-is. If you need env-var-based substitution (e.g. resolving a GitHub App ID into `bypass_actors[].actor_id`), render the file upstream (e.g. with `envsubst`) before invoking this action.

## Outputs

- `summary` — JSON object. In `apply` mode: `{ repository, rulesets_created, rulesets_updated, rulesets_unchanged, labels_applied, collaborators_applied, teams_applied }`. In `export` mode: `{ mode, changed, sections }`.
- `changed` — export mode only: `"true"` if `settings-file` was modified, else `"false"`. Empty in apply mode.

## Reverse sync (`mode: export`)

`mode: export` flips the direction: instead of pushing the YAML to the repo, it reads the repo's live state from the API and writes it **back** into `settings-file`, then reports whether the file changed via the `changed` output. This lets a workflow capture changes made directly in the GitHub UI back into source control instead of letting them drift.

- **`rulesets`** → lists `/repos/{owner}/{repo}/rulesets`, fetches each, normalizes to the file's shape (`name`, `target`, `enforcement`, `conditions`, `bypass_actors`, `rules`), and replaces the `.rulesets` array wholesale.
- **`repository`** → reads `/repos/{owner}/{repo}` and updates **only the keys already present** in the file's `.repository` block (so drift on managed keys is captured without introducing keys the repo deliberately omits).
- **`labels`** → reads **every** label on the repo (`/repos/{owner}/{repo}/labels`) and replaces `.labels` with `{ name, color, description }` entries.
- **`collaborators`** → reads **direct** collaborators (`?affiliation=direct`; org-inherited access is left alone) and writes `{ username, permission }`, normalizing `role_name` to a PUT-compatible permission (`read`→`pull`, `write`→`push`).
- **`teams`** → reads teams with repo access and writes `{ name, permission }` where `name` is the team slug (the merger's identity key for teams).

The rest of the file (other top-level keys, the repository keys you don't manage) is preserved. Each touched section is normalized, so inline comments inside it are dropped — fine for an auto-capture that lands as a reviewable commit/diff. Classic branch protection (the legacy `branches:` protection API) and `environments` are **not** exported.

### Auto-capturing live drift

Run export from a workflow, then commit whatever it captured. The canonical wiring triggers export on a push that changes the workflow file (so the captured `settings.yml` lands in the same branch/PR as a preview) and on a weekly schedule (to catch UI ruleset edits that fire no push):

```yaml
on:
  push:
    paths: ['.github/workflows/apply-repo-settings.yaml']
  schedule:
    - cron: '0 0 * * 0'

jobs:
  export:
    runs-on: ubuntu-latest
    steps:
      - uses: nsheaps/github-actions/.github/actions/checkout-as-app@main
        id: checkout
        with:
          app-id: ${{ secrets.AUTOMATION_GITHUB_APP_ID }}
          private-key: ${{ secrets.AUTOMATION_GITHUB_APP_PRIVATE_KEY }}
      - uses: nsheaps/github-actions/.github/actions/apply-repo-settings@main
        id: export
        with:
          token: ${{ steps.checkout.outputs.token }}
          mode: export
          sections: rulesets
      - if: steps.export.outputs.changed == 'true'
        run: |
          git add .github/settings.yml
          git commit -m "chore: sync rulesets into settings.yml"
          git push origin "HEAD:${{ github.ref_name }}"
```

> There is no `repository_ruleset` Actions trigger, so pure UI ruleset edits (with no corresponding push) are caught by the weekly schedule. For immediate ruleset-edit-driven exports, dispatch this action from an org-level ruleset webhook via `repository_dispatch`.

The full wired-up workflow (push/schedule gating + commit-back) lives at [`nsheaps/.github`'s `apply-repo-settings.yaml` template](https://github.com/nsheaps/.github/blob/main/ansible/templates/.github/workflows/apply-repo-settings.yaml).

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
- **`labels:` list** → `POST` to create, `PATCH /repos/{owner}/{repo}/labels/{name}` to update color/description.
- **`collaborators:` list** → `PUT /repos/{owner}/{repo}/collaborators/{username}` with `{ permission }`.
- **`teams:` list** → `PUT /orgs/{owner}/teams/{slug}/repos/{owner}/{repo}` with `{ permission }`.

**Nothing is ever deleted or revoked.** Rulesets, labels, collaborators, and teams that exist on the repo but are absent from the YAML are left untouched (safer default — repos may have UI-created rulesets/labels, and we never want to silently revoke access). A future opt-in prune mode (tracked by `TODO(prune)` markers in `action.sh`) will make `settings.yml` authoritative per section once export is proven.

## Limitations

- The upstream repository-settings app reads from the default branch only. This action reads from the workflow's checkout, so it works on any branch — useful for testing changes in a PR before merging.
- `environments` and classic branch protection (`branches:`) are not supported.
- `collaborators`/`teams` apply needs the App to have `Administration: write` (and org `Members` for teams). Export only reads.
- `bypass_actors[].actor_id` for `RepositoryRole` must be the role's numeric ID (community-documented: 1=read, 2=triage, 3=write, 4=maintain, 5=admin). Custom roles have user-assigned IDs.
