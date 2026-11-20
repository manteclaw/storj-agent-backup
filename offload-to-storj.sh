#!/usr/bin/env bash
# Disk space watch: keep at least FREE_SPACE_THRESHOLD_PCT of DISK_PATH
# free, offloading bulky data to Storj.
#
# Usage: offload-to-storj.sh [--config FILE] [--dry-run]
#
# How it works:
#   1. Measure free space. If at or above the threshold, do nothing, exit 0.
#   2. If below the threshold, work in order until free space is back:
#        a. MIRRORED_COPIES from the config — local copies that ALREADY
#           live on Storj ("local-path|s3-bucket/prefix"). Each is
#           verified with `rclone check --size-only` against Storj first.
#           Only if the check reports zero differences is the local copy
#           removed. The bucket is never written to by this step; it is
#           the source of truth.
#        b. Paths listed in the candidates file (one absolute path per
#           line). Each is copied to the offload bucket, verified with
#           `rclone check --size-only`, and only then removed locally.
#   3. Every removal is recorded in the offload manifest (JSONL), so
#      restore-from-storj.sh can bring it back.
#
# Safety rules:
#   - Nothing is deleted without a passing verification first.
#   - Protected paths are never touched: /, $HOME, the kit directory,
#     the config, the manifest, the candidates file, the log directory,
#     and anything in PROTECTED_PATHS.
#   - If candidates run out and free space is still below the threshold,
#     exit 2 and print the largest remaining directories so a human can
#     decide.
#
# Credentials are NOT stored in this script or in any config file. The
# caller must set RCLONE_S3_ACCESS_KEY_ID and RCLONE_S3_SECRET_ACCESS_KEY
# in the environment. The script never prints the credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: offload-to-storj.sh [--config FILE] [--dry-run]

Free disk space by offloading verified copies to Storj, keeping at least
FREE_SPACE_THRESHOLD_PCT of DISK_PATH free (default 30%).

Options:
  --config FILE   Use this config file (default: ./storj-backup.conf, then
                  ~/.config/storj-agent-backup/storj-backup.conf)
  --dry-run       Print what would be offloaded without copying, verifying
                  or removing anything, and without needing Storj credentials.
  --help          Show this help.

Environment:
  RCLONE_S3_ACCESS_KEY_ID, RCLONE_S3_SECRET_ACCESS_KEY   Storj S3 credentials
  OFFLOAD_BUCKET    Bucket offloaded files go into (default: <bucket>-offload)
  RCLONE            rclone binary (default: rclone on PATH)
  STORJ_BACKUP_CONF Config file path (overridden by --config)
EOF
}

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

parse_flags "$@"
set -- "${POSITIONAL_ARGS[@]}"
[ "$#" -eq 0 ] || { usage >&2; die "offload-to-storj.sh takes no positional arguments"; }

load_config
require_credentials
setup_logging "offload"
check_rclone

TOTAL=0
AVAIL=0
refresh_disk() {
  read -r TOTAL AVAIL <<< "$(df -B1 --output=size,avail "$DISK_PATH" | tail -1)"
}
free_pct() {
  if [ "${TOTAL:-0}" -gt 0 ]; then echo $(( AVAIL * 100 / TOTAL )); else echo 0; fi
}

refresh_disk
log "Disk space watch starting. Disk: $DISK_PATH, total: $((TOTAL/1024/1024/1024)) GiB, free: $((AVAIL/1024/1024/1024)) GiB ($(free_pct)%). Threshold: ${FREE_SPACE_THRESHOLD_PCT}% free."

if [ "$(free_pct)" -ge "$FREE_SPACE_THRESHOLD_PCT" ]; then
  log "Free space $(free_pct)% is at or above the ${FREE_SPACE_THRESHOLD_PCT}% threshold. Nothing to offload."
  echo "{\"free_pct_before\": $(free_pct), \"free_pct_after\": $(free_pct), \"offloaded\": [], \"still_short\": false}"
  exit 0
fi

BEFORE_PCT="$(free_pct)"
OFFLOADED_JSON=""

