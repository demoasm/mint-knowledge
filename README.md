# 薄荷知识库

文档管理、知识检索与辅助问答。此仓库独立维护，不属于腾讯官方产品。

## 开发与发布

- 本地源码：E:\mint-knowledge。
- 现有本地凭据、运行数据及镜像缓存继续保留在 E:\WeKnora，禁止加入 Git。
- 云端配置和数据保持在 /opt/weknora，不因仓库迁移而重新初始化。
- GitHub Actions：main 提交自动构建镜像，成功后自动发布；也支持手动选择完整提交 SHA 发布。
- 新版本使用 ghcr.io/demoasm/mint-knowledge-*；旧镜像保留供回退。

## 开源声明

基于 WeKnora 修改，保留原始 LICENSE、THIRD_PARTY_NOTICES.md 及 licenses/ 中的版权与第三方声明。
修改包括独立品牌、主题、平台管理员权限、知识库配置精简和部署流程。
本仓库采用代码快照导入，不携带上游 Git 历史或 fork 关系。