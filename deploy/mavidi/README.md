# MaViDi Mealie deployment

This packet deploys the official Mealie image with SQLite in a Docker volume. The port binds to host loopback. Use a private access layer with TLS and independent user authentication for family devices.

## Bootstrap

On the Windows host, use Docker Desktop with WSL integration enabled for
Ubuntu-26.04. In that distribution, Docker Compose, GnuPG, GNU tar, flock,
find, and bash must be available to the same Linux user that will run the task.
Keep this checkout under `D:\Workspace`. Commands below are for that WSL user.
Backups and the key belong in the Linux user's private home, not this checkout.

1. Prepare a high-entropy, single-line GPG passphrase and private directories:

   ```bash
   umask 077
   mkdir -p "$HOME/.local/state/mavidi-mealie" "$HOME/.config/mavidi-mealie"
   chmod 700 "$HOME/.local/state/mavidi-mealie" "$HOME/.config/mavidi-mealie"
   ( set -o noclobber; gpg --gen-random --armor 2 32 > "$HOME/.config/mavidi-mealie/backup.key" )
   chmod 600 "$HOME/.config/mavidi-mealie/backup.key"
   export MAVIDI_BACKUP_KEY="$HOME/.config/mavidi-mealie/backup.key"
   cd /mnt/d/Workspace/projects/nekurama/mealie/deploy/mavidi
   ```

   Do not replace an existing key: keep old keys for as long as their archives
   are retained. Preserve this key independently off-host before relying on backups. Losing
   it makes the archives unrecoverable. Do not commit it, put it in a Compose
   file, or copy it alongside the encrypted archives.
2. Review `compose.yaml`. The defaults use `localhost:9925`, `Asia/Kolkata`,
   SQLite, disabled public signup, and the MaViDi group and household. Set
   `MEALIE_PORT` and `MEALIE_BASE_URL` together if changing the loopback port;
   the URL must match the browser address. Keep the port binding loopback-only.
3. After explicitly authorizing deployment, run `docker compose -p mavidi-mealie
   up -d` from this directory. Open `http://localhost:9925` on the host. On a
   new installation, consult the documentation for the pinned release for its
   initial administrator credentials. Change the password and email immediately,
   before entering any private data. Do not assume the `DEFAULT_EMAIL` setting
   replaces the initial login; verify it in the deployed release.
4. Run `bash backup.sh` and then `bash restore-drill.sh /absolute/path/to/the/printed/archive.tar.gpg`.
   Check both commands' exit status. Only a successful drill establishes that
   this particular archive was restored and passed the checks.

## Backup and recovery

`backup.sh` locks concurrent backups, requires a running Mealie container, stops
it for a consistent SQLite and file snapshot, streams the data volume through
GPG AES256 encryption, and restarts Mealie even on ordinary errors or signals.
It verifies decryption, tar readability, and the presence of `mealie.db` before
publishing the archive. Only after success does it delete matching local
archives older than 30 days. The local default is
`~/.local/state/mavidi-mealie`; `MAVIDI_BACKUP_DIR` changes it. The key defaults
to `backup.key` in that directory for compatibility; set `MAVIDI_BACKUP_KEY`
as above to keep it separate. The script makes the backup directory private.
Key files must be regular, nonempty, and inaccessible to group and others.

Plaintext archive data is streamed, not written to a host file. Docker's data
volume and temporary drill volume contain plaintext; the host and Docker
administrators can access them. A compromised running host can also read the
key. Protect host access and storage; encryption does not protect against a
compromised host. Copy only completed `.tar.gpg` files to independently secured
off-host storage, using a separately approved method and retention policy.
Keep a separate offline or otherwise independently protected key copy, and
periodically verify access to both. This packet does not automate off-host
copying, key rotation, or alerts.

The drill accepts only archives from trusted backups. It streams decryption into
a newly created Docker volume, checks the existing SQLite database with
`PRAGMA quick_check`, then starts Mealie on Docker's `none` network and checks
its HTTP endpoint from inside the container. It publishes no ports and never
mounts the live volume. It removes its container and volume afterward, including
on ordinary failures. No application content or user login is verified. The
image configured in Compose must already be present locally; use an image
compatible with the archive's database version, especially across upgrades.
Do not use a newer schema with an older image. A failed drill is not a backup
success: investigate and retain the archive.

For actual disaster recovery, first preserve the existing live volume and
encrypted archive, then restore and validate in isolation. Plan an explicitly
approved promotion of a verified restored volume; this drill does not replace or
modify the live deployment. Avoid manual plaintext extraction to the host.
Monitor disk capacity, task exit codes, backup age, and drill results. If a
backup reports a restart or cleanup failure, inspect Docker and recover the
service or remove the specifically reported resource manually. Power loss,
forced termination, or Docker daemon failure can prevent cleanup or restart;
inspect for leftover drill/backup containers and volumes before retrying. Do not
prune all Docker volumes.

## Windows Task Scheduler

Create a scheduled task under the intended Windows user. Ensure Docker Desktop
and Ubuntu-26.04 integration are available at the scheduled time, and configure
the task to wake the machine if appropriate. Set **Program/script** to
`C:\Windows\System32\wsl.exe`, and **Add arguments** to the following, replacing
`LINUX_USER` with the WSL user who owns the key:

```text
--distribution Ubuntu-26.04 --user LINUX_USER --exec /usr/bin/env MAVIDI_BACKUP_KEY=/home/LINUX_USER/.config/mavidi-mealie/backup.key /bin/bash /mnt/d/Workspace/projects/nekurama/mealie/deploy/mavidi/backup.sh
```

If that user's home is not `/home/LINUX_USER`, substitute its actual absolute
Linux path. Set the trigger to daily, disallow overlapping instances, and enable task
history. Check the last result and backup timestamps after the first scheduled
run and regularly thereafter. Task Scheduler does not automatically alert on
failure; arrange monitoring separately. Run an isolated restore drill periodically
and after upgrades or key changes, using the same key and a selected completed
archive. Do not record the passphrase in scheduler arguments or logs.

## Upstream sync and upgrades

Keep changes confined to `deploy/mavidi` when syncing upstream. Review upstream
release notes, Compose and image changes, SQLite migration and rollback guidance,
and reconcile conflicts without silently replacing local defaults. Before an
upgrade, make an encrypted backup and successfully drill it with the current
image. Pin the reviewed stable version in `compose.yaml`, obtain it only after
approval, and verify service health and a new backup/drill after upgrading.
Keep the old image and pre-upgrade backup for recovery; a database migration may
make simply switching the image back unsafe.
