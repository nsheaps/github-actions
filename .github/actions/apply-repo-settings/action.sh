#!/usr/bin/env bash
# Apply Repo Settings — reads SETTINGS_FILE and applies the supported
# top-level sections to {OWNER}/{REPO} via the GitHub API.
#
# Supported sections:
#   repository  → PATCH /repos/{owner}/{repo}
#   rulesets    → POST/PUT/DELETE /repos/{owner}/{repo}/rulesets
#
# Not supported (yet): labels, collaborators, teams, environments, branches.
# Those are handled by other workflows in nsheaps/.github today.

set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${OWNER:?OWNER required}"
: "${REPO:?REPO required}"
: "${SETTINGS_FILE:=.github/settings.yml}"
: "${DRY_RUN:=false}"
: "${SECTIONS:=repository,rulesets}"

if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo "::error file=$SETTINGS_FILE::settings file not found"
  exit 1
fi

log() { echo "::group::$*"; }
endlog() { echo "::endgroup::"; }
info() { echo "  → $*"; }

api() {
  # api METHOD PATH [JSON-BODY]
  # Uses curl to capture the full response body even on errors (gh api only
  # emits a short error message on failure, hiding the JSON validation details).
  local method="$1" path="$2" body="${3:-}"
  local resp_file http_code rc=0
  resp_file=$(mktemp)

  if [[ -n "$body" ]]; then
    http_code=$(curl -s -w "%{http_code}" \
      -X "$method" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "https://api.github.com${path}" \
      -o "$resp_file") || rc=$?
  else
    http_code=$(curl -s -w "%{http_code}" \
      -X "$method" \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com${path}" \
      -o "$resp_file") || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    echo "::error::API $method $path: curl failed (exit $rc)" >&2
    rm -f "$resp_file"
    return $rc
  fi

  local resp_body
  resp_body=$(cat "$resp_file")
  rm -f "$resp_file"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    echo "::error::API $method $path failed (HTTP $http_code): $resp_body" >&2
    return 1
  fi

  echo "$resp_body"
}

want_section() {
  local target="$1"
  [[ ",$SECTIONS," == *",$target,"* ]]
}

###############################################################################
# repository: PATCH /repos/{owner}/{repo}
###############################################################################
apply_repository() {
  log "repository"
  local body
  body="$(yq -o=json '.repository // {}' "$SETTINGS_FILE")"
  if [[ "$body" == "{}" || -z "$body" ]]; then
    info "no repository block, skipping"
    endlog
    REPO_CHANGED="false"
    return
  fi
  info "applying repository config..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "$body" | jq '.'
    REPO_CHANGED="dry-run"
  else
    api PATCH "/repos/${OWNER}/${REPO}" "$body" >/dev/null
    REPO_CHANGED="true"
  fi
  endlog
}

###############################################################################
# rulesets: list existing, then create/update by name.
# We do NOT delete rulesets that aren't in settings.yml (safer default —
# repos may have rulesets created via the UI we don't want to wipe).
###############################################################################
apply_rulesets() {
  log "rulesets"

  local count
  count="$(yq '.rulesets | length // 0' "$SETTINGS_FILE")"
  if [[ "$count" == "0" || "$count" == "null" ]]; then
    info "no rulesets block, skipping"
    endlog
    return
  fi

  # Fetch existing rulesets — map name → id
  local existing
  existing="$(gh api --paginate "/repos/${OWNER}/${REPO}/rulesets" --jq '[.[] | {name, id}]')"
  info "found $(echo "$existing" | jq 'length') existing ruleset(s)"

  local i
  for ((i=0; i<count; i++)); do
    local name body existing_id
    name="$(yq -r ".rulesets[$i].name" "$SETTINGS_FILE")"
    body="$(yq -o=json ".rulesets[$i]" "$SETTINGS_FILE")"

    existing_id="$(echo "$existing" | jq -r --arg n "$name" '.[] | select(.name == $n) | .id // empty')"

    if [[ -z "$existing_id" ]]; then
      info "create: $name"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "$body" | jq '.'
      else
        api POST "/repos/${OWNER}/${REPO}/rulesets" "$body" >/dev/null
      fi
      CREATED+=("$name")
    else
      # Compare current vs desired to decide if PUT is needed.
      local current_norm desired_norm
      current_norm="$(gh api "/repos/${OWNER}/${REPO}/rulesets/${existing_id}" \
        --jq '{name, target, enforcement, conditions, rules, bypass_actors}' \
        | jq -S '.')"
      desired_norm="$(echo "$body" | jq -S '{name, target, enforcement, conditions, rules, bypass_actors}')"
      if [[ "$current_norm" == "$desired_norm" ]]; then
        info "unchanged: $name (id=$existing_id)"
        UNCHANGED+=("$name")
      else
        info "update: $name (id=$existing_id)"
        if [[ "$DRY_RUN" == "true" ]]; then
          diff <(echo "$current_norm") <(echo "$desired_norm") || true
        else
          api PUT "/repos/${OWNER}/${REPO}/rulesets/${existing_id}" "$body" >/dev/null
        fi
        UPDATED+=("$name")
      fi
    fi
  done

  endlog
}

###############################################################################
# main
###############################################################################
CREATED=()
UPDATED=()
UNCHANGED=()
REPO_CHANGED="false"

echo "Applying $SETTINGS_FILE to $OWNER/$REPO (dry-run=$DRY_RUN, sections=$SECTIONS)"

if want_section "repository"; then
  apply_repository
fi

if want_section "rulesets"; then
  apply_rulesets
fi

# Summary
summary="$(jq -nc \
  --arg repo_changed "$REPO_CHANGED" \
  --argjson created  "$(printf '%s\n' "${CREATED[@]:-}"  | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson updated  "$(printf '%s\n' "${UPDATED[@]:-}"  | jq -R . | jq -s 'map(select(length>0))')" \
  --argjson unchanged "$(printf '%s\n' "${UNCHANGED[@]:-}" | jq -R . | jq -s 'map(select(length>0))')" \
  '{repository: $repo_changed, rulesets_created: $created, rulesets_updated: $updated, rulesets_unchanged: $unchanged}'
)"

echo "Summary: $summary"
echo "summary=$summary" >> "$GITHUB_OUTPUT"

# Pretty markdown summary for the run page
{
  echo "## Apply Repo Settings — \`$OWNER/$REPO\`"
  echo
  echo "- **repository**: \`$REPO_CHANGED\`"
  echo "- **rulesets created**: ${#CREATED[@]}${CREATED:+: ${CREATED[*]}}"
  echo "- **rulesets updated**: ${#UPDATED[@]}${UPDATED:+: ${UPDATED[*]}}"
  echo "- **rulesets unchanged**: ${#UNCHANGED[@]}${UNCHANGED:+: ${UNCHANGED[*]}}"
  echo
  echo "Source: \`$SETTINGS_FILE\` · Dry run: \`$DRY_RUN\` · Sections: \`$SECTIONS\`"
} >> "$GITHUB_STEP_SUMMARY"
