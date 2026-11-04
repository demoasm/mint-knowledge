#!/bin/bash
set -euo pipefail
command=${SSH_ORIGINAL_COMMAND:-}
cd /opt/weknora
if [[ "$command" == status ]]; then
 cat current-source 2>/dev/null || printf 'unknown\n'
 exit 0
fi
# Registry credentials only live in a temporary per-invocation Docker config.
tcb_repo=ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git
login_tcb() {
 local password
 IFS= read -r -t 10 password || { echo 'TCB password missing on stdin' >&2; return 1; }
 [[ -n "$password" ]] || return 1
 export DOCKER_CONFIG
 DOCKER_CONFIG=$(mktemp -d /opt/weknora/.tcb-auth.XXXXXX)
 trap 'rm -f -- "$DOCKER_CONFIG/config.json"; rmdir -- "$DOCKER_CONFIG"' EXIT
 printf '%s\n' "$password" | timeout 30 docker login ccr.ccs.tencentyun.com --username 100006345097 --password-stdin >/dev/null
 unset password
}
# One-time registry migration: seed cached production layers from within
# Tencent Cloud. Only new bootstrap tags are created; no containers are changed.
if [[ "$command" =~ ^tcb-bootstrap\ ((app|frontend)(,(app|frontend))*)$ ]]; then
 IFS=, read -r -a seed_services <<< "${BASH_REMATCH[1]}"
 login_tcb
 base=(docker compose -f docker-compose.yml -f compose.cloud.yaml -f release.yaml)
 for service in "${seed_services[@]}"; do
  cid=$("${base[@]}" ps -q "$service")
  [[ -n "$cid" ]] || exit 1
  image_id=$(docker inspect "$cid" --format '{{.Image}}')
  component=$service
  [[ "$service" != frontend ]] || component=ui
  image="$tcb_repo:bootstrap-$component-${image_id#sha256:}"
  docker tag "$image_id" "$image"
  started=$SECONDS
  timeout 600 docker push "$image"
  echo "TCB cache seeded: $service in $((SECONDS-started))s; no services changed"
 done
 exit 0
fi
if [[ "$command" =~ ^tcb-probe\ (probe-[0-9]{1,20}-[0-9]{1,3})$ ]]; then
 tag=${BASH_REMATCH[1]}
 login_tcb
 started=$SECONDS
 timeout 120 docker pull "$tcb_repo:$tag"
 docker image inspect "$tcb_repo:$tag" --format 'TCB probe image: {{.Id}} ({{.Size}} bytes)'
 echo "TCB server pull completed in $((SECONDS-started))s; no services changed"
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
[[ "$command" =~ ^(deploy|tcb|build)\ ([0-9a-f]{40})\ ((app|frontend|docreader)(,(app|frontend|docreader))*)$ ]] || exit 2
transport=${BASH_REMATCH[1]}; version=${BASH_REMATCH[2]}; components=${BASH_REMATCH[3]}
IFS=, read -r -a services <<< "$components"
exec 9>/opt/weknora/deploy.lock
flock -w 60 9 || exit 3
if [[ "$transport" == tcb || "$transport" == build ]]; then login_tcb; fi
if [[ "$transport" == build ]]; then
 source /opt/weknora/server-build.sh
 build_release_from_source "$version" "$components"
 echo "Build and TCB backup complete; manual deployment required: $version ($components)"
 exit 0
fi
python3 - "$version" "$components" "$transport" <<'PY'
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
    if sys.argv[3] in ('tcb','build'):
        image=f'ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git:{component}-{sys.argv[1]}'
    else:
        image=f'ghcr.io/demoasm/mint-knowledge-{component}:{sys.argv[1]}'
    release['services'][service]['image']=image
Path('release.next.yaml').write_text(json.dumps(release,indent=2)+'\n')
PY
base=(docker compose -f docker-compose.yml -f compose.cloud.yaml)
declare -A expected_images
for service in "${services[@]}"; do
 component=$service
 [[ "$service" != frontend ]] || component=ui
 if [[ "$transport" == tcb ]]; then
  image="$tcb_repo:$component-$version"
  pulled=false
  for attempt in 1 2; do
   if timeout 300 docker pull "$image"; then pulled=true; break; fi
   sleep 5
  done
  $pulled || { echo "TCB pull failed: $service" >&2; exit 1; }
  expected_images[$service]=$(docker image inspect "$image" --format '{{.Id}}')
 elif [[ "$transport" == build ]]; then
  image="$tcb_repo:$component-$version"
  expected_images[$service]=$(docker image inspect "$image" --format '{{.Id}}')
 else
  # Retain the validated SSH import protocol for already-imported releases.
  receipt="incoming/$version/$service.ready"
  [[ -f "$receipt" ]] || { echo "Missing delivered image: $service" >&2; exit 1; }
  image="ghcr.io/demoasm/mint-knowledge-$component:$version"
  expected_images[$service]=$(cat "$receipt")
  [[ "$(docker image inspect "$image" --format '{{.Id}}')" == "${expected_images[$service]}" ]] || exit 1
 fi
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
  [[ "$(docker inspect "$cid" --format '{{.Image}}')" == "${expected_images[$service]}" ]] || return 1
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