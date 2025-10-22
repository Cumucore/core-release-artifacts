#!/bin/bash

set -euo pipefail  # Exit on error, undefined variable, or failed pipeline

# === CONFIGURATION ===
ARTIFACTS_DIR="./4.3-artifacts"
GITHUB_REPO_OWNER="Cumucore"

# Define repos and their respective branches safely
declare -A REPO_BRANCHES
REPO_BRANCHES["MME"]="v4.3"
REPO_BRANCHES["CNC-API"]="4.3"
REPO_BRANCHES["LicenceAF"]="4.3"
REPO_BRANCHES["SGW-C"]="v4.3"
REPO_BRANCHES["NWDAF"]="4.3"
REPO_BRANCHES["SA_GUI_Console"]="4.3"
REPO_BRANCHES["fgcalarm"]="1.2.0"
REPO_BRANCHES["hss"]="4.3"
REPO_BRANCHES["nfnrfapi"]="5.6"

# === COLOR CODES ===
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
BLUE="\033[1;34m"
RESET="\033[0m"

# === LOGGING FUNCTION ===
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${RESET} $*"
}

# === HELP FUNCTION ===
usage() {
    echo -e "Usage: $0 <github_token>"
    echo -e "  <github_token>   GitHub Personal Access Token with repo access.\n"
    echo -e "Options:"
    echo -e "  -h, --help       Show this help message."
    exit 1
}

# === START TIMER ===
START_TIME=$(date +%s)

# === PREREQUISITES ===
for cmd in curl jq unzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}Error:${RESET} Required command '$cmd' not found. Please install it."
        exit 2
    fi
done

if [ $# -ne 1 ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

GITHUB_TOKEN="$1"

# === PREPARE DIRECTORIES ===
mkdir -p "$ARTIFACTS_DIR"
STATE_DIR="$ARTIFACTS_DIR/.state"
mkdir -p "$STATE_DIR"

# === STATE FUNCTIONS ===
get_last_run_id() {
    local repo="$1"
    local id_file="$STATE_DIR/${repo}-last_run_id.txt"
    [[ -f "$id_file" ]] && cat "$id_file" || echo ""
}

save_last_run_id() {
    local repo="$1" run_id="$2"
    echo "$run_id" >"$STATE_DIR/${repo}-last_run_id.txt"
}

# === PROGRESS BAR ===
progress_bar() {
    local progress=$1 total=$2 width=40
    local filled=$(( progress * width / total ))
    local empty=$(( width - filled ))
    printf "\r[${GREEN}%0.s#${RESET}" $(seq 1 $filled)
    printf "%0.s-" $(seq 1 $empty)
    printf "] %s/%s" "$progress" "$total"
}

# === PROCESS EACH REPO ===
process_repo() {
    local repo="$1" branch="$2" current_repo="$3" total_repos="$4"
    progress_bar "$current_repo" "$total_repos"

    log "${YELLOW}==== Processing repository: $repo (branch: $branch) ====${RESET}"
    local last_run_id
    last_run_id=$(get_last_run_id "$repo")

    local latest_run_id
    latest_run_id=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/$GITHUB_REPO_OWNER/$repo/actions/runs?branch=$branch&per_page=1" |
        jq -r '.workflow_runs[0].id')

    if [[ -z "$latest_run_id" || "$latest_run_id" == "null" ]]; then
        log "${RED}  No workflow runs found for $repo (branch: $branch). Skipping.${RESET}"
        return
    fi

    if [[ "$last_run_id" == "$latest_run_id" ]]; then
        log "  No new workflow run for $repo. Skipping download."
        return
    fi

    local artifacts_url="https://api.github.com/repos/$GITHUB_REPO_OWNER/$repo/actions/runs/$latest_run_id/artifacts"
    local artifacts
    artifacts=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$artifacts_url" | jq -r '.artifacts[]? | "\(.name) \(.archive_download_url)"')

    if [[ -z "$artifacts" ]]; then
        log "  No artifacts found for $repo. Skipping."
        return
    fi

    while IFS= read -r line; do
        local artifact_name download_url
        artifact_name=$(echo "$line" | awk '{print $1}')
        download_url=$(echo "$line" | awk '{print $2}')
        if [[ -z "$artifact_name" || -z "$download_url" ]]; then
            log "  Invalid artifact data for $repo. Skipping."
            continue
        fi
        log "  Downloading artifact: ${GREEN}$artifact_name${RESET} from $repo..."
        curl -sSL -H "Authorization: token $GITHUB_TOKEN" -o "$ARTIFACTS_DIR/${repo}-${artifact_name}.zip" "$download_url"
        if [[ -f "$ARTIFACTS_DIR/${repo}-${artifact_name}.zip" ]]; then
            log "  Saved as ${ARTIFACTS_DIR}/${repo}-${artifact_name}.zip"
        else
            log "  ${RED}Failed to download $artifact_name for $repo.${RESET}"
        fi
    done <<<"$artifacts"

    save_last_run_id "$repo" "$latest_run_id"
}

# === UNZIP ALL ARTIFACTS ===
batch_unzip_artifacts() {
    log "Unzipping all artifact zip files..."
    shopt -s nullglob
    for zipfile in "$ARTIFACTS_DIR"/*.zip; do
        base=$(basename "$zipfile" .zip)
        target_dir="$ARTIFACTS_DIR/$base"
        mkdir -p "$target_dir"
        log "  Unzipping ${GREEN}$zipfile${RESET} to $target_dir..."
        unzip -oq "$zipfile" -d "$target_dir" && log "  ✅ Unzipped $zipfile." || log "  ❌ Failed to unzip $zipfile."
    done
    shopt -u nullglob
    log "Unzipping complete."
}

# === CLEAN UP ZIP FILES ===
batch_delete_zips() {
    log "Deleting all artifact zip files..."
    shopt -s nullglob
    for zipfile in "$ARTIFACTS_DIR"/*.zip; do
        rm -f "$zipfile"
        log "  Deleted $zipfile."
    done
    shopt -u nullglob
    log "Zip file cleanup complete."
}

# === MAIN LOOP ===
total_repos=${#REPO_BRANCHES[@]}
current_repo=1

# Process in sorted order for consistent output
for repo in $(printf '%s\n' "${!REPO_BRANCHES[@]}" | sort); do
    branch="${REPO_BRANCHES[$repo]:-main}"  # Default to main if missing
    process_repo "$repo" "$branch" "$current_repo" "$total_repos"
    ((current_repo++))
done
echo ""  # newline after progress bar

batch_unzip_artifacts
batch_delete_zips

log "\n${GREEN}All artifacts processed successfully in $ARTIFACTS_DIR.${RESET}"

# === LOG DURATION ===
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "${YELLOW}Total time taken: ${DURATION} seconds.${RESET}"