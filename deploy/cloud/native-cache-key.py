"""Stable keys for the native artifacts actually consumed by the app image."""
import hashlib
from pathlib import Path
import sys

def cache_key(root, component):
    root = Path(root)
    # Include the complete build recipe to invalidate base images, compiler flags,
    # mirrors, output layout and ABI changes as well as component source changes.
    paths = [root / 'docker/Dockerfile.app', root / 'deploy/cloud/native-artifacts.sh']
    if component == 'browserskill':
        paths += [root / 'scripts/build_browserskill.sh', root / 'scripts/browserskill-release.json']
    elif component == 'anydoc':
        paths += [root / 'scripts/build-anydoc-lib.sh']
        vendor = root / 'third_party/anydoc-go'
        paths += [vendor / name for name in ('Cargo.toml', 'Cargo.lock', 'build.rs', 'version.go', 'LICENSE')]
        paths += sorted((vendor / 'src').rglob('*.rs'))
        paths += sorted((vendor / 'include').rglob('*.[hH]'))
    else:
        raise ValueError('Unknown native component')
    h = hashlib.sha256(b'mint-native-v1-linux-amd64-build-jobs-1\0')
    for path in paths:
        h.update(path.relative_to(root).as_posix().encode() + b'\0')
        h.update(path.read_bytes() + b'\0')
    return h.hexdigest()

if __name__ == '__main__':
    print(cache_key(sys.argv[1], sys.argv[2]))
