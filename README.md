# storj-agent-backup

A small, boring-in-a-good-way backup kit for agents (and humans) whose
workspace lives on one machine: back it up to Storj S3, free local disk
by offloading verified copies, and restore anything on demand.

Three scripts, one config file, no daemons, no database, no credentials
in files.

| Script | What it does |
| --- | --- |
| `backup-to-storj.sh` | Additive `rclone copy` of configured directories into a Storj S3 bucket. Run on a schedule (e.g. every 6 hours via cron). |
| `offload-to-storj.sh` | Keeps a target percentage of disk free by moving bulky data to Storj. Removes nothing locally until `rclone check` proves the Storj copy matches. |
| `restore-from-storj.sh` | Brings an offloaded path back, using the manifest to find where it lives. |

Shared helpers live in `lib/common.sh` (config loading, logging, the
dry-run rclone wrapper, protected-path guards, manifest writer).

## Requirements

- [rclone](https://rclone.org/install/) (any recent version; S3 backend)
- `python3` (manifest writer/reader — JSONL, stdlib only)
- A Storj account with an S3 keypair (Storj console → Access → S3 Credentials)

## Quick start

```sh
# 1. Copy the example config and edit it (bucket + what to back up).
cp storj-backup.conf.example storj-backup.conf
$EDITOR storj-backup.conf

# 2. Export credentials — env vars only, never in a file.
export RCLONE_S3_ACCESS_KEY_ID="..."
export RCLONE_S3_SECRET_ACCESS_KEY="..."

# 3. Dry-run first: prints every rclone command, needs no credentials.
./backup-to-storj.sh --dry-run
./offload-to-storj.sh --dry-run

# 4. Run it for real.
./backup-to-storj.sh
```

Every script also accepts `--config FILE` (default: `./storj-backup.conf`,
then `~/.config/storj-agent-backup/storj-backup.conf`, overridable with
`STORJ_BACKUP_CONF`) and `--help`.

## Scheduling

```cron
# Backup every 6 hours (credentials must be in the cron environment).
0 */6 * * * /path/to/storj-agent-backup/backup-to-storj.sh
# Keep >= 30% of disk free, checked every 3 hours.
0 */3 * * * /path/to/storj-agent-backup/offload-to-storj.sh
```

## How offload works

1. Measure free space on `DISK_PATH` (default `$HOME`). At or above
   `FREE_SPACE_THRESHOLD_PCT` (default 30%)? Do nothing, exit 0.
2. **Mirrored copies first** (`MIRRORED_COPIES` in the config,
   `local-path|s3-bucket/prefix`): local directories that already live
   on Storj. Each is verified with `rclone check --size-only`; only a
   zero-difference check removes the local copy. The bucket is never
   written to by this step — it is the source of truth.
3. **Candidates next** (one absolute path per line in the candidates
   file): each is copied to the offload bucket (default
   `<backup-bucket>-offload`), verified with `rclone check --size-only`,
   and only then removed locally.
4. Every removal is appended to the offload manifest (JSONL: local path,
   Storj location, size, date, verification result). If space is still
   below the threshold after all candidates, the script exits 2 and
   prints the largest remaining directories so a human can decide.

Restore with:

```sh
./restore-from-storj.sh ~/workspace/archived-datasets
```

## Safety rules

- **Credentials are env vars only.** No key ever goes in a file, a
  config, or a log, and the scripts never print them.
- **Backup is additive.** `rclone copy` never deletes from the bucket,
  so deleting a local file never wipes its backup.
- **Nothing is removed without verification.** Offload runs
  `rclone check --size-only` first; a mismatch means the local copy
  stays put and a human is told.
- **Every removal is recorded** in the manifest, so anything offloaded
  can be found and restored.
- **Protected paths are never offloaded:** `/`, `$HOME`, the kit
  directory, the config, the manifest, the candidates file, the log
  directory, and anything listed in `PROTECTED_PATHS`.
- **Dry-run removes nothing.** `--dry-run` prints every rclone command,
  skips credential checks, and never deletes or records anything.

## Config reference

See `storj-backup.conf.example` — every setting is documented there.
Scalar settings can be overridden by environment variables; the lists
(`BACKUP_SOURCES`, `BACKUP_EXCLUDES`, `HOME_FILES`, `MIRRORED_COPIES`,
`PROTECTED_PATHS`) come from the config file.

- `BACKUP_SOURCES` — `"local-path:remote-prefix"` pairs.
- `MIRRORED_COPIES` — `"local-path|s3-bucket/prefix"` pairs.
- `BACKUP_BUCKET` — default `agent-backup`; `OFFLOAD_BUCKET` defaults
  to `<backup-bucket>-offload`.
- `FREE_SPACE_THRESHOLD_PCT` — default `30`; `DISK_PATH` — default `$HOME`.

## Origin

Generalized from a live, working setup that backs up an agent's
workspace to Storj every 6 hours and keeps its SSD above 30% free.
The live version's machine-specific defaults (bucket names, source
paths, a hardcoded recovery-copy step) were replaced with the config
file: the recovery-copy step became the generic `MIRRORED_COPIES`
mechanism above, and all bucket/path defaults are neutral.

## License

MIT — see `LICENSE`.
