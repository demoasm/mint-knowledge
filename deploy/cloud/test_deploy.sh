#!/bin/bash
set -euo pipefail
mkdir -p /opt/weknora /tmp/mock-bin
cat > /tmp/mock-bin/docker <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> /tmp/docker-calls
exit 0
MOCK
cat > /tmp/mock-bin/curl <<'MOCK'
#!/bin/bash
exit 0
MOCK
chmod +x /tmp/mock-bin/*
export PATH=/tmp/mock-bin:$PATH
cd /opt/weknora
cat > release.yaml <<'JSON'
{"services":{"app":{"image":"pinned-app:old"},"frontend":{"image":"pinned-ui:old"},"docreader":{"image":"pinned-docreader:old"}}}
JSON
SSH_ORIGINAL_COMMAND='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa frontend' bash /source/deploy.sh </dev/null
python3 - <<'PY'
import json
r=json.load(open('/opt/weknora/release.yaml'))['services']
assert r['app']['image']=='pinned-app:old'
assert r['docreader']['image']=='pinned-docreader:old'
assert r['frontend']['image'].endswith(':aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
calls=open('/tmp/docker-calls').read().splitlines()
assert any('pull frontend' in c for c in calls)
assert any('up -d --no-deps --no-build frontend' in c for c in calls)
assert not any('exec' in c or 'postgres' in c or 'redis' in c for c in calls)
assert open('/opt/weknora/current-source').read().strip()=='a'*40
print('PASS: UI-only deployment preserves backend/parser pins and does not touch database')
PY