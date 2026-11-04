# 镜像直传发布

main 的变化组件由 GitHub Actions 构建，同时推送 GHCR 留档并加载到 runner。
runner 用 docker save + gzip -1 打包，经现有受限 SSH 部署密钥直传服务器；服务器验证压缩包大小、SHA-256 和镜像标签，docker load 后生成导入收据。
所有组件导入成功后才更新发布：应用变更先备份数据库；仅更新选中的服务，强制 --pull never，并检查实际运行镜像与健康接口。失败恢复原镜像版本。

- 服务器不再登录或拉取 GHCR，不需要配置额外的仓库密钥。
- 自动发布会跳过已被更新的 main 提交取代的版本。
- 手动 Build Mint images 可指定 components 强制重建；auto 保持按变化选择。
- 手动 Deploy lightweight server 可填已存在的镜像 SHA 用于重发或回退。镜像在 Actions runner 拉取，再经相同 SSH 协议导入。
- 单组件压缩、传输和导入均有超时；传输失败重试一次。临时压缩包自动删除，已有镜像、.env、数据和备份不清理。
- 新协议要求先将本目录 deploy.sh 安装为服务器现有 /opt/weknora/ci-deploy.sh（原路径、所有者和 0700 权限）。受限密钥不变。
- 协议仅接受 status、receive SHA service SHA256 size、deploy SHA service[,service]；不接受任意命令和上传路径。

本地验证：在隔离容器挂载本目录至 /source，执行 bash /source/test_deploy.sh。
测试脚本会拒绝存在生产 compose 或 .env 的目录；不要直接在生产服务器执行测试。
