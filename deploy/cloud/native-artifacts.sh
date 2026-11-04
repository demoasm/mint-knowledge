#!/bin/bash
# Sourced by server-build.sh. This creates artifact images, never deployments.
ensure_native_artifacts() {
 local source=$1 component key image target
 for component in browserskill anydoc; do
  key=$(python3 "$source/deploy/cloud/native-cache-key.py" "$source" "$component")
  image="$tcb_repo:native-$component-linux-amd64-$key"
  target="$component-artifacts"
  if timeout 60 docker manifest inspect "$image" >/dev/null 2>&1; then
   echo "Reuse native artifact: $component ($key); Rust compilation skipped"
  else
   echo "Build native artifact: $component ($key)"
   timeout 2400 docker buildx build --builder mint-server-builder --platform linux/amd64 --load \
    --target "$target" --progress plain -f "$source/docker/Dockerfile.app" -t "$image" \
    --build-arg APK_MIRROR_ARG=mirrors.tencent.com --build-arg BUILD_PARALLELISM=1 \
    --build-arg GOPROXY_ARG=https://goproxy.cn,direct \
    --build-arg RUSTUP_DIST_SERVER=https://rsproxy.cn --build-arg RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup \
    --build-arg CARGO_MIRROR=sparse+https://rsproxy.cn/index/ \
    --build-arg NPM_REGISTRY=https://registry.npmmirror.com "$source"
   timeout 600 docker push "$image"
  fi
  if [[ "$component" == browserskill ]]; then
   BROWSERSKILL_ARTIFACT_IMAGE=$image
  else
   ANYDOC_ARTIFACT_IMAGE=$image
  fi
 done
}
