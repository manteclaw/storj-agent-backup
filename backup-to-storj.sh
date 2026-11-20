#!/usr/bin/env bash
# Back up local directories to a Storj S3 bucket (additive rclone copy).
#
# Usage: backup-to-storj.sh [--config FILE] [--dry-run]
#
# What is backed up is driven by storj-backup.conf (see
# storj-backup.conf.example): BACKUP_SOURCES entries of the form
#   "$HOME/notes:notes"         local path : remote prefix in the bucket
# plus the files listed in HOME_FILES, copied from $HOME (max-depth 1).
#
# Safety: rclone copy is additive — deleting a local file never deletes
# its backup. Credentials come from the environment only:
#   RCLONE_S3_ACCESS_KEY_ID / RCLONE_S3_SECRET_ACCESS_KEY
# They are never written to a file and never printed by this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: backup-to-storj.sh [--config FILE] [--dry-run]

Back up configured local directories to a Storj S3 bucket with rclone copy.

Options:
  --config FILE   Use this config file (default: ./storj-backup.conf, then
                  ~/.config/storj-agent-backup/storj-backup.conf)
  --dry-run       Print the rclone commands without running them and without
                  needing Storj credentials.
  --help          Show this help.

Environment:
  RCLONE_S3_ACCESS_KEY_ID, RCLONE_S3_SECRET_ACCESS_KEY   Storj S3 credentials
  BACKUP_BUCKET     Bucket to back up into (default: agent-backup)
  RCLONE            rclone binary (default: rclone on PATH)
  STORJ_BACKUP_CONF Config file path (overridden by --config)
EOF
}

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

parse_flags "$@"
set -- "${POSITIONAL_ARGS[@]}"
[ "$#" -eq 0 ] || { usage >&2; die "backup-to-storj.sh takes no positional arguments"; }

load_config
require_credentials
setup_logging "backup"
check_rclone

if [ "${#BACKUP_SOURCES[@]}" -eq 0 ] && [ "${#HOME_FILES[@]}" -eq 0 ]; then
  die "No backup sources configured. Copy storj-backup.conf.example to storj-backup.conf and set BACKUP_SOURCES."
fi

log "Starting backup to Storj bucket '$BACKUP_BUCKET' (log: $LOG)"

copy_source() { # $1 = local path, $2 = remote prefix
  local src="$1" dest="$2"
  local args=() pat
  [ -e "$src" ] || { log "WARNING: source missing, skipping: $src"; return 0; }
  for pat in "${BACKUP_EXCLUDES[@]}"; do args+=(--exclude "$pat"); done
  log "Copying $src -> :s3:$BACKUP_BUCKET/$dest"
  run_rclone copy "$src" ":s3:$BACKUP_BUCKET/$dest" \
    --checkers "$RCLONE_CHECKERS" --transfers "$RCLONE_TRANSFERS" \
    "${args[@]}"
}

for entry in "${BACKUP_SOURCES[@]}"; do
  copy_source "${entry%%:*}" "${entry#*:}"
done

if [ "${#HOME_FILES[@]}" -gt 0 ]; then
  include="{$(IFS=,; echo "${HOME_FILES[*]}")}"
  log "Copying home files -> :s3:$BACKUP_BUCKET/home-files"
  run_rclone copy "$HOME" ":s3:$BACKUP_BUCKET/home-files" \
    --max-depth 1 --include "$include" \
    --checkers "$RCLONE_CHECKERS" --transfers "$RCLONE_TRANSFERS"
fi

log "Bucket size after backup:"
run_rclone size ":s3:$BACKUP_BUCKET"

log "Backup complete."
