---
name: testing-github-actions
description: >
  Use this skill when developing or changing a composite action in this repo
  (nsheaps/github-actions) and you need to PROVE it works end-to-end before
  merging — especially when a new input/output or behavior was added. Covers
  pinning a consumer workflow (e.g. in nsheaps/.github) at the action's feature
  branch or commit SHA, triggering the run, and verifying the new code actually
  executed. Recall it whenever a consumer workflow "passed" but you're not sure
  it exercised your changes, or when you see/expect an "Unexpected input(s)"
  warning. Triggers: "test the action", "prove the action works", "why did the
  workflow pass", "test before merge", "pin action to branch/SHA".
---

# Testing GitHub Actions cross-repo

Actions in this repo are referenced by **other repos** (e.g. `nsheaps/.github`,
`nsheaps/.org`) as `uses: nsheaps/github-actions/.github/actions/<name>@main`.
That `@main` is the crux of testing: a consumer workflow pinned to `@main` runs
the action **as it exists on `main` right now** — i.e. the _pre-merge_ version,
not the code on your branch. Pushing changes to a feature branch does nothing
to what `@main` consumers see.

To test action changes end-to-end you must point a consumer at your branch/SHA.

## The trap: a green check does NOT mean your code ran

GitHub Actions **silently ignores undefined inputs** to an action. If you pass
an input the resolved action version doesn't declare, you get a non-fatal
annotation:

```
Warning: Unexpected input(s) 'mode', valid inputs are ['token', 'owner', ...]
```

The step still runs and **succeeds** — using only the inputs the action does
declare. So if you add a `mode: export` input on a branch, then run a consumer
pinned to `@main` (which has no `mode` yet), the job goes green while running
the _old_ code path and ignoring `mode` entirely. The green check is a false
positive — it proves nothing about your change.

> Real example from this repo: `.github`'s `apply-repo-settings.yaml` passed
> `mode: export` to `apply-repo-settings@main` before the `mode` input was
> merged. The export job "passed" — but `@main` had no `mode` input, so it
> silently ran the old **apply** path. Nothing exported.

**Rule of thumb:** if you changed an action's `inputs`/`outputs`/behavior, a
consumer pinned to `@main` cannot validate it. Pin to your ref first.

## How to test against your branch

1. **Push your action changes** to its feature branch in this repo
   (`nsheaps/github-actions`). Note the branch name or the commit SHA.

2. **Point a consumer workflow at that ref.** In the consuming repo (often
   `nsheaps/.github`), edit every `uses:` line for the action under test:

   ```yaml
   # from:
   - uses: nsheaps/github-actions/.github/actions/apply-repo-settings@main
   # to (branch):
   - uses: nsheaps/github-actions/.github/actions/apply-repo-settings@claude/zealous-heisenberg-wfaxhk
   # or (immutable, preferred for a definitive proof):
   - uses: nsheaps/github-actions/.github/actions/apply-repo-settings@<full-40-char-sha>
   ```

   A branch ref re-resolves on every run (good while iterating). A SHA is
   immutable (good for a final, reproducible proof). Reusable workflows
   (`uses: org/repo/.github/workflows/x.yaml@ref`) pin the same way.

3. **Trigger the consumer.** Use whatever the workflow listens for — push to a
   branch, `workflow_dispatch`, or `repository_dispatch`. Prefer a non-default
   branch / dry-run input so a test run can't mutate production state.

4. **Watch the run and read the logs** (see "Observing runs" below). Don't
   trust the green ✓ alone — open the step and confirm the new behavior.

5. **Verify your inputs were actually accepted** — the key check:
   - **No `Unexpected input(s)` warning** for your new inputs → the resolved
     action version declares them → your version ran.
   - Look for a log line that only your new code path emits (add one if
     needed, e.g. `echo "mode=$MODE"`), and confirm the expected branch ran.
   - Check the step's `outputs` if your change added one.

6. **Revert the pin before merging the consumer.** Change every `uses:` back
   to `@main` (or the next released tag). Shipping a consumer pinned to a
   feature branch is a landmine — the branch gets deleted and the consumer
   breaks. Make reverting part of the consumer PR's final commit.

## Order of operations across repos

Because consumers reference `@main`, the action change must land first:

1. Test the action on its branch via a pinned consumer (steps above).
2. Merge the **action** PR (`nsheaps/github-actions`) to `main`.
3. Re-point consumers to `@main`, confirm green, merge the **consumer** PRs
   (`nsheaps/.github`, which then syncs to managed repos including `.org`).

Never merge a consumer that depends on unreleased action behavior while it's
still pinned to `@main` — it'll run stale code in production.

## Observing runs

Authenticated access is needed to read run logs. With `gh` + a token
(`GH_TOKEN`), from any repo:

```bash
# latest runs of a workflow
gh run list --repo nsheaps/.github --workflow apply-repo-settings.yaml --limit 5
# watch a run to completion
gh run watch --repo nsheaps/.github <run-id>
# full logs (grep for your markers / warnings)
gh run view --repo nsheaps/.github <run-id> --log | grep -iE 'unexpected input|mode=|export'
```

In web sessions the git remote is a local proxy — use `gh api --hostname
github.com ...` or the GitHub MCP tools instead of `gh run` if `gh` isn't
configured for github.com. If no token is available, fall back to the run's
**Actions** page in the GitHub UI and read the step logs there.

## Quick checklist

- [ ] Action change pushed to its branch; SHA/branch noted.
- [ ] Consumer's `uses:` repinned from `@main` to the branch/SHA (every occurrence).
- [ ] Run triggered on a safe branch / with dry-run where possible.
- [ ] Logs show **no** `Unexpected input(s)` warning for new inputs.
- [ ] A log line / output unique to the new code path is present.
- [ ] Consumer repinned back to `@main` before its PR merges.
- [ ] Action PR merged before consumer PR.

## Gotchas

- **Undefined inputs never fail** — only warn. Absence of the warning is your
  signal the right version ran; presence means you're hitting a stale ref.
- **Composite actions are fetched at the pinned ref**, including their own
  internal `uses:` and scripts. Editing a script on your branch only takes
  effect for consumers pinned to that branch.
- **`@main` is a moving target** — a consumer test that passed yesterday can
  break when `main` moves. Pin to a SHA for a stable proof.
- **Don't dry-run-only and call it done** — `dry-run: true` proves the action
  parses inputs and reaches its logic, but not that the real API
  calls/side-effects work. Do at least one non-dry-run on a throwaway target.
