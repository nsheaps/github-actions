# Open PR If Needed

Idempotently open a pull request between two branches that already exist on the remote.

This is the nsheaps-org composite action for the "create PR if not already open" pattern, extracted from [`nsheaps/.github/.github/workflows/sync-repo-settings.yaml`](https://github.com/nsheaps/.github/blob/main/.github/workflows/sync-repo-settings.yaml) per Nate's review on [nsheaps/github-actions#48](https://github.com/nsheaps/github-actions/pull/48).

## What it does

1. Checks whether a PR is already open for `head` -> `base`. If so, returns its number/URL and exits successfully (`result=existing`).
2. Otherwise, composes a PR body that appends `Workflow run: <server_url>/<repo>/actions/runs/<run_id>` so reviewers can trace back to the triggering run (the nsheaps convention — see `check.yaml` in this repo).
3. Calls `gh pr create`. If `gh` fails because there is no diff between head and base, the action treats that as a no-op (`result=nodiff`) instead of erroring.

## Inputs

| Input       | Required | Default                 | Description                                                                            |
| ----------- | -------- | ----------------------- | -------------------------------------------------------------------------------------- |
| `title`     | yes      | —                       | PR title                                                                               |
| `body`      | yes      | —                       | PR body. A `Workflow run: <url>` line is appended automatically.                       |
| `base`      | yes      | —                       | Base branch (the branch to merge INTO)                                                 |
| `head`      | yes      | —                       | Head branch (the branch to merge FROM)                                                 |
| `repo`      | no       | `${{ github.repository }}` | Target repo in `OWNER/REPO` form                                                    |
| `token`     | yes      | —                       | GitHub token with `pull-requests: write` + `contents: read` on the target repo         |
| `labels`    | no       | `''`                    | Comma-separated labels to apply to the PR                                              |
| `reviewers` | no       | `''`                    | Comma-separated GitHub usernames to request review from                                |

## Outputs

| Output      | Description                                                                                                |
| ----------- | ---------------------------------------------------------------------------------------------------------- |
| `pr-number` | Number of the PR (existing or newly opened). Empty when `result=nodiff`.                                   |
| `pr-url`    | URL of the PR (existing or newly opened). Empty when `result=nodiff`.                                      |
| `result`    | `existing` (PR was already open), `opened` (new PR was created), or `nodiff` (no PR because there is no diff). |

## Example

```yaml
- name: Open PR if direct sync could not push
  if: steps.sync.outcome == 'failure'
  uses: nsheaps/github-actions/.github/actions/open-pr-if-needed@main
  with:
    title: "sync: ${{ matrix.upstream }} -> ${{ matrix.target }}"
    body: |
      Automated sync could not fast-forward `${{ matrix.target }}` from `${{ matrix.upstream }}`
      (diverged history or branch protection). Merging via PR instead.
    base: ${{ matrix.target }}
    head: ${{ matrix.upstream }}
    token: ${{ secrets.GITHUB_TOKEN }}
```

## Pre-conditions

- Both `head` and `base` branches must already exist on the remote. This action does NOT push commits — it only opens a PR between two existing branches. For the "commit local changes then open PR" pattern, use [`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request) instead.
- The token must have `pull-requests: write` permission on the target repo.

## See also

- [`peter-evans/create-pull-request`](https://github.com/peter-evans/create-pull-request) — for the "commit local changes + open PR" pattern (used in `sync-repo-settings.yaml`).
- `.github/workflows/sync-main-to-edge.yaml` in this repo — the original consumer.
