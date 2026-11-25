#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

state="${MAVIDI_BACKUP_DIR:-$HOME/.local/state/mavidi-mealie}"
key="${MAVIDI_BACKUP_KEY:-$state/backup.key}"
mkdir -p -- "$state"
chmod 700 -- "$state"
exec 9>"$state/backup.lock"
flock -n 9 || { echo "Another backup is running." >&2; exit 1; }
[[ -f "$key" && ! -L "$key" && -s "$key" && -r "$key" ]] || {
  echo "Provision a readable, nonempty key file at $key." >&2; exit 1;
}
mode=$(stat -c '%a' -- "$key")
(( (8#$mode & 077) == 0 )) || { echo "Key file must not be accessible to group or others." >&2; exit 1; }

compose=(docker compose -p mavidi-mealie -f compose.yaml)
container=$("${compose[@]}" ps -q mealie)
[[ -n "$container" ]] || { echo "Mealie container not found." >&2; exit 1; }
[[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]] || {
  echo "Mealie must be running before backup." >&2; exit 1;
}
image=$(docker inspect --format '{{.Image}}' "$container")
volume=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{if eq .Type "volume"}}{{.Name}}{{end}}{{end}}{{end}}' "$container")
[[ -n "$volume" ]] || { echo "Expected a Docker volume at /app/data." >&2; exit 1; }

partial=$(mktemp "$state/.backup.XXXXXXXX")
archive="$state/mealie-$(date -u +%Y%m%dT%H%M%SZ)-${partial##*.}.tar.gpg"
restart_needed=0
helper=
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$helper" ]]; then
    docker rm -f "$helper" >/dev/null || { echo "ERROR: remove backup container $helper manually." >&2; result=1; }
  fi
  if (( restart_needed )); then
    "${compose[@]}" start mealie || { echo "ERROR: restart Mealie manually." >&2; result=1; }
  fi
  rm -f -- "$partial" || result=1
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

restart_needed=1
"${compose[@]}" stop mealie
helper=$(docker create --pull never --network none --log-driver none \
  --mount "type=volume,source=$volume,target=/app/data,readonly" --entrypoint tar "$image" -C /app/data -cf - .)
docker start -a "$helper" |
  gpg --batch --yes --no-symkey-cache --pinentry-mode loopback --passphrase-file "$key" \
    --cipher-algo AES256 --symmetric --output "$partial"
docker rm "$helper" >/dev/null
helper=
"${compose[@]}" start mealie
restart_needed=0
gpg --batch --no-symkey-cache --pinentry-mode loopback --passphrase-file "$key" --decrypt "$partial" |
  tar -tf - | grep -Fx './mealie.db' >/dev/null
mv -- "$partial" "$archive"
find "$state" -maxdepth 1 -type f -name 'mealie-*.tar.gpg' -mmin +43200 -delete
printf 'Backup created: %s\n' "$archive"
