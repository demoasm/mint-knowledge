#!/bin/bash
# Run only on an ephemeral CI runner or inside an isolated test container.
set -euo pipefail
[[ ! -e /opt/weknora/docker-compose.yml && ! -e /opt/weknora/.env ]] || { echo 'Refusing to test in a production directory' >&2; exit 1; }
source_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p /opt/weknora /tmp/mock-bin
cat > /tmp/mock-bin/docker <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/docker-calls
if [[ "$*" == *' pull '* ]]; then echo 'Registry pull forbidden' >&2; exit 99; fi
if [[ "$1 $2" == 'image inspect' || "$1" == inspect ]]; then echo 'sha256:test-image'; exit 0; fi
if [[ "$1" == load && "${MOCK_FAIL_LOAD:-0}" == 1 ]]; then exit 1; fi
if [[ "$*" == *' ps -q '* ]]; then echo test-container; fi
if [[ "$*" == *' up '* && "${MOCK_FAIL_UP:-0}" == 1 && ! -e /tmp/failed-up ]]; then touch /tmp/failed-up; exit 1; fi
if [[ "$*" == *' exec -T postgres '* ]]; then echo database-backup; fi
MOCK
cat > /tmp/mock-bin/curl <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x /tmp/mock-bin/*
export PATH=/tmp/mock-bin:$PATH
cd /opt/weknora
version=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
other=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
fixture() {
 python3 - "$1" "$2" "$3" <<'PY'
import io,json,sys,tarfile
component,version,dest=sys.argv[1:]
image=f'ghcr.io/demoasm/mint-knowledge-{component}:{version}'
with tarfile.open(dest,'w:gz') as tar:
    data=json.dumps([{'Config':'config.json','RepoTags':[image],'Layers':[]}]).encode()
    member=tarfile.TarInfo('manifest.json'); member.size=len(data)
    tar.addfile(member,io.BytesIO(data))
PY
}
receive() {
 local v=$1 component=$2 file=$3
 local checksum size
 checksum=$(sha256sum "$file" | cut -d' ' -f1); size=$(stat -c %s "$file")
 SSH_ORIGINAL_COMMAND="receive $v $component $checksum $size" bash "$source_dir/deploy.sh" < "$file"
}
reset_release() {
 cat > release.yaml <<'JSON'
{"services":{"app":{"image":"pinned-app:old"},"frontend":{"image":"pinned-ui:old"},"docreader":{"image":"pinned-docreader:old"}}}
JSON
 echo old > current-source
 : > /tmp/docker-calls
}
fixture ui "$version" /tmp/ui.tar.gz
receive "$version" frontend /tmp/ui.tar.gz
[[ $(cat "incoming/$version/frontend.ready") == sha256:test-image ]]
# Invalid input, truncation, checksum/tag mismatch and load failure must not
# create an import receipt or reach deployment.
if SSH_ORIGINAL_COMMAND='receive ../../bad' bash "$source_dir/deploy.sh" </dev/null; then exit 1; fi
size=$(stat -c %s /tmp/ui.tar.gz)
if SSH_ORIGINAL_COMMAND="receive $other frontend $(printf '%064d' 0) $size" bash "$source_dir/deploy.sh" </tmp/ui.tar.gz; then exit 1; fi
checksum=$(sha256sum /tmp/ui.tar.gz | cut -d' ' -f1)
if SSH_ORIGINAL_COMMAND="receive $other frontend $checksum $((size+10))" bash "$source_dir/deploy.sh" </tmp/ui.tar.gz; then exit 1; fi
if receive "$other" frontend /tmp/ui.tar.gz; then exit 1; fi
fixture ui "$other" /tmp/other-ui.tar.gz
if MOCK_FAIL_LOAD=1 receive "$other" frontend /tmp/other-ui.tar.gz; then exit 1; fi
[[ ! -e "incoming/$other/frontend.ready" ]]
reset_release
before=$(sha256sum release.yaml)
if SSH_ORIGINAL_COMMAND="deploy $other frontend" bash "$source_dir/deploy.sh"; then exit 1; fi
[[ $(sha256sum release.yaml) == "$before" && $(cat current-source) == old ]]
[[ ! -s /tmp/docker-calls ]]
SSH_ORIGINAL_COMMAND="deploy $version frontend" bash "$source_dir/deploy.sh"
python3 - <<'PY'
import json
r=json.load(open('release.yaml'))['services']
assert r['app']['image']=='pinned-app:old'
assert r['docreader']['image']=='pinned-docreader:old'
assert r['frontend']['image'].endswith(':'+'a'*40)
calls=open('/tmp/docker-calls').read().splitlines()
assert any('up -d --no-deps --no-build --pull never frontend' in c for c in calls)
assert not any(' pull ' in c or 'exec' in c or 'postgres' in c or 'redis' in c for c in calls)
assert open('current-source').read().strip()=='a'*40
print('PASS: UI-only deployment preserves backend/parser pins and database')
PY
fixture app "$version" /tmp/app.tar.gz
receive "$version" app /tmp/app.tar.gz
reset_release
SSH_ORIGINAL_COMMAND="deploy $version app" bash "$source_dir/deploy.sh"
grep -q 'exec -T postgres' /tmp/docker-calls
grep -q 'up -d --no-deps --no-build --pull never app' /tmp/docker-calls
[[ -s "backups/pre-$version.sql.gz" ]]
reset_release
if MOCK_FAIL_UP=1 SSH_ORIGINAL_COMMAND="deploy $version frontend" bash "$source_dir/deploy.sh"; then exit 1; fi
[[ $(sha256sum release.yaml) == "$before" && $(cat current-source) == old ]]
[[ $(grep -c 'up -d --no-deps --no-build --pull never frontend' /tmp/docker-calls) == 2 ]]
echo 'PASS: checksum/truncation/tag/load failures rejected; missing imports blocked; app backup and rollback preserved'
