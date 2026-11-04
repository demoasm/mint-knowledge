#!/bin/bash
set -euo pipefail
command=${SSH_ORIGINAL_COMMAND:-}
cd /opt/weknora
if [[ "$command" == status ]]; then
 cat current-source 2>/dev/null || printf 'unknown\n'
 exit 0
fi
# The deploy key can only query status, receive one versioned image or deploy
# preloaded images. No shell, scp or arbitrary destination paths are accepted.
if [[ "$command" =~ ^receive\ ([0-9a-f]{40})\ (app|frontend|docreader)\ ([0-9a-f]{64})\ ([0-9]{1,10})$ ]]; then
 version=${BASH_REMATCH[1]}; component=${BASH_REMATCH[2]}
 checksum=${BASH_REMATCH[3]}; size=${BASH_REMATCH[4]}
 [[ "$size" != 0* && "$size" -le 4294967296 ]] || exit 2
 root="incoming/$version"
 mkdir -p "$root"
 exec 8>"$root/.$component.lock"
 flock -n 8 || exit 3
 # Reserve room for importing the image as well as receiving the archive.
 available=$(df -PB1 . | awk 'NR==2 {print $4}')
 (( available > size + 2147483648 )) || { echo 'Insufficient disk space' >&2; exit 1; }
 archive=$(mktemp "$root/.$component.XXXXXX")
 trap 'rm -f -- "$archive"' EXIT
 timeout 600 head -c "$((size+1))" > "$archive"
 [[ "$(stat -c %s "$archive")" == "$size" ]] || { echo 'Incomplete image archive' >&2; exit 1; }
 [[ "$(sha256sum "$archive" | cut -d' ' -f1)" == "$checksum" ]] || { echo 'Image checksum mismatch' >&2; exit 1; }
 image_component=$component
 [[ "$component" != frontend ]] || image_component=ui
 image="ghcr.io/demoasm/mint-knowledge-$image_component:$version"
 python3 - "$archive" "$image" <<'PYMANIFEST'
import json,sys,tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    member=archive.getmember('manifest.json')
    if member.size > 1024*1024:
        raise SystemExit('Image manifest too large')
    manifest=json.load(archive.extractfile(member))
    if len(manifest)!=1 or manifest[0].get('RepoTags')!=[sys.argv[2]]:
        raise SystemExit('Unexpected image tag in archive')
PYMANIFEST
 timeout 600 docker load -i "$archive"
 docker image inspect "$image" --format '{{.Id}}' > "$root/$component.ready.next"
 mv "$root/$component.ready.next" "$root/$component.ready"
 echo "Image ready: $version $component ($size bytes, SHA256 verified)"
 exit 0
fi
[[ "$command" =~ ^deploy\ ([0-9a-f]{40})\ ((app|frontend|docreader)(,(app|frontend|docreader))*)$ ]] || exit 2
version=${BASH_REMATCH[1]}; components=${BASH_REMATCH[2]}
IFS=, read -r -a services <<< "$components"
exec 9>/opt/weknora/deploy.lock
flock -w 60 9 || exit 3
python3 - "$version" "$components" <<'PY'
import json,re,sys
from pathlib import Path
text=Path('release.yaml').read_text()
try:
    release=json.loads(text)
except json.JSONDecodeError:
    release={'services':{k:{'image':v} for k,v in re.findall(r'^  (\w+):\s*\n    image:\s*(\S+)',text,re.M)}}
if set(release.get('services',{})) != {'app','frontend','docreader'}:
    raise SystemExit('Invalid existing release; refusing to lose component pins')
for service in sys.argv[2].split(','):
    component='ui' if service=='frontend' else service
    release['services'][service]['image']=f'ghcr.io/demoasm/mint-knowledge-{component}:{sys.argv[1]}'
Path('release.next.yaml').write_text(json.dumps(release,indent=2)+'\n')
PY
base=(docker compose -f docker-compose.yml -f compose.cloud.yaml)
# A deployment must use exactly the images accepted by the receive protocol.
for service in "${services[@]}"; do
 receipt="incoming/$version/$service.ready"
 [[ -f "$receipt" ]] || { echo "Missing delivered image: $service" >&2; exit 1; }
 component=$service
 [[ "$service" != frontend ]] || component=ui
 image="ghcr.io/demoasm/mint-knowledge-$component:$version"
 [[ "$(docker image inspect "$image" --format '{{.Id}}')" == "$(cat "$receipt")" ]] || exit 1
done
mkdir -p backups
if [[ ",$components," == *,app,* ]]; then
 "${base[@]}" exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip > "backups/pre-$version.sql.gz"
fi
cp release.yaml release.previous.yaml
rollback() {
 trap - ERR
 cp release.previous.yaml release.yaml
 "${base[@]}" -f release.yaml up -d --no-deps --no-build --pull never "${services[@]}" || true
}
trap rollback ERR
cp release.next.yaml release.yaml
"${base[@]}" -f release.yaml up -d --no-deps --no-build --pull never "${services[@]}"
images_running() {
 for service in "${services[@]}"; do
  cid=$("${base[@]}" -f release.yaml ps -q "$service")
  [[ -n "$cid" ]] || return 1
  [[ "$(docker inspect "$cid" --format '{{.Image}}')" == "$(cat "incoming/$version/$service.ready")" ]] || return 1
 done
}
for attempt in $(seq 1 60); do
 if images_running && curl -fsS --max-time 5 http://127.0.0.1:8080/health && curl -fsS --max-time 5 http://127.0.0.1/ >/dev/null; then
  printf '%s\n' "$version" > current-source.next
  mv current-source.next current-source
  echo "Deployment healthy: $version ($components)"
  exit 0
 fi
 sleep 5
done
rollback
exit 1