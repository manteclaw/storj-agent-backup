#!/usr/bin/env bash
# Re-download a file or directory that offload-to-storj.sh moved to Storj.
#
# Usage: restore-from-storj.sh [--config FILE] [--dry-run] <local-path>
#
# Looks up the most recent manifest entry for that local path in the
# offload manifest and copies it back from the recorded Storj location.
# Credentials come from the environment, same as the backup script.
# The script never prints the credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: restore-from-storj.sh [--config FILE] [--dry-run] <local-path>

Restore a file or directory previously offloaded to Storj, using the
offload manifest to find where it lives.

Options:
  --config FILE   Use this config file (default: ./storj-backup.conf, then
                  ~/.config/storj-agent-backup/storj-backup.conf)
  --dry-run       Print what would be restored without copying anything and
                  without needing Storj credentials.
  --help          Show this help.

Environment:
  RCLONE_S3_ACCESS_KEY_ID, RCLONE_S3_SECRET_ACCESS_KEY   Storj S3 credentials
  MANIFEST_FILE     Offload manifest (default: ~/.local/state/storj-agent-backup/offload-manifest.jsonl)
  RCLONE            rclone binary (default: rclone on PATH)
EOF
}

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

parse_flags "$@"
set -- "${POSITIONAL_ARGS[@]}"
[ "$#" -eq 1 ] || { usage >&2; die "restore-from-storj.sh needs exactly one <local-path> argument"; }

TARGET="${1%/}"

load_config
require_credentials
setup_logging "restore"
check_rclone

[ -f "$MANIFEST_FILE" ] || die "No manifest found at $MANIFEST_FILE — nothing was ever offloaded."
command -v python3 >/dev/null 2>&1 || die "python3 is required (manifest reader)"

LOCATION="$(python3 - "$MANIFEST_FILE" "$TARGET" <<'EOF'
import json, sys
manifest, target = sys.argv[1], sys.argv[2]
found = None
with open(manifest) as f:
    for line in f:
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if entry.get("local_path") == target:
            found = entry.get("storj_location")
print(found or "")
EOF
)"

[ -n "$LOCATION" ] || die "No manifest entry for $TARGET — it was never offloaded, or the path differs."

log "Restoring $TARGET from $LOCATION ..."
SRC=":s3:${LOCATION#s3://}"
run_rclone copy "$SRC" "$TARGET" \
  --checkers "$RCLONE_CHECKERS" --transfers "$RCLONE_TRANSFERS"
log "Restored to $TARGET. Verify with: du -sh $TARGET"
