#!/bin/bash
set -euo pipefail

# --- Configuration ---
ARCANE_URL="${INPUT_ARCANE_URL%/}"
API_KEY="${INPUT_ARCANE_API_KEY}"
ENV_ID="${INPUT_ENVIRONMENT_ID}"
COMPOSE_DIR="${INPUT_COMPOSE_DIR:-}"
COMPOSE_FILES_INPUT="${INPUT_COMPOSE_FILES:-}"
REPO_URL="${INPUT_REPOSITORY_URL:-https://github.com/${GITHUB_REPOSITORY}.git}"
REPO_NAME="${INPUT_REPOSITORY_NAME:-${GITHUB_REPOSITORY##*/}}"
BRANCH="${INPUT_BRANCH:-${GITHUB_REF_NAME:-main}}"
AUTH_TYPE="${INPUT_AUTH_TYPE:-http}"
GIT_TOKEN="${INPUT_GIT_TOKEN:-}"
AUTO_SYNC="${INPUT_AUTO_SYNC:-true}"
SYNC_INTERVAL="${INPUT_SYNC_INTERVAL:-5}"
TRIGGER_SYNC="${INPUT_TRIGGER_SYNC:-true}"
ENV_VARS="${INPUT_ENV_VARS:-}"

# [C1/C2] Mask secrets immediately, before any logging or API calls
[[ -n "${API_KEY}" ]] && echo "::add-mask::${API_KEY}"
[[ -n "${GIT_TOKEN}" ]] && echo "::add-mask::${GIT_TOKEN}"

SYNCS_CREATED=0
SYNCS_UPDATED=0
REPOSITORY_ID=""

# --- Helpers ---

log_info() {
  echo "[Arcane Deploy] $1"
}

log_error() {
  echo "::error::[Arcane Deploy] $1"
}

# Trim leading and trailing whitespace from a string.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

# Validate a required input is non-empty.
require_input() {
  local name="$1" value="$2"
  if [[ -z "${value}" ]]; then
    log_error "${name} is required"
    exit 1
  fi
}

# --- API Helper ---
# Make an authenticated API request to Arcane.
# Usage: arcane_api METHOD /path [curl args...]
arcane_api() {
  local method="$1"
  local path="$2"
  shift 2

  local url="${ARCANE_URL}/api${path}"
  local tmp_body
  tmp_body=$(mktemp)

  local http_code
  # [H2] Capture curl exit code separately to detect transport failures
  http_code=$(curl -s -w "%{http_code}" \
    --max-time 30 --connect-timeout 10 \
    -X "${method}" \
    -H "X-Api-Key: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -o "${tmp_body}" \
    "$@" \
    "${url}") || {
    log_error "API ${method} ${path} failed: curl transport error (DNS, timeout, or connection refused)"
    rm -f "${tmp_body}"
    return 1
  }

  # [H2] Guard against empty http_code (should not happen after above, but be safe)
  if [[ -z "${http_code}" ]]; then
    log_error "API ${method} ${path} failed: no HTTP response code received"
    rm -f "${tmp_body}"
    return 1
  fi

  if [[ "${http_code}" -ge 400 ]]; then
    log_error "API ${method} ${path} failed (HTTP ${http_code})"
    cat "${tmp_body}" >&2
    rm -f "${tmp_body}"
    return 1
  fi

  cat "${tmp_body}"
  rm -f "${tmp_body}"
}

# [H7] Extract a jq field and validate it is non-empty and non-"null".
# Usage: jq_extract_id JSON_STRING JQ_FILTER CONTEXT_MSG
# Returns the extracted value on stdout, or returns 1 on failure.
jq_extract_id() {
  local json="$1" filter="$2" context="$3"
  local value
  value=$(echo "${json}" | jq -r "${filter}" 2>/dev/null) || {
    log_error "${context}: failed to parse API response as JSON"
    return 1
  }
  if [[ -z "${value}" || "${value}" == "null" ]]; then
    log_error "${context}: expected a valid ID but got '${value}'"
    return 1
  fi
  echo "${value}"
}

