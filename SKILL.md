---
name: storj-agent-backup
description: Back up an agent's workspace to Storj S3 with rclone, free local disk by offloading verified copies, and restore them on demand. Use when an agent needs durable off-machine backups, or when local disk is filling up and bulky data should live on Storj instead — without ever losing a file to a bad delete.
license: MIT
compatibility: Any agent runtime with a POSIX shell, rclone, and python3
metadata:
  author: manteclaw
  version: "1.0.0"
  tags: storj s3 backup offload rclone agent-ops storage
---

## Storj Agent Backup

A small backup kit for agents (or humans) who live in a workspace and
need it to survive a wiped machine: three scripts plus one config file.

- `backup-to-storj.sh` — additive `rclone copy` of configured directories
  into a Storj S3 bucket. Run on a schedule (e.g. every 6 hours).
- `offload-to-storj.sh` — keeps a target percentage of disk free by
  moving bulky data to Storj. Nothing is removed locally until a
  `rclone check` proves the Storj copy matches.
- `restore-from-storj.sh <local-path>` — brings an offloaded path back,
  using the manifest to find where it lives.

### When to use

- The workspace (notes, memory, skills, research) must exist somewhere
  other than the one machine it runs on.
- Local disk is filling up and the bulky stuff should live on Storj,
  retrievable on demand.
- A local directory is a copy of data that already lives on Storj and
  the disk space can be reclaimed safely.

### Setup (once)

1. Install rclone: https://rclone.org/install/ (python3 is also needed,
   for the manifest writer/reader).
2. Copy `storj-backup.conf.example` to `storj-backup.conf` (same
   directory as the scripts, or `~/.config/storj-agent-backup/`) and set
   `BACKUP_BUCKET` and `BACKUP_SOURCES`.
3. Export Storj S3 credentials in the environment — never in a file:
   `RCLONE_S3_ACCESS_KEY_ID` and `RCLONE_S3_SECRET_ACCESS_KEY`.
   (Create an S3 keypair in the Storj console: Access > S3 Credentials.)

### How to use

```sh
./backup-to-storj.sh                    # run the backup now
./backup-to-storj.sh --dry-run          # show the rclone commands, no creds needed
./offload-to-storj.sh                   # free disk up to the threshold
./restore-from-storj.sh ~/path/to/dir   # bring an offloaded path back
```

Every script also accepts `--config FILE` and `--help`.

### Safety rules (do not weaken these)

- **Credentials are env vars only.** No key ever goes in a file, a
  config, or a log, and the scripts never print them.
- **Backup is additive.** `rclone copy` never deletes from the bucket,
  so deleting a local file never wipes its backup.
- **Nothing is removed without verification.** Offload runs
  `rclone check --size-only` first; a mismatch means the local copy
  stays put and a human is told.
- **Every removal is recorded.** The offload manifest (JSONL) logs the
  local path, Storj location, size, date, and verification result.
- **Protected paths are never offloaded:** `/`, `$HOME`, the kit
  directory, the config, the manifest, the candidates file, the log
  directory, and anything in `PROTECTED_PATHS`.
- **Mirrored copies are read-only on the Storj side.** If a local
  directory already lives in a Storj bucket, offload verifies it and
  removes the local copy — it never writes to that bucket.
- **Dry-run removes nothing.** `--dry-run` prints every rclone command,
  skips credential checks, and never deletes or records anything.

### Config reference

See `storj-backup.conf.example` — every setting is documented there.
Scalars can be overridden by environment variables; the lists
(`BACKUP_SOURCES`, `MIRRORED_COPIES`, `PROTECTED_PATHS`, …) come from
the config file. `BACKUP_SOURCES` entries are `local-path:remote-prefix`;
`MIRRORED_COPIES` entries are `local-path|s3-bucket/prefix`.
