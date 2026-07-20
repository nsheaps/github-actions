#!/usr/bin/env bash
# Lightweight test harness for action.sh.
#
# This repo has no bats/shellspec setup, so this is a plain bash script:
# it stubs out `curl` (the only thing action.sh shells out to for the
# actual GitHub API calls) with a recorder, runs action.sh against fixture
# settings.yml files, and asserts on the calls made (or not made) and on
# exit codes. Run directly: `.github/actions/apply-repo-settings/test.sh`
# (requires mikefarah/yq + jq on PATH, same as action.sh itself).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_SH="$SCRIPT_DIR/action.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok - $*"; }
fail() {
  FAIL=$((FAIL + 1))
  echo "  not ok - $*"
}

# assert_contains NEEDLE HAYSTACK LABEL
assert_contains() {
  local needle="$1" haystack="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (expected to find: $needle)"
    echo "    --- haystack ---"
    echo "$haystack" | sed 's/^/    /'
  fi
}

# assert_not_contains NEEDLE HAYSTACK LABEL
assert_not_contains() {
  local needle="$1" haystack="$2" label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label (expected NOT to find: $needle)"
  fi
}

# assert_eq ACTUAL EXPECTED LABEL
assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected [$expected], got [$actual])"
  fi
}

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

MOCK_BIN="$TMPDIR/bin"
mkdir -p "$MOCK_BIN"
export MOCK_CURL_LOG="$TMPDIR/curl.log"

# Fake `curl` that records every call action.sh's `api()` helper makes and
# returns a canned response, so no real network call ever happens. Supports
# forcing a failure via MOCK_CURL_FORCE_STATUS (used by the permission-denied
# test case below).
cat >"$MOCK_BIN/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
method="GET"
url=""
body=""
outfile="/dev/null"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) shift 2 ;;
    -w) shift 2 ;;
    -d) body="$2"; shift 2 ;;
    -o) outfile="$2"; shift 2 ;;
    -s) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done

echo "${method} ${url} ${body}" >>"$MOCK_CURL_LOG"

if [[ -n "${MOCK_CURL_FORCE_STATUS:-}" ]]; then
  echo "${MOCK_CURL_FORCE_BODY:-{}}" >"$outfile"
  printf '%s' "$MOCK_CURL_FORCE_STATUS"
  exit 0
fi

case "$url" in
  */collaborators/*) echo -n "" >"$outfile"; printf '204' ;;
  *) echo '{}' >"$outfile"; printf '200' ;;
esac
MOCK_CURL
chmod +x "$MOCK_BIN/curl"

run_action() {
  # run_action SETTINGS_FILE SECTIONS [extra env assignments...]
  local settings_file="$1" sections="$2"
  shift 2
  : >"$MOCK_CURL_LOG"
  (
    cd "$TMPDIR"
    export PATH="$MOCK_BIN:$PATH"
    export GH_TOKEN="fake-token"
    export OWNER="acme"
    export REPO="widgets"
    export SETTINGS_FILE="$settings_file"
    export DRY_RUN="false"
    export SECTIONS="$sections"
    export GITHUB_OUTPUT="$TMPDIR/github_output"
    export GITHUB_STEP_SUMMARY="$TMPDIR/github_step_summary"
    : >"$GITHUB_OUTPUT"
    : >"$GITHUB_STEP_SUMMARY"
    for assignment in "$@"; do
      export "${assignment?}"
    done
    "$ACTION_SH"
  )
}

echo "### collaborators: applies each {username, permission} entry via PUT"
cat >"$TMPDIR/settings-collaborators.yml" <<'YAML'
collaborators:
  - username: alice
    permission: push
  - username: bob
    permission: admin
YAML

if run_action "settings-collaborators.yml" "collaborators" >"$TMPDIR/out.log" 2>&1; then
  log="$(cat "$MOCK_CURL_LOG")"
  assert_contains "PUT https://api.github.com/repos/acme/widgets/collaborators/alice {\"permission\":\"push\"}" "$log" \
    "PUT issued for alice with permission=push"
  assert_contains "PUT https://api.github.com/repos/acme/widgets/collaborators/bob {\"permission\":\"admin\"}" "$log" \
    "PUT issued for bob with permission=admin"
  summary="$(grep '^summary=' "$TMPDIR/github_output" | sed 's/^summary=//')"
  assert_contains '"collaborators_applied":["alice","bob"]' "$summary" "summary output lists both usernames"
else
  fail "action.sh exited non-zero for a valid collaborators block"
  cat "$TMPDIR/out.log" | sed 's/^/    /'
fi

echo "### collaborators: opt-in only — default sections does not touch collaborators"
if run_action "settings-collaborators.yml" "repository,rulesets" >"$TMPDIR/out.log" 2>&1; then
  log="$(cat "$MOCK_CURL_LOG")"
  assert_not_contains "/collaborators/" "$log" \
    "no collaborators PUT issued when sections=repository,rulesets (default) even though the block exists"
else
  fail "action.sh exited non-zero on default sections with a collaborators block present"
  cat "$TMPDIR/out.log" | sed 's/^/    /'
fi

echo "### collaborators: no collaborators block + section requested → no-op, not an error"
cat >"$TMPDIR/settings-empty.yml" <<'YAML'
repository:
  private: true
YAML
if run_action "settings-empty.yml" "repository,rulesets,collaborators" >"$TMPDIR/out.log" 2>&1; then
  log="$(cat "$MOCK_CURL_LOG")"
  assert_not_contains "/collaborators/" "$log" \
    "no collaborators PUT issued when there's no collaborators: block"
else
  fail "action.sh exited non-zero when collaborators is requested but absent from settings.yml"
  cat "$TMPDIR/out.log" | sed 's/^/    /'
fi

echo "### collaborators: missing 'permission' field fails loudly instead of silently skipping"
cat >"$TMPDIR/settings-bad.yml" <<'YAML'
collaborators:
  - username: carol
YAML
if run_action "settings-bad.yml" "collaborators" >"$TMPDIR/out.log" 2>&1; then
  fail "action.sh should have exited non-zero on a collaborators entry missing 'permission'"
else
  assert_contains "missing required 'permission'" "$(cat "$TMPDIR/out.log")" \
    "clear error message on missing 'permission'"
fi

echo "### collaborators: API error (e.g. token lacking Administration:write) propagates as a failure"
if MOCK_CURL_FORCE_STATUS=403 MOCK_CURL_FORCE_BODY='{"message":"Resource not accessible by integration"}' \
  run_action "settings-collaborators.yml" "collaborators" >"$TMPDIR/out.log" 2>&1; then
  fail "action.sh should have exited non-zero when the collaborators PUT returns 403"
else
  assert_contains "HTTP 403" "$(cat "$TMPDIR/out.log")" \
    "403 from the collaborators PUT surfaces in the error annotation, not swallowed"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
