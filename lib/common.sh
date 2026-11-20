#!/usr/bin/env bash
# storj-agent-backup — shared helpers.
#
# Sourced by backup-to-storj.sh, offload-to-storj.sh and restore-from-storj.sh.
# Not meant to be run directly.
#
# Contract for callers (do these before sourcing):
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   define usage() — printed by --help
# Then: source "$SCRIPT_DIR/lib/common.sh"
#
# Provides:
#   parse_flags "$@"      --help/-h, --dry-run, --config FILE
#                         (positionals land in POSITIONAL_ARGS; the caller
#                         then does: set -- "${POSITIONAL_ARGS[@]}")
#   load_config           find + source the config file, apply defaults.
#                         Env vars override config; config overrides defaults.
#   require_credentials   S3 keys from the environment only (skipped in
#                         dry-run, so --dry-run needs no credentials).
#   setup_logging <tag>   per-run log file (stdout only in dry-run).
#   log / die             timestamped logging / fatal error.
#   check_rclone          rclone binary present (skipped in dry-run).
#   run_rclone ...        rclone wrapper: echoes the command in dry-run,
#                         runs it for real otherwise.
#   is_protected <path>   true if a path must never be offloaded.
#   remove_verified <path> <why>   rm -rf guarded by DRY_RUN + is_protected.
#   manifest_add <local> <storj> <bytes> <note>   JSONL removal record.
#
# Safety rules baked in here (see README.md):
#   - Credentials are env vars only, never in files, never printed.
#   - rclone copy is additive: local deletes never wipe the backup.
#   - Nothing is removed locally without a passing `rclone check` first.
#   - Every removal is recorded in the manifest (JSONL).

# Flags parsed by parse_flags.
DRY_RUN=0
CONFIG_FILE=""
POSITIONAL_ARGS=()

parse_flags() {
  POSITIONAL_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --config)
        [ -n "${2:-}" ] || { echo "error: --config needs a file path" >&2; exit 2; }
        CONFIG_FILE="$2"
        shift 2
        ;;
      --config=*)
        CONFIG_FILE="${1#--config=}"
        shift
        ;;
      --)
        shift
        POSITIONAL_ARGS+=("$@")
        break
        ;;
      -*)
        echo "error: unknown option: $1 (see --help)" >&2
        exit 2
        ;;
      *)
        POSITIONAL_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

# Config resolution order: --config FILE, $STORJ_BACKUP_CONF,
# ./storj-backup.conf, ~/.config/storj-agent-backup/storj-backup.conf.
# No config file is an error only if the script then has nothing to do
# (e.g. backup with no BACKUP_SOURCES); the scripts report that clearly.
load_config() {
  local found=""
  if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "config file not found: $CONFIG_FILE"
    found="$CONFIG_FILE"
  elif [ -n "${STORJ_BACKUP_CONF:-}" ]; then
    [ -f "$STORJ_BACKUP_CONF" ] || die "config file not found: $STORJ_BACKUP_CONF (from STORJ_BACKUP_CONF)"
    found="$STORJ_BACKUP_CONF"
  elif [ -f "./storj-backup.conf" ]; then
    found="./storj-backup.conf"
  elif [ -f "$HOME/.config/storj-agent-backup/storj-backup.conf" ]; then
    found="$HOME/.config/storj-agent-backup/storj-backup.conf"
  fi
  if [ -n "$found" ]; then
    # shellcheck source=/dev/null
    source "$found"
    CONFIG_FILE="$found"
  fi

  # Defaults. Env wins over config because the example config itself
  # assigns with ${VAR:-default}; these cover the no-config case.
  : "${RCLONE:=rclone}"
  : "${BACKUP_BUCKET:=agent-backup}"
  : "${OFFLOAD_BUCKET:=${BACKUP_BUCKET}-offload}"
  : "${STORJ_ENDPOINT:=https://gateway.storjshare.io}"
  : "${FREE_SPACE_THRESHOLD_PCT:=30}"
  : "${DISK_PATH:=$HOME}"
  : "${LOG_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/storj-agent-backup/logs}"
  : "${MANIFEST_FILE:=${XDG_STATE_HOME:-$HOME/.local/state}/storj-agent-backup/offload-manifest.jsonl}"
  : "${CANDIDATES_FILE:=$HOME/.config/storj-agent-backup/offload-candidates.txt}"
  : "${RCLONE_CHECKERS:=8}"
  : "${RCLONE_TRANSFERS:=4}"

  # Arrays: config is the only source; default to empty when unset.
  [ -n "${BACKUP_SOURCES+x}" ]    || BACKUP_SOURCES=()
  [ -n "${BACKUP_EXCLUDES+x}" ]   || BACKUP_EXCLUDES=('**/*.partial')
  [ -n "${HOME_FILES+x}" ]        || HOME_FILES=()
  [ -n "${MIRRORED_COPIES+x}" ]   || MIRRORED_COPIES=()
  [ -n "${PROTECTED_PATHS+x}" ]   || PROTECTED_PATHS=()
}

