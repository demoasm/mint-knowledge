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
