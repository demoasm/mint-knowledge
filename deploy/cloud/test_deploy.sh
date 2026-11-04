#!/bin/bash
# Run only on an ephemeral CI runner or inside an isolated test container.
set -euo pipefail
[[ ! -e /opt/weknora/docker-compose.yml && ! -e /opt/weknora/.env ]] || { echo 'Refusing to test in a production directory' >&2; exit 1; }
source_dir=$(cd "$(dirname "$0")" && pwd)
mkdir -p /opt/weknora /tmp/mock-bin
cat > /tmp/mock-bin/docker <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/docker-calls
if [[ "$1 $2" == 'buildx inspect' && "$*" != *--bootstrap* ]]; then exit 1; fi
if [[ "$1 $2" == 'buildx build' && "${MOCK_FAIL_BUILD:-0}" == 1 ]]; then exit 1; fi
if [[ "$1" == push && "${MOCK_FAIL_PUSH:-0}" == 1 ]]; then exit 1; fi
if [[ "$1" == login ]]; then
 [[ "$(cat)" == test-password && "${MOCK_FAIL_LOGIN:-0}" != 1 ]] || exit 1
 exit 0
fi
if [[ "$1" == pull ]]; then
 [[ "$2" == ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git:* && "${MOCK_FAIL_PULL:-0}" != 1 ]] || exit 1
 exit 0
fi
if [[ "$*" == *' pull '* ]]; then echo 'Unexpected compose pull' >&2; exit 99; fi
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

# TCB mode must pull only selected services from the fixed registry, and must
# reject login/pull failures before modifying the active release.
reset_release
if printf '%s\n' test-password | MOCK_FAIL_LOGIN=1 SSH_ORIGINAL_COMMAND="tcb $version frontend" bash "$source_dir/deploy.sh"; then exit 1; fi
[[ "$(sha256sum release.yaml)" == "$before" && $(cat current-source) == old ]]
[[ ! -e .tcb-auth.* ]]
reset_release
if printf '%s\n' test-password | MOCK_FAIL_PULL=1 SSH_ORIGINAL_COMMAND="tcb $version frontend" bash "$source_dir/deploy.sh"; then exit 1; fi
[[ "$(sha256sum release.yaml)" == "$before" && $(cat current-source) == old ]]
reset_release
printf '%s\n' test-password | SSH_ORIGINAL_COMMAND="tcb $version frontend" bash "$source_dir/deploy.sh"
python3 - <<'PY'
import json
r=json.load(open('release.yaml'))['services']
assert r['app']['image']=='pinned-app:old'
assert r['docreader']['image']=='pinned-docreader:old'
assert r['frontend']['image']=='ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git:ui-'+'a'*40
calls=open('/tmp/docker-calls').read().splitlines()
assert any(c.startswith('pull ccr.ccs.tencentyun.com/') for c in calls)
assert not any('ghcr.io' in c or 'exec -T postgres' in c for c in calls)
assert not any('test-password' in c for c in calls)
print('PASS: TCB login/pull failure preserves release; UI-only TCB deployment preserves other pins')
PY
[[ -z $(find . -maxdepth 1 -type d -name '.tcb-auth.*' -print -quit) ]]
reset_release
printf '%s\n' test-password | SSH_ORIGINAL_COMMAND='tcb-probe probe-123-1' bash "$source_dir/deploy.sh"
[[ "$(sha256sum release.yaml)" == "$before" && $(cat current-source) == old ]]
! grep -q ' up ' /tmp/docker-calls
[[ -z $(find . -maxdepth 1 -type d -name '.tcb-auth.*' -print -quit) ]]
echo 'PASS: TCB probe changes no services and leaves no registry credential config'

reset_release
printf '%s\n' test-password | SSH_ORIGINAL_COMMAND='tcb-bootstrap app,frontend' bash "$source_dir/deploy.sh"
[[ "$(sha256sum release.yaml)" == "$before" && $(cat current-source) == old ]]
grep -q 'push ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git:bootstrap-app-' /tmp/docker-calls
grep -q 'push ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git:bootstrap-ui-' /tmp/docker-calls
! grep -q ' up ' /tmp/docker-calls
[[ -z $(find . -maxdepth 1 -type d -name '.tcb-auth.*' -print -quit) ]]
echo 'PASS: TCB bootstrap seeds cached layers without changing release or services'

# Source-build protocol: isolate Git, swap and Docker operations in this fixture.
cp "$source_dir/server-build.sh" /opt/weknora/server-build.sh
cp "$source_dir/buildkitd.toml" /opt/weknora/buildkitd.toml
cat > /tmp/mock-bin/git <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/git-calls
case "$*" in
 *fetch*) [[ "${MOCK_FAIL_FETCH:-0}" != 1 ]] ;;
 *rev-parse*) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
 *status*) [[ "${MOCK_DIRTY:-0}" != 1 ]] || echo dirty ;;
 'init --bare '*) mkdir -p "${@: -1}" ;;
 *'worktree add --detach '*) mkdir -p "${@: -2:1}"; touch "${@: -2:1}/.git" ;;
esac
MOCK
for tool in fallocate mkswap swapon; do
 printf '#!/bin/bash\nexit 0\n' > "/tmp/mock-bin/$tool"
done
chmod +x /tmp/mock-bin/*
for flag in MOCK_FAIL_FETCH MOCK_DIRTY MOCK_FAIL_BUILD MOCK_FAIL_PUSH; do
 reset_release
 if printf '%s\n' test-password | env "$flag=1" SSH_ORIGINAL_COMMAND="build $version app,frontend" bash "$source_dir/deploy.sh"; then exit 1; fi
 [[ "$(sha256sum release.yaml)" == "$before" && $(cat current-source) == old ]]
 ! grep -q ' up ' /tmp/docker-calls
 [[ -z $(find . -maxdepth 1 -type d -name '.tcb-auth.*' -print -quit) ]]
done
reset_release
printf '%s\n' test-password | SSH_ORIGINAL_COMMAND="build $version app,frontend" bash "$source_dir/deploy.sh"
python3 - <<'PYTEST'
import json
calls=open('/tmp/docker-calls').read().splitlines()
builds=[i for i,c in enumerate(calls) if c.startswith('buildx build ')]
pushes=[i for i,c in enumerate(calls) if c.startswith('push ')]
up=next(i for i,c in enumerate(calls) if ' up ' in c)
assert len(builds)==len(pushes)==2
assert builds[0]<pushes[0]<builds[1]<pushes[1]<up
assert not any(c.startswith('pull ') for c in calls)
assert any('--driver-opt memory=1800m' in c and '--driver-opt cpu-quota=100000' in c for c in calls)
assert any('exec -T postgres' in c for c in calls)
r=json.load(open('release.yaml'))['services']
assert r['docreader']['image']=='pinned-docreader:old'
assert r['app']['image'].endswith(':app-'+'a'*40)
assert r['frontend']['image'].endswith(':ui-'+'a'*40)
assert 'https://github.com/demoasm/mint-knowledge.git' in open('/tmp/git-calls').read()
print('PASS: server builds and TCB backups precede deployment; failures preserve the active release')
PYTEST
