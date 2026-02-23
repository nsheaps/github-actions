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
SYNC_NAME_PREFIX="${INPUT_SYNC_NAME_PREFIX:-${GITHUB_REPOSITORY##*/}}"

SYNCS_CREATED=0
SYNCS_UPDATED=0
REPOSITORY_ID=""

# --- Logging ---
log_info() {
  echo "[Arcane Deploy] $1"
}

log_error() {
  echo "::error::[Arcane Deploy] $1"
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
  http_code=$(curl -s -w "%{http_code}" \
    -X "${method}" \
    -H "X-Api-Key: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -o "${tmp_body}" \
    "$@" \
    "${url}") || true

  if [[ "${http_code}" -ge 400 ]]; then
    log_error "API ${method} ${path} failed (HTTP ${http_code})"
    cat "${tmp_body}" >&2
    rm -f "${tmp_body}"
    return 1
  fi

  cat "${tmp_body}"
  rm -f "${tmp_body}"
}

# --- Compose File Discovery ---
discover_compose_files() {
  local files=()

  # From explicit list
  if [[ -n "${COMPOSE_FILES_INPUT}" ]]; then
    while IFS= read -r file; do
      file="${file#"${file%%[![:space:]]*}"}" # trim leading
      file="${file%"${file##*[![:space:]]}"}" # trim trailing
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

  printf '%s\n' "${files[@]}"
}

# --- Sync Naming ---
# Derive a sync name from a compose file path.
# "stacks/myapp/compose.yml" -> "${prefix}-myapp"
# "compose.yml" (root) -> "${prefix}"
sync_name_from_path() {
  local path="$1"
  local dir
  dir=$(dirname "${path}")

  local name
  if [[ "${dir}" == "." ]]; then
    name="${SYNC_NAME_PREFIX}"
  else
    name=$(basename "${dir}")
    if [[ "${name}" != "${SYNC_NAME_PREFIX}" ]]; then
      name="${SYNC_NAME_PREFIX}-${name}"
    fi
  fi

  echo "${name}"
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

  if [[ -n "${REPOSITORY_ID}" ]]; then
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
    create_payload=$(jq -n \
      --arg name "${REPO_NAME}" \
      --arg url "${REPO_URL}" \
      --arg authType "${AUTH_TYPE}" \
      --arg token "${GIT_TOKEN}" \
      '{name: $name, url: $url, authType: $authType, token: $token}')

    local result
    result=$(arcane_api POST "/customize/git-repositories" -d "${create_payload}")

    REPOSITORY_ID=$(echo "${result}" | jq -r '.id')
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

  local auto_sync_val="false"
  [[ "${AUTO_SYNC}" == "true" ]] && auto_sync_val="true"

  if [[ -n "${existing_id}" ]]; then
    log_info "  Updating sync ${existing_id} (${sync_name})"

    local update_payload
    update_payload=$(jq -n \
      --arg name "${sync_name}" \
      --arg branch "${BRANCH}" \
      --arg composePath "${compose_path}" \
      --argjson autoSync "${auto_sync_val}" \
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

    if [[ "${TRIGGER_SYNC}" == "true" ]]; then
      log_info "  Triggering sync..."
      arcane_api POST "/environments/${ENV_ID}/gitops-syncs/${existing_id}/sync" > /dev/null || true
    fi
  else
    log_info "  Creating sync: ${sync_name}"

    local create_payload
    create_payload=$(jq -n \
      --arg name "${sync_name}" \
      --arg repositoryId "${REPOSITORY_ID}" \
      --arg branch "${BRANCH}" \
      --arg composePath "${compose_path}" \
      --arg projectName "${sync_name}" \
      --argjson autoSync "${auto_sync_val}" \
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

    local new_id
    new_id=$(echo "${result}" | jq -r '.id')
    log_info "  Created sync: ${new_id}"

    SYNCS_CREATED=$((SYNCS_CREATED + 1))

    if [[ "${TRIGGER_SYNC}" == "true" ]]; then
      log_info "  Triggering sync..."
      arcane_api POST "/environments/${ENV_ID}/gitops-syncs/${new_id}/sync" > /dev/null || true
    fi
  fi
}

# --- Environment Variables ---
export_env_vars() {
  if [[ -z "${ENV_VARS}" ]]; then
    return
  fi

  echo "::group::Setting shared environment variables"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}" # trim leading
    line="${line%"${line##*[![:space:]]}"}" # trim trailing
    [[ -z "${line}" ]] && continue
    [[ "${line}" == \#* ]] && continue

    local key="${line%%=*}"
    local value="${line#*=}"
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
if [[ -z "${ARCANE_URL}" ]]; then
  log_error "arcane-url is required"
  exit 1
fi
if [[ -z "${API_KEY}" ]]; then
  log_error "arcane-api-key is required"
  exit 1
fi
if [[ -z "${ENV_ID}" ]]; then
  log_error "environment-id is required"
  exit 1
fi
if [[ -z "${COMPOSE_DIR}" && -z "${COMPOSE_FILES_INPUT}" ]]; then
  log_error "At least one of compose-dir or compose-files is required"
  exit 1
fi

# Mask the API key
echo "::add-mask::${API_KEY}"

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
