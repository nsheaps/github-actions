# apply-repo-settings

An ephemeral, in-workflow alternative to the [repository-settings GitHub App](https://github.com/repository-settings/app).

Reads `.github/settings.yml` from the current repo and applies the supported sections to the target repo via the GitHub API, using a GitHub App token (so the action runs only when invoked — no always-on bot, no third-party service).

## Why not self-host the upstream app?

The upstream app is a Probot webhook server — it's designed to listen for `push` events on a long-running process. Adapting it for ephemeral one-shot runs is more invasive than building a minimal applier from scratch. This action covers `repository:` config, `rulesets:`, and (opt-in) `collaborators:` in a small bash + `gh api` script. Other sections (`labels`, `teams`, `environments`, legacy `branches`) are not yet implemented — labels are managed via a separate sync today.

## Inputs

| Input           | Required | Default                | Description                                                                                                                                                                |
| --------------- | -------- | ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `token`         | yes      | —                      | GitHub token with `Administration: write` on the target repo (typically from `checkout-as-app` or `github-app-auth`).                                                      |
| `owner`         | no       | current owner          | Target repo owner.                                                                                                                                                         |
| `repo`          | no       | current repo           | Target repo name.                                                                                                                                                          |
| `settings-file` | no       | `.github/settings.yml` | Path to the YAML to apply.                                                                                                                                                 |
| `dry-run`       | no       | `false`                | Print what would change without applying.                                                                                                                                  |
| `sections`      | no       | `repository,rulesets`  | Comma-separated section names to apply. `collaborators` is supported but **opt-in only** — it is not in the default (see [What it actually does](#what-it-actually-does)). |

The action does **not** do any templating or placeholder substitution on `settings-file` — it applies the YAML as-is. If you need env-var-based substitution (e.g. resolving a GitHub App ID into `bypass_actors[].actor_id`), render the file upstream (e.g. with `envsubst`) before invoking this action.

## Outputs

- `summary` — JSON object: `{ repository, rulesets_created, rulesets_updated, rulesets_unchanged, collaborators_applied }`.

## Setting up the GitHub App

Use the hosted setup helper:

**→ https://nsheaps.github.io/github-actions/?preset=apply-repo-settings**

It builds a [GitHub App manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest) with exactly the permissions this action needs (`administration:write` + `contents:read` + `metadata:read`), submits to `github.com/.../apps/new`, then exchanges the returned code for the App ID + private key client-side. The page is generic — a dropdown selects which app to create (preset auto-selected via the `?preset=` qparam above; every form field also supports query-param prefill, e.g. `&org=nsheaps&appname=my-settings-app`). Accordion sections cover hosting, troubleshooting, and a no-manifest manual setup path.

Source: [`pages/index.html`](../../../pages/index.html). Deployed by [`.github/workflows/pages.yaml`](../../workflows/pages.yaml).

`PUT /repos/{owner}/{repo}/collaborators/{username}` (used by the `collaborators` section) is documented by GitHub as requiring `Administration: write` on the target repo — the same permission this manifest already grants for `repository`/`rulesets`. No additional app permission is needed to enable `collaborators`.

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
- **`collaborators:` list** (only when `collaborators` is included in `sections` — see below) → for each `{username, permission}` entry, `PUT /repos/{owner}/{repo}/collaborators/{username}` with `{"permission": "<permission>"}`. `permission` is whatever the GitHub API accepts (`pull`, `triage`, `push`, `maintain`, `admin`, or a custom repository role name); this action does not validate it beyond checking it's present — an invalid value surfaces as an API error.

Rulesets that exist on the repo but are absent from the YAML are **not deleted** (safer default — repos may have UI-created rulesets we don't want to wipe). Collaborators absent from the YAML are similarly **not removed** — this action only ever adds/updates, never revokes. If you want destructive sync for either, add a `--prune` mode in a follow-up.

### Why `collaborators` is opt-in, not a default section

`repository` and `rulesets` ship in the default `sections` value, so a repo with no `repository:`/`rulesets:` block in its `settings.yml` sees no behavior change either way — the section is simply skipped. The same is true for `collaborators`. The difference is what happens once a repo's `settings.yml` _does_ gain a `collaborators:` block — for example via the `nsheaps/.github` sync layer's `collaborators` deep-merge, which a repo owner may not have driven themselves. Granting a user push/admin access is a higher-consequence, harder-to-notice change than adding a ruleset, so this action requires each repo to explicitly add `collaborators` to its `sections` input before any `PUT /repos/{owner}/{repo}/collaborators/{username}` call is made. Until a repo opts in, an incoming `collaborators:` block is inert from this action's point of view.

## Limitations

- The upstream repository-settings app reads from the default branch only. This action reads from the workflow's checkout, so it works on any branch — useful for testing changes in a PR before merging.
- No support yet for `labels`, `teams`, `environments`. Those are tracked separately.
- `bypass_actors[].actor_id` for `RepositoryRole` must be the role's numeric ID (community-documented: 1=read, 2=triage, 3=write, 4=maintain, 5=admin). Custom roles have user-assigned IDs.
- `collaborators` only manages **outside collaborators / explicit repo-level access grants** — adding an org member via this call does not add them to the organization, only grants/updates their repo-level permission. It does not touch org membership, invite state, or team-based access.