# --- Step A: mirrored copies (already on Storj — verify, then remove). ---
for entry in "${MIRRORED_COPIES[@]}"; do
  [ "$(free_pct)" -lt "$FREE_SPACE_THRESHOLD_PCT" ] || break
  LOCAL_PATH="${entry%%|*}"
  S3_PATH="${entry#*|}"
  [ -n "$LOCAL_PATH" ] && [ -n "$S3_PATH" ] || { log "WARNING: malformed MIRRORED_COPIES entry, skipping: $entry"; continue; }
  [ -e "$LOCAL_PATH" ] || { log "Mirrored copy listed but missing, skipping: $LOCAL_PATH"; continue; }
  log "Checking local copy against Storj '$S3_PATH' (size-only)..."
  if run_rclone check --size-only "$LOCAL_PATH" ":s3:$S3_PATH" --checkers "$RCLONE_CHECKERS"; then
    SIZE_BYTES="$(du -sb "$LOCAL_PATH" | cut -f1)"
    if remove_verified "$LOCAL_PATH" "mirrored copy already on Storj; local copy removed after verification, bucket is the source of truth"; then
      manifest_add "$LOCAL_PATH" "s3://$S3_PATH" "$SIZE_BYTES" "mirrored copy already on Storj; local copy removed after verification, bucket is the source of truth"
      OFFLOADED_JSON="$OFFLOADED_JSON{\"path\": \"$LOCAL_PATH\", \"size_gib\": $((SIZE_BYTES/1024/1024/1024))},"
    fi
  else
    log "WARNING: local copy differs from Storj '$S3_PATH'. NOT removing it. A human must reconcile it first."
  fi
  refresh_disk
  log "Free space now $(free_pct)%."
done

# --- Step B: listed candidates -> offload bucket, verify, then remove. ---
run_rclone mkdir ":s3:$OFFLOAD_BUCKET" 2>/dev/null || true
if [ -f "$CANDIDATES_FILE" ]; then
  while IFS= read -r CANDIDATE; do
    [ "$(free_pct)" -ge "$FREE_SPACE_THRESHOLD_PCT" ] && break
    case "$CANDIDATE" in ""|\#*) continue ;; esac
    [ -e "$CANDIDATE" ] || { log "Candidate listed but missing, skipping: $CANDIDATE"; continue; }
    if is_protected "$CANDIDATE"; then
      log "Candidate is a protected path, skipping: $CANDIDATE"
      continue
    fi
    case "$CANDIDATE" in
      "$HOME"/*) REL="${CANDIDATE#$HOME/}" ;;
      *) REL="$(basename "$CANDIDATE")" ;;
    esac
    DEST=":s3:$OFFLOAD_BUCKET/$REL"
    log "Offloading $CANDIDATE -> $DEST ..."
    if run_rclone copy "$CANDIDATE" "$DEST" --checkers "$RCLONE_CHECKERS" --transfers "$RCLONE_TRANSFERS" \
       && run_rclone check --size-only "$CANDIDATE" "$DEST" --checkers "$RCLONE_CHECKERS"; then
      SIZE_BYTES="$(du -sb "$CANDIDATE" | cut -f1)"
      if remove_verified "$CANDIDATE" "copied to $OFFLOAD_BUCKET, verified, removed locally"; then
        manifest_add "$CANDIDATE" "s3://$OFFLOAD_BUCKET/$REL" "$SIZE_BYTES" "copied to $OFFLOAD_BUCKET, verified, removed locally"
        OFFLOADED_JSON="$OFFLOADED_JSON{\"path\": \"$CANDIDATE\", \"size_gib\": $((SIZE_BYTES/1024/1024/1024))},"
      fi
    else
      log "ERROR: copy or verification failed for $CANDIDATE. Leaving it in place."
    fi
    refresh_disk
    log "Free space now $(free_pct)%."
  done < "$CANDIDATES_FILE"
else
  log "No candidates file at $CANDIDATES_FILE — nothing listed to offload."
fi

refresh_disk
AFTER_PCT="$(free_pct)"
log "Done. Free space: ${BEFORE_PCT}% -> ${AFTER_PCT}%. Log: $LOG"

if [ "$AFTER_PCT" -lt "$FREE_SPACE_THRESHOLD_PCT" ]; then
  log "STILL BELOW THRESHOLD. Largest remaining directories under home:"
  du -sh "$HOME"/* 2>/dev/null | sort -rh | head -10 | tee -a "$LOG"
  echo "{\"free_pct_before\": $BEFORE_PCT, \"free_pct_after\": $AFTER_PCT, \"offloaded\": [${OFFLOADED_JSON%,}], \"still_short\": true}"
  exit 2
fi
echo "{\"free_pct_before\": $BEFORE_PCT, \"free_pct_after\": $AFTER_PCT, \"offloaded\": [${OFFLOADED_JSON%,}], \"still_short\": false}"
exit 0
