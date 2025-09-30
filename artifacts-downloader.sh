#!/bin/bash

set -euo pipefail       # Exit on error, undefined variable, or error in pipeline

ARTIFACTS_DIR="./4.3-artifacts"
GITHUB_REPO_OWNER="Cumucore"
GITHUB_REPOS=(
    "MME" "CNC-API" "LicenceAF" "SGW-C" "NWDAF" "SA_GUI_Console" "fgcalarm" "hss" "nfnrfapi"
)

# Function to log messages with timestamp
log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"	# Log with timestamp in format [YYYY-MM-DD HH:MM:SS]
}

# Function to display usage information
usage() {
	echo "Usage: $0 <github_token>"
	echo "  <github_token>   GitHub Personal Access Token with repo access."
	echo "\nOptions:"
	echo "  -h, --help       Show this help message."
	exit 1
}

START_TIME=$(date +%s)

# Check for required commands
for cmd in curl jq; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		echo "Error: Required command '$cmd' not found. Please install it and try again."
		exit 2
	fi
done

if [ $# -ne 1 ] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
	usage
fi

GITHUB_TOKEN="$1"


# Ensure artifacts and state directories exist
mkdir -p "$ARTIFACTS_DIR"
STATE_DIR="$ARTIFACTS_DIR/.state"
mkdir -p "$STATE_DIR"


# Function to get the last downloaded run ID for a repo
get_last_run_id() {
	local repo="$1"
	local id_file="$STATE_DIR/${repo}-last_run_id.txt"
	if [ -f "$id_file" ]; then
		cat "$id_file"
	else
		echo ""
	fi
}

# Function to save the last downloaded run ID for a repo
save_last_run_id() {
	local repo="$1"
	local run_id="$2"
	echo "$run_id" >"$STATE_DIR/${repo}-last_run_id.txt"
}

# Function to download artifact for a repo if new
process_repo() {
	local repo="$1"
	local current_repo="$2"
	local total_repos="$3"
	echo -ne "[Progress: $current_repo/$total_repos] Processing $repo...\r"
	log "[Progress: $current_repo/$total_repos] Processing $repo"
	log "==== Processing repository: $repo ===="
	local last_run_id=$(get_last_run_id "$repo")
	local latest_run_id=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
		"https://api.github.com/repos/$GITHUB_REPO_OWNER/$repo/actions/runs?per_page=1" |
		jq -r '.workflow_runs[0].id')

	if [ -z "$latest_run_id" ] || [ "$latest_run_id" = "null" ]; then
		log "  No workflow runs found for $repo. Skipping."
		return
	fi

	if [ "$last_run_id" = "$latest_run_id" ]; then
		log "  No new workflow run for $repo. Skipping download."
		return
	fi

	local artifacts_url="https://api.github.com/repos/$GITHUB_REPO_OWNER/$repo/actions/runs/$latest_run_id/artifacts"
	local artifacts=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$artifacts_url" | jq -r '.artifacts[]? | "\(.name) \(.archive_download_url)"')

	if [ -z "$artifacts" ]; then
		log "  No artifacts found for $repo. Skipping."
		return
	fi

	while IFS= read -r line; do
		local artifact_name=$(echo "$line" | awk '{print $1}')
		local download_url=$(echo "$line" | awk '{print $2}')
		if [ -z "$artifact_name" ] || [ -z "$download_url" ]; then
			log "  Invalid artifact data for $repo. Skipping."
			continue
		fi
		log "  Downloading artifact: $artifact_name from $repo..."
		curl -sSL -H "Authorization: token $GITHUB_TOKEN" -o "$ARTIFACTS_DIR/$artifact_name.zip" "$download_url"
		if [ -f "$ARTIFACTS_DIR/$artifact_name.zip" ]; then
			mv "$ARTIFACTS_DIR/$artifact_name.zip" "$ARTIFACTS_DIR/${repo}-artifacts.zip"
			log "  Saved as $ARTIFACTS_DIR/${repo}-artifacts.zip"
		else
			log "  Failed to download $artifact_name for $repo."
		fi
	done <<<"$artifacts"
	save_last_run_id "$repo" "$latest_run_id"
}

# Function to batch unzip all zip files
batch_unzip_artifacts() {
	log "Unzipping all artifact zip files..."
	shopt -s nullglob
	for zipfile in "$ARTIFACTS_DIR"/*.zip; do
		base=$(basename "$zipfile" .zip)
		folder_name="${base}"
		target_dir="$ARTIFACTS_DIR/$folder_name"
		mkdir -p "$target_dir"
		log "  Unzipping $zipfile to $target_dir..."
		unzip -oq "$zipfile" -d "$target_dir"
		if [ $? -eq 0 ]; then
			log "  Unzipped $zipfile."
		else
			log "  Failed to unzip $zipfile."
		fi
	done
	shopt -u nullglob
	log "Unzipping complete."
}

# Function to batch delete all zip files
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

# Main loop
total_repos=${#GITHUB_REPOS[@]}
current_repo=1

for REPO in "${GITHUB_REPOS[@]}"; do
	process_repo "$REPO" "$current_repo" "$total_repos"
	current_repo=$((current_repo + 1))
done
echo -ne "\n" # Move to new line after progress bar

# Batch unzip and cleanup
batch_unzip_artifacts
batch_delete_zips

log "\nAll artifacts processed in $ARTIFACTS_DIR."

# Log total duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "Total time taken: ${DURATION} seconds."
