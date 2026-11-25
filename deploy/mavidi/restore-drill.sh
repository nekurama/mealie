#!/usr/bin/env bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

[[ $# == 1 && "$1" == /* && -f "$1" && -r "$1" ]] || {
  echo "Usage: bash restore-drill.sh /absolute/path/to/backup.tar.gpg" >&2; exit 1;
}
archive=$1
state="${MAVIDI_BACKUP_DIR:-$HOME/.local/state/mavidi-mealie}"
key="${MAVIDI_BACKUP_KEY:-$state/backup.key}"
[[ -f "$key" && ! -L "$key" && -s "$key" && -r "$key" ]] || {
  echo "Provision a readable, nonempty key file at $key." >&2; exit 1;
}
mode=$(stat -c '%a' -- "$key")
(( (8#$mode & 077) == 0 )) || { echo "Key file must not be accessible to group or others." >&2; exit 1; }

image=$(docker compose -p mavidi-mealie -f compose.yaml config --images)
[[ -n "$image" && "$image" != *$'\n'* ]] || { echo "Expected exactly one Mealie image." >&2; exit 1; }
docker image inspect "$image" >/dev/null
volume=
container=
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$container" ]]; then
    docker rm -f "$container" >/dev/null || { echo "ERROR: remove drill container $container manually." >&2; result=1; }
  fi
  if [[ -n "$volume" ]]; then
    docker volume rm "$volume" >/dev/null || { echo "ERROR: remove drill volume $volume manually." >&2; result=1; }
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

volume=$(docker volume create)
container=$(docker create -i --pull never --network none --log-driver none \
  --mount "type=volume,source=$volume,target=/app/data,volume-nocopy" \
  --entrypoint tar "$image" -C /app/data -xf -)
gpg --batch --no-symkey-cache --pinentry-mode loopback --passphrase-file "$key" --decrypt "$archive" |
  docker start -ai "$container"
docker rm "$container" >/dev/null
container=
container=$(docker create --pull never --network none --log-driver none \
  --mount "type=volume,source=$volume,target=/app/data,volume-nocopy" --entrypoint python "$image" -c \
  'import sqlite3, sys; c = sqlite3.connect("file:/app/data/mealie.db?mode=ro", uri=True); c.execute("PRAGMA temp_store=MEMORY"); r = c.execute("PRAGMA quick_check").fetchall(); c.close(); sys.exit(0 if r == [("ok",)] else 1)')
docker start -a "$container"
docker rm "$container" >/dev/null
container=
echo "SQLite quick_check passed."

container=$(docker create --pull never --network none --log-driver none \
  --mount "type=volume,source=$volume,target=/app/data,volume-nocopy" \
  -e TMPDIR=/app/data -e SQLITE_TMPDIR=/app/data -e DB_ENGINE=sqlite -e ALLOW_SIGNUP=false -e TZ=Asia/Kolkata \
  -e DEFAULT_GROUP=MaViDi -e DEFAULT_HOUSEHOLD=MaViDi "$image")
docker start "$container" >/dev/null
healthy=0
for (( attempt=0; attempt<36; attempt++ )); do
  if docker exec "$container" curl -fsS --max-time 5 http://127.0.0.1:9000/api/app/about >/dev/null 2>&1; then
    healthy=1
    break
  fi
  [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]] || break
  sleep 5
done
(( healthy )) || { echo "ERROR: isolated Mealie did not become HTTP healthy." >&2; exit 1; }
echo "Isolated HTTP health passed; drill resources will be removed."