# --- Compose File Discovery ---
discover_compose_files() {
  local files=()

  # From explicit list
  if [[ -n "${COMPOSE_FILES_INPUT}" ]]; then
    while IFS= read -r file; do
      file="$(trim "${file}")"
      [[ -z "${file}" ]] && continue
      files+=("${file}")
    done <<< "${COMPOSE_FILES_INPUT}"
  fi

  # From directory scan
  if [[ -n "${COMPOSE_DIR}" ]]; then
    local search_dir="${GITHUB_WORKSPACE:-.}/${COMPOSE_DIR}"
    if [[ ! -d "${search_dir}" ]]; then
      log_error "compose-dir '${COMPOSE_DIR}' does not exist"
      return 1
    fi

    while IFS= read -r -d '' file; do
      local rel_path="${file#"${GITHUB_WORKSPACE:-.}/"}"
      files+=("${rel_path}")
    done < <(find "${search_dir}" -maxdepth 2 -type f \( \
      -name "docker-compose.yml" -o \
      -name "docker-compose.yaml" -o \
      -name "compose.yml" -o \
      -name "compose.yaml" \
    \) -print0 | sort -z)
  fi

  if [[ ${#files[@]} -eq 0 ]]; then
    log_error "No compose files found. Set compose-dir and/or compose-files."
    return 1
  fi

  # Deduplicate in case compose-dir scan overlaps with explicit compose-files
  local seen=()
  for f in "${files[@]}"; do
    local dup=false
    for s in "${seen[@]+"${seen[@]}"}"; do
      [[ "$s" == "$f" ]] && { dup=true; break; }
    done
    $dup || seen+=("$f")
  done

  printf '%s\n' "${seen[@]}"
}

# --- Sync Naming ---
# Derive a sync name from a compose file path.
# "stacks/myapp/compose.yml" -> "myapp"
sync_name_from_path() {
  basename "$(dirname "$1")"
}

# --- Repository Management ---
# Find an existing Arcane git repository by URL, or create one.
ensure_repository() {
  echo "::group::Ensuring git repository in Arcane"
  log_info "Looking for repository: ${REPO_URL}"

  local repos
  repos=$(arcane_api GET "/customize/git-repositories")

  REPOSITORY_ID=$(echo "${repos}" | jq -r \
    --arg url "${REPO_URL}" \
    '[.[] | select(.url == $url)] | first // empty | .id')

  if [[ -n "${REPOSITORY_ID}" && "${REPOSITORY_ID}" != "null" ]]; then
    log_info "Found existing repository: ${REPOSITORY_ID}"

    # Update credentials so the token stays current
    if [[ "${AUTH_TYPE}" == "http" && -n "${GIT_TOKEN}" ]]; then
      local update_payload
      update_payload=$(jq -n \
        --arg token "${GIT_TOKEN}" \
        '{token: $token}')

      arcane_api PUT "/customize/git-repositories/${REPOSITORY_ID}" \
        -d "${update_payload}" > /dev/null
      log_info "Updated repository credentials"
    fi
  else
    log_info "Creating new repository: ${REPO_NAME}"

    local create_payload
    if [[ "${AUTH_TYPE}" == "http" ]]; then
      create_payload=$(jq -n \
        --arg name "${REPO_NAME}" \
        --arg url "${REPO_URL}" \
        --arg authType "${AUTH_TYPE}" \
        --arg token "${GIT_TOKEN}" \
        '{name: $name, url: $url, authType: $authType, token: $token}')
    else
      create_payload=$(jq -n \
        --arg name "${REPO_NAME}" \
        --arg url "${REPO_URL}" \
        --arg authType "${AUTH_TYPE}" \
        '{name: $name, url: $url, authType: $authType}')
    fi

    local result
    result=$(arcane_api POST "/customize/git-repositories" -d "${create_payload}")

    # [H7] Validate the response contains a real ID
    REPOSITORY_ID=$(jq_extract_id "${result}" '.id' "create repository")
    log_info "Created repository: ${REPOSITORY_ID}"
  fi

  echo "::endgroup::"
}

# --- Sync Management ---
# Create or update a gitops sync for a single compose file.
upsert_sync() {
  local compose_path="$1"
  local sync_name="$2"
  local existing_syncs="$3"

  # Match by compose path + repository ID
  local existing_id
  existing_id=$(echo "${existing_syncs}" | jq -r \
    --arg composePath "${compose_path}" \
    --arg repoId "${REPOSITORY_ID}" \
    '[.[] | select(.composePath == $composePath and .repositoryId == $repoId)] | first // empty | .id')

  local sync_id
  if [[ -n "${existing_id}" && "${existing_id}" != "null" ]]; then
    log_info "  Updating sync ${existing_id} (${sync_name})"

    local update_payload
    update_payload=$(jq -n \
      --arg name "${sync_name}" \
      --arg branch "${BRANCH}" \
      --arg composePath "${compose_path}" \
      --argjson autoSync "${AUTO_SYNC}" \
      --argjson syncInterval "${SYNC_INTERVAL}" \
      '{
        name: $name,
        branch: $branch,
        composePath: $composePath,
        autoSync: $autoSync,
        syncInterval: $syncInterval
      }')

    arcane_api PUT "/environments/${ENV_ID}/gitops-syncs/${existing_id}" \
      -d "${update_payload}" > /dev/null

    SYNCS_UPDATED=$((SYNCS_UPDATED + 1))
    sync_id="${existing_id}"
  else
    log_info "  Creating sync: ${sync_name}"

    local create_payload
    create_payload=$(jq -n \
      --arg name "${sync_name}" \
      --arg repositoryId "${REPOSITORY_ID}" \
      --arg branch "${BRANCH}" \
      --arg composePath "${compose_path}" \
      --arg projectName "${sync_name}" \
      --argjson autoSync "${AUTO_SYNC}" \
      --argjson syncInterval "${SYNC_INTERVAL}" \
      '{
        name: $name,
        repositoryId: $repositoryId,
        branch: $branch,
        composePath: $composePath,
        projectName: $projectName,
        autoSync: $autoSync,
        syncInterval: $syncInterval
      }')

    local result
    result=$(arcane_api POST "/environments/${ENV_ID}/gitops-syncs" -d "${create_payload}")

    # [H7] Validate the response contains a real ID
    sync_id=$(jq_extract_id "${result}" '.id' "create sync '${sync_name}'")
    log_info "  Created sync: ${sync_id}"

    SYNCS_CREATED=$((SYNCS_CREATED + 1))
  fi

  # Deduplicated trigger-sync (was duplicated in both branches)
  if [[ "${TRIGGER_SYNC}" == "true" ]]; then
    log_info "  Triggering sync..."
    if ! arcane_api POST "/environments/${ENV_ID}/gitops-syncs/${sync_id}/sync" > /dev/null; then
      log_info "  Warning: trigger-sync failed for ${sync_name} (sync was still created/updated)"
    fi
  fi
}

# --- Environment Variables ---
# Export variables to the GitHub Actions runner environment ($GITHUB_ENV).
# NOTE: These are CI workflow-scoped variables, NOT Arcane deployment-time variables.
# They are available to subsequent workflow steps, not inside deployed containers.
export_env_vars() {
  if [[ -z "${ENV_VARS}" ]]; then
    return
  fi

  echo "::group::Setting workflow environment variables"
  while IFS= read -r line; do
    line="$(trim "${line}")"
    [[ -z "${line}" ]] && continue
    [[ "${line}" == \#* ]] && continue

    local key="${line%%=*}"
    local value="${line#*=}"

    # [H1] Validate key format to prevent env injection via malformed keys
    if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      log_error "Invalid env-var key: '${key}' (must match [A-Za-z_][A-Za-z0-9_]*)"
      exit 1
    fi

    # [H1] Reject embedded newlines in values to prevent env injection
    if [[ "${value}" == *$'\n'* ]]; then
      log_error "Invalid env-var value for '${key}': embedded newlines are not allowed"
      exit 1
    fi

    # [H1] Mask the value so it does not appear in logs of subsequent steps
    echo "::add-mask::${value}"

    log_info "  ${key}=***"
    echo "${key}=${value}" >> "${GITHUB_ENV}"
  done <<< "${ENV_VARS}"
  echo "::endgroup::"
}

# --- Main ---

log_info "Arcane Docker Compose Deploy"
log_info "Instance: ${ARCANE_URL}"
log_info "Environment: ${ENV_ID}"
log_info "Repository: ${REPO_URL}"
log_info "Branch: ${BRANCH}"

# Validate required inputs
require_input "arcane-url" "${ARCANE_URL}"
require_input "arcane-api-key" "${API_KEY}"
require_input "environment-id" "${ENV_ID}"

if [[ -z "${COMPOSE_DIR}" && -z "${COMPOSE_FILES_INPUT}" ]]; then
  log_error "At least one of compose-dir or compose-files is required"
  exit 1
fi

# [H5] Validate git-token is set when auth-type is http
if [[ "${AUTH_TYPE}" == "http" && -z "${GIT_TOKEN}" ]]; then
  log_error "git-token is required when auth-type is http (the default). Set git-token or use auth-type: none."
  exit 1
fi

# [H4] Reject unsupported auth-type values
if [[ "${AUTH_TYPE}" != "none" && "${AUTH_TYPE}" != "http" ]]; then
  log_error "auth-type '${AUTH_TYPE}' is not supported. Valid values: none, http."
  exit 1
fi

# Validate auto-sync is a boolean (required for jq --argjson)
if [[ "${AUTO_SYNC}" != "true" && "${AUTO_SYNC}" != "false" ]]; then
  log_error "auto-sync must be 'true' or 'false', got '${AUTO_SYNC}'"
  exit 1
fi

# [H3] Validate sync-interval is a positive integer
if [[ ! "${SYNC_INTERVAL}" =~ ^[1-9][0-9]*$ ]]; then
  log_error "sync-interval must be a positive integer, got '${SYNC_INTERVAL}'"
  exit 1
fi

# Validate arcane-url uses HTTPS
if [[ "${ARCANE_URL}" != https://* ]]; then
  log_error "arcane-url must use HTTPS (got '${ARCANE_URL}')"
  exit 1
fi

# Export shared env vars
export_env_vars

# Discover compose files
echo "::group::Discovering compose files"
compose_file_list=$(discover_compose_files)
mapfile -t compose_files <<< "${compose_file_list}"
log_info "Found ${#compose_files[@]} compose file(s):"
for f in "${compose_files[@]}"; do
  log_info "  - ${f}"
done
echo "::endgroup::"

# Ensure git repository exists in Arcane
ensure_repository

# Get existing syncs
echo "::group::Syncing compose stacks"
existing_syncs=$(arcane_api GET "/environments/${ENV_ID}/gitops-syncs")

# Process each compose file
for compose_path in "${compose_files[@]}"; do
  [[ -z "${compose_path}" ]] && continue

  sync_name=$(sync_name_from_path "${compose_path}")
  log_info "Processing: ${compose_path} -> ${sync_name}"
  upsert_sync "${compose_path}" "${sync_name}" "${existing_syncs}"
done
echo "::endgroup::"

# Set outputs
echo "syncs-created=${SYNCS_CREATED}" >> "${GITHUB_OUTPUT}"
echo "syncs-updated=${SYNCS_UPDATED}" >> "${GITHUB_OUTPUT}"
echo "repository-id=${REPOSITORY_ID}" >> "${GITHUB_OUTPUT}"

log_info "Done! Created: ${SYNCS_CREATED}, Updated: ${SYNCS_UPDATED}"
