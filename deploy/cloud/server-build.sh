#!/bin/bash
# Sourced by the fixed deployment entrypoint, while holding deploy.lock.
prepare_build_host() {
 local root=$1
 mkdir -p "$root/sources" "$root/logs" "$root/buildx"
 local available
 available=$(df -PB1 "$root" | awk 'NR==2 {print $4}')
 local minimum=8589934592
 [[ ! -d "$root/buildx/instances" ]] || minimum=2147483648
 (( available > minimum )) || { echo 'Insufficient disk: first build needs 8 GiB; cached build needs 2 GiB free' >&2; return 1; }
 if [[ "$(awk '/SwapTotal/ {print $2}' /proc/meminfo)" == 0 ]]; then
  if [[ ! -e "$root/swapfile" ]]; then
   fallocate -l 2G "$root/swapfile"
   chmod 600 "$root/swapfile"
   mkswap "$root/swapfile" >/dev/null
  fi
  [[ ! -L "$root/swapfile" ]] || return 1
  swapon "$root/swapfile"
 fi
 export BUILDX_CONFIG="$root/buildx"
 if ! docker buildx inspect mint-server-builder >/dev/null 2>&1; then
  docker buildx create --name mint-server-builder --driver docker-container \
   --driver-opt image=moby/buildkit:buildx-stable-1 \
   --driver-opt memory=1800m --driver-opt memory-swap=3800m \
   --driver-opt cpu-period=100000 --driver-opt cpu-quota=100000 \
   --buildkitd-config /opt/weknora/buildkitd.toml
 fi
 timeout 180 docker buildx inspect --bootstrap mint-server-builder
}

build_release_from_source() {
 local version=$1 components=$2
 local root=/opt/mint-knowledge-build
 prepare_build_host "$root"
 # Keep operational logs and all build state outside the live compose project.
 exec > >(tee -a "$root/logs/$version.log") 2>&1
 local mirror="$root/repository.git" source="$root/sources/$version"
 if [[ ! -d "$mirror" ]]; then git init --bare "$mirror"; fi
 git --git-dir="$mirror" config remote.origin.url https://github.com/demoasm/mint-knowledge.git
 timeout 300 git --git-dir="$mirror" fetch --no-tags --depth=1 origin "$version"
 [[ "$(git --git-dir="$mirror" rev-parse "$version^{commit}")" == "$version" ]] || return 1
 if [[ ! -e "$source/.git" ]]; then
  git --git-dir="$mirror" worktree add --detach "$source" "$version"
 fi
 [[ "$(git -C "$source" rev-parse HEAD)" == "$version" ]] || return 1
 [[ -z "$(git -C "$source" status --porcelain --untracked-files=all)" ]] || { echo 'Build worktree is dirty; refusing to overwrite it' >&2; return 1; }
 local service component context dockerfile image started
 local -a build_services args
 IFS=, read -r -a build_services <<< "$components"
 # Each selected component must be built AND backed up before release.yaml changes.
 for service in "${build_services[@]}"; do
  component=$service
  [[ "$service" != frontend ]] || component=ui
  context="$source"; dockerfile="$source/docker/Dockerfile.$component"
  args=(--build-arg APK_MIRROR_ARG=mirrors.tencent.com)
  case "$service" in
   app)
    if [[ -f "$source/deploy/cloud/native-artifacts.sh" ]]; then
     source "$source/deploy/cloud/native-artifacts.sh"
     ensure_native_artifacts "$source"
     args+=(--build-arg BROWSERSKILL_IMAGE="$BROWSERSKILL_ARTIFACT_IMAGE" --build-arg ANYDOC_IMAGE="$ANYDOC_ARTIFACT_IMAGE")
    fi
    args+=(--build-arg BUILD_PARALLELISM=1 --build-arg GOPROXY_ARG=https://goproxy.cn,direct
     --build-arg RUSTUP_DIST_SERVER=https://rsproxy.cn --build-arg RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup
     --build-arg CARGO_MIRROR=sparse+https://rsproxy.cn/index/
     --build-arg NPM_REGISTRY=https://registry.npmmirror.com --build-arg COMMIT_ID_ARG="$version") ;;
   frontend)
    context="$source/frontend"; dockerfile="$context/Dockerfile"
    args+=(--build-arg NPM_REGISTRY=https://registry.npmmirror.com --build-arg NODE_MAX_OLD_SPACE_SIZE=2048
     --build-arg VITE_FRONTEND_COMMIT="$version") ;;
   docreader) ;;
   *) return 2 ;;
  esac
  image="$tcb_repo:$component-$version"
  started=$SECONDS
  timeout 3600 docker buildx build --builder mint-server-builder --platform linux/amd64 --load \
   --progress plain --label "org.opencontainers.image.revision=$version" \
   -f "$dockerfile" -t "$image" "${args[@]}" "$context"
  echo "Server build completed: $service in $((SECONDS-started))s"
  timeout 600 docker push "$image"
  echo "TCB backup complete: $image"
  mkdir -p "$root/built/$version"
  docker image inspect "$image" --format '{{.Id}}' > "$root/built/$version/$service.ready.next"
  mv "$root/built/$version/$service.ready.next" "$root/built/$version/$service.ready"
 done
}
