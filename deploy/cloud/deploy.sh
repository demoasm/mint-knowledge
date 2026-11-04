#!/bin/bash
set -euo pipefail
command=${SSH_ORIGINAL_COMMAND:-}
cd /opt/weknora
if [[ "$command" == status ]]; then
  cat current-source 2>/dev/null || printf 'unknown\n'
  exit 0
fi
[[ "$command" =~ ^([0-9a-f]{40})(\ (app|frontend|docreader)(,(app|frontend|docreader))*)?$ ]] || exit 2
version=${BASH_REMATCH[1]}
components=${command#"$version"}
components=${components# }
components=${components:-app,frontend,docreader}
IFS=, read -r -a services <<< "$components"
exec 9>/opt/weknora/deploy.lock
flock -n 9 || exit 3
registry_token=""
IFS= read -r -t 5 registry_token || true
if [ -n "$registry_token" ]; then
 export DOCKER_CONFIG=$(mktemp -d /opt/weknora/.registry.XXXXXX)
 trap 'rm -rf -- "$DOCKER_CONFIG"' EXIT
 printf '%s\n' "$registry_token" | docker login ghcr.io -u demoasm --password-stdin >/dev/null
 unset registry_token
fi
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
pulled=false
for attempt in 1 2 3; do
 if "${base[@]}" -f release.next.yaml pull "${services[@]}"; then pulled=true; break; fi
 sleep $((attempt * 5))
done
$pulled || exit 1
mkdir -p backups
if [[ ",$components," == *,app,* ]]; then
 "${base[@]}" exec -T postgres sh -c 'pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip > "backups/pre-$version.sql.gz"
fi
cp release.yaml release.previous.yaml
rollback() {
 trap - ERR
 cp release.previous.yaml release.yaml
 "${base[@]}" -f release.yaml up -d --no-deps --no-build "${services[@]}" || true
}
trap rollback ERR
cp release.next.yaml release.yaml
"${base[@]}" -f release.yaml up -d --no-deps --no-build "${services[@]}"
for attempt in $(seq 1 60); do
 if curl -fsS --max-time 5 http://127.0.0.1:8080/health && curl -fsS --max-time 5 http://127.0.0.1/ >/dev/null; then
  printf '%s\n' "$version" > current-source.next
  mv current-source.next current-source
  echo "Deployment healthy: $version ($components)"
  exit 0
 fi
 sleep 5
done
rollback
exit 1