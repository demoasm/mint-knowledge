# ������Դ�빹���� TCB ����

����ˮ���� GitHub Actions ���������仯ѡ�������ͨ���������� SSH ��Կִ�з������̶���ڡ��������� demoasm/mint-knowledge ��ȡָ�� SHA�����й��������뱾�� Docker������ TCB ������������Զ�������ǰ��˲��ö����������񣬷�������Դ���ޣ���˴���ִ�С�Actions ���ٹ������侵��GHCR ��������������

����ccr.ccs.tencentyun.com/tcb-100006345097-fwhd/git:<app|ui|docreader>-<SHA>��
δ�仯���������ԭ����Nginx �� frontend ���񣬽�ǰ�˱�����ؽ���docreader ������¡�

## ������׼��

�� deploy.sh ��װΪ /opt/weknora/ci-deploy.sh��ͬʱ��װ server-build.sh��buildkitd.toml ��ͬĿ¼����Կǿ������䡣GitHub production ��������ʹ�� TCB_PASSWORD ������ DEPLOY_* secrets�����뾭 stdin ���ݣ���ʱ Docker ��¼�������˳�ʱ������

Դ�롢��־��Buildx Ԫ���ݺ��½� Swap λ�� /opt/mint-knowledge-build�������� Compose ���ݶ��������ι���Ҫ������ 8 GiB ���пռ䣻���л���ʱ���� 2 GiB��û�� Swap ʱ���������ö��� 2 GiB �ļ������� fstab���������� 1 �ˡ�1800 MiB �ڴ棬�����ܼ� 3800 MiB �ڴ�� Swap�����й������������档�״��乹�������ػ�������Go/Rust/Node �������������û��档

���ھ���Դ���Է����������������á�����ǰ��֤�ύ SHA ���ɾ��������������������й��������������޸� release.yaml��current-source�����������ݿ����������ֻ���ֶ������������Ÿ�����Щ״̬��Ӧ�ø���ǰ�������ݿ⣬У�����о��񼰽���״̬��ʧ�ܻع���Compose ʹ�� --pull never��

## �ֶ�����

Actions �� Build images on server ���ֶ�ѡ�����Deploy lightweight server �������� TCB ���� SHA �ط�����ˡ����� tcb��tcb-probe��tcb-bootstrap��receive��deploy Э��������ʷ�汾����ϡ�������������־�� /opt/mint-knowledge-build/logs/<SHA>.log��

������ԣ�python3 -m unittest discover -s deploy/cloud -p 'test_*.py'���Լ� bash deploy/cloud/test_deploy.sh������ֻ������ʱ CI runner ������������У���Ҫ����ʵ����Ŀ¼ִ�С�

## Rust 组件产物复用

服务器构建 app 前分别查询 TCB 的 native-browserskill-linux-amd64-<SHA256> 和 native-anydoc-linux-amd64-<SHA256>。指纹包含 Docker 构建配置、原生产物构建脚本及各组件固定版本/源码；不包含日常业务 Go 代码或 go.mod。命中时不执行 Rust 编译；只有缺少对应指纹产物时才构建并推送各自的 artifacts target。

产物镜像仅保存 BrowserSkill 的可执行文件、扩展和许可证，或 anydoc 的静态库，不包含 Rust 工具链及中间 target。app 构建通过 BROWSERSKILL_IMAGE、ANYDOC_IMAGE 使用它们；即使 BuildKit 缓存被回收也可从 TCB 复用。第一次建立这些标签仍需编译；不提供参数的本地 app Docker 构建保留从源码构建的兼容行为。

构建成功仍只备份 TCB，不自动发布或修改运行中的服务。
