# TCB 镜像发布

GitHub Actions 按变化组件构建，推送两份标签：
- 线上分发：`ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git:<component>-<commit SHA>`。
- GHCR 留档：`ghcr.io/demoasm/mint-knowledge-<component>:<commit SHA>`。

component 为 app/ui/docreader，服务名 frontend 对应 ui。未变化的镜像保持原版本。

在 GitHub production 环境配置 `TCB_PASSWORD`；用户名固定为 100006345097。
Actions 经现有受限 SSH 部署密钥将密码从 stdin 传入服务器。服务器使用临时 Docker 配置登录 TCB，仅拉取选中的镜像；成功和失败退出都会清理临时凭据，不修改现有 .env 或 Docker 登录配置。

发布继续保留应用更新前数据库备份、仅重建选中服务、实际运行镜像校验、健康检查及回滚。Compose 启动使用 --pull never，所有网络拉取都在切换服务之前完成并设超时/重试。

手动 `Check TCB push and server pull` 会上传 1 MiB 的 probe 标签并在服务器拉取，不启动任何测试容器或更新业务服务。
手动 `Build Mint images` 可指定组件强制重建。手动 `Deploy lightweight server` 可填已有 TCB 镜像 SHA 重发或回退；迁移前只有 GHCR 标签的版本需先在 TCB 镜像仓库补齐对应标签。

服务器固定入口仍为 `/opt/weknora/ci-deploy.sh`，原受限密钥不变。新增协议 `tcb SHA services` 和 `tcb-probe probe-run-attempt` 只允许固定仓库和合法标签；原 `receive`/`deploy` 直传协议保留以兼容已导入版本。主流水线不再经 SSH 传输大镜像。

在隔离环境运行 `bash deploy/cloud/test_deploy.sh` 和组件选择单元测试；不要在生产目录执行测试脚本。
