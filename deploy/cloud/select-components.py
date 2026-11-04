#!/usr/bin/env python3
"""Select components from changes since the last successfully deployed source."""
import json, subprocess, sys, os
from pathlib import Path
os.chdir(Path(__file__).resolve().parents[2])
base, head = sys.argv[1:3]
all_components = ['app', 'ui', 'docreader']
try:
    subprocess.run(['git','cat-file','-e',base+'^{commit}'],check=True,capture_output=True)
    files = subprocess.check_output(['git','diff','--name-only',base,head],text=True).splitlines()
except subprocess.CalledProcessError:
    files = []
    selected = set(all_components)
else:
    selected = set()
    for f in files:
        if f.startswith('frontend/'): selected.add('ui')
        if f.startswith(('docreader/','packages/','docker/Dockerfile.docreader')): selected.add('docreader')
        if f.startswith(('internal/','cmd/','config/','third_party/','patches/','scripts/','docker/Dockerfile.app','deploy/cloud/native-')) or f in ('go.mod','go.sum','Makefile','VERSION','LICENSE','THIRD_PARTY_NOTICES.md') or f.startswith('licenses/'):
            selected.add('app')
        if f in ('.dockerignore','.gitattributes'): selected.update(all_components)
requested=sys.argv[3] if len(sys.argv)>3 else 'auto'
if requested != 'auto':
    selected=set('ui' if c=='frontend' else c for c in requested.split(','))
    if not selected or not selected.issubset(set(all_components)):
        raise SystemExit('Invalid component selection')
rows=[]
for c in all_components:
    if c in selected:
        rows.append(dict(component=c,context='frontend' if c=='ui' else '.',file='frontend/Dockerfile' if c=='ui' else 'docker/Dockerfile.'+c))
print('matrix='+json.dumps({'include':rows},separators=(',',':')))
print('components='+','.join('frontend' if c=='ui' else c for c in all_components if c in selected))
print('changed='+str(bool(rows)).lower())