require_credentials() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: credentials not required; no network calls will be made."
    return 0
  fi
  : "${RCLONE_S3_ACCESS_KEY_ID:?RCLONE_S3_ACCESS_KEY_ID is not set in the environment (Storj S3 access key)}"
  : "${RCLONE_S3_SECRET_ACCESS_KEY:?RCLONE_S3_SECRET_ACCESS_KEY is not set in the environment (Storj S3 secret key)}"
  export RCLONE_S3_PROVIDER=Storj
  export RCLONE_S3_ENDPOINT="$STORJ_ENDPOINT"
}

LOG=""
setup_logging() { # $1 = tag, e.g. backup
  local tag="$1"
  if [ "$DRY_RUN" -eq 1 ]; then
    LOG="/dev/null"
    return 0
  fi
  mkdir -p "$LOG_DIR"
  LOG="$LOG_DIR/$tag-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG"
}

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
die() { echo "error: $*" >&2; exit 1; }

check_rclone() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  command -v "$RCLONE" >/dev/null 2>&1 || die "rclone not found (RCLONE=$RCLONE). Install rclone: https://rclone.org/install/"
}

# rclone wrapper. In dry-run it only echoes the command and succeeds;
# callers must still guard destructive steps (see remove_verified).
run_rclone() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN: rclone $*"
    return 0
  fi
  "$RCLONE" "$@"
}

# is_protected <path> — true (0) if the path must never be offloaded:
# /, $HOME, the kit directory, the config, the manifest, the candidates
# file, the log directory, anything in PROTECTED_PATHS, or any ancestor
# of one of those (removing it would remove the guarded path too).
is_protected() {
  local p="$1" guard
  case "$p" in
    ""|"/"|"$HOME") return 0 ;;
  esac
  for guard in "$SCRIPT_DIR" "$CONFIG_FILE" "$MANIFEST_FILE" "$CANDIDATES_FILE" "$LOG_DIR" "${PROTECTED_PATHS[@]}"; do
    [ -n "$guard" ] || continue
    [ "$p" = "$guard" ] && return 0
    case "$guard" in
      "$p"/*) return 0 ;;
    esac
  done
  return 1
}

# remove_verified <path> <why> — remove a local path only after its
# caller verified the Storj copy. Refuses protected/missing paths and
# removes nothing at all in dry-run. Returns 0 on success (or dry-run
# skip), 1 on refusal.
remove_verified() {
  local p="$1" why="$2"
  if is_protected "$p"; then
    log "REFUSING to remove protected path: $p"
    return 1
  fi
  [ -e "$p" ] || { log "Nothing to remove (already gone): $p"; return 1; }
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would remove $p ($why)"
    return 0
  fi
  log "Removing $p ($why)"
  rm -rf -- "$p"
}

# manifest_add <local-path> <storj-location> <size-bytes> <note>
# Appends one JSON line to the manifest. Every local removal is recorded
# here so restore-from-storj.sh can bring it back.
manifest_add() {
  local lp="$1" loc="$2" size="$3" note="$4"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would record manifest entry: $lp -> $loc"
    return 0
  fi
  mkdir -p "$(dirname "$MANIFEST_FILE")"
  command -v python3 >/dev/null 2>&1 || die "python3 is required (manifest writer)"
  python3 - "$lp" "$loc" "$size" "$note" <<'EOF' >> "$MANIFEST_FILE"
import json, sys, datetime
print(json.dumps({
    "date": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "local_path": sys.argv[1],
    "storj_location": sys.argv[2],
    "size_bytes": int(sys.argv[3]),
    "note": sys.argv[4],
    "verified": "rclone check --size-only passed before removal",
}))
EOF
}
