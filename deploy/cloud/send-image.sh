#!/bin/bash
set -euo pipefail
version=${1:?commit SHA required}
component=${2:?component required}
[[ "$version" =~ ^[0-9a-f]{40}$ ]] || exit 2
[[ "$component" =~ ^(app|ui|docreader)$ ]] || exit 2
source "$(dirname "$0")/ssh-client.sh"
image="ghcr.io/demoasm/mint-knowledge-$component:$version"
# The build job loads its output directly. Manual publishing pulls on the
# Actions runner, never on the production server.
if ! docker image inspect "$image" >/dev/null 2>&1; then
 timeout 600 docker pull "$image"
fi
archive=$(mktemp "${RUNNER_TEMP}/mint-${component}.XXXXXX.tar.gz")
trap 'rm -f -- "$archive"' EXIT
started=$SECONDS
timeout 600 bash -o pipefail -c 'docker save "$1" | gzip -1 > "$2"' _ "$image" "$archive"
checksum=$(sha256sum "$archive" | cut -d' ' -f1)
size=$(stat -c %s "$archive")
service=$component
[[ "$component" != ui ]] || service=frontend
for attempt in 1 2; do
 if timeout 600 "${SSH[@]}" "$REMOTE" "receive $version $service $checksum $size" < "$archive"; then
  echo "Delivered $service: $size compressed bytes in $((SECONDS-started))s (pack + transfer + import)"
  exit 0
 fi
 echo "Image delivery attempt $attempt failed" >&2
 sleep 5
done
exit 1
