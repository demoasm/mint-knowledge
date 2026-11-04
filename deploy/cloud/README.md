# 服务器源码构建与 TCB 备份

主流水线由 GitHub Actions 触发，按变化选择组件，通过现有受限 SSH 密钥执行服务器固定入口。服务器从 demoasm/mint-knowledge 拉取指定 SHA，串行构建并导入本机 Docker，推送 TCB 后发布。Actions 不再构建或传输镜像，GHCR 不再新增留档。

镜像：ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git:<app|ui|docreader>-<SHA>。
未变化的组件保留原镜像；Nginx 随 frontend 镜像，仅前端变更才重建，docreader 按需更新。

## 服务器准备

将 deploy.sh 安装为 /opt/weknora/ci-deploy.sh，同时安装 server-build.sh、buildkitd.toml 到同目录。密钥强制命令不变。GitHub production 环境继续使用 TCB_PASSWORD 和现有 DEPLOY_* secrets，密码经 stdin 传递，临时 Docker 登录配置在退出时清理。

源码、日志、Buildx 元数据和新建 Swap 位于 /opt/mint-knowledge-build，与在线 Compose 数据独立。初次构建要求至少 8 GiB 空闲空间。没有 Swap 时创建并启用独立 2 GiB 文件，不改 fstab。构建器限 1 核、1800 MiB 内存，允许总计 3800 MiB 内存加 Swap，串行构建，保留缓存。首次冷构建需下载基础镜像、Go/Rust/Node 依赖；后续复用缓存。

国内镜像源仅对服务器构建传参启用。构建前验证提交 SHA 及干净工作区；不会重置已有工作区。所有选中组件构建及 TCB 备份成功后才更新 release.yaml。应用更新前备份数据库，校验运行镜像及健康状态，失败回滚，Compose 使用 --pull never。

## 手动操作

Actions 中 Build and deploy on server 可手动选组件；Deploy lightweight server 可用已有 TCB 镜像 SHA 重发或回退。保留 tcb、tcb-probe、tcb-bootstrap、receive、deploy 协议用于历史版本和诊断。服务器构建日志在 /opt/mint-knowledge-build/logs/<SHA>.log。

隔离测试：python3 -m unittest discover -s deploy/cloud -p 'test_*.py'，以及 bash deploy/cloud/test_deploy.sh。后者只能在临时 CI runner 或隔离容器运行，不要在真实服务目录执行。
