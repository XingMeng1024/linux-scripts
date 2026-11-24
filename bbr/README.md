# BBR：内核网络调优

在 Debian 12/13 或 Ubuntu 22.04/24.04 上启用内核自带 BBR 和默认 FQ，支持原生 AMD64/ARM64，要求 systemd 和 root。不安装包、第三方内核或 BBR Plus，不升级内核，不设置 MTU/TCP 缓冲区，不替换网卡根队列。不支持 BBR 或无法设置 FQ 时退出，尽量恢复本次修改。

```bash
sudo bash bbr/install.sh
bash bbr/install.sh --help
sysctl net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control net.core.default_qdisc
ip -4 route show default
tc qdisc show
sudo bash bbr/uninstall.sh           # 在终端确认
sudo bash bbr/uninstall.sh --yes     # 自动化确认
```

模块仅创建 `/etc/sysctl.d/99-linux-scripts-bbr.conf`（记录原值）。安装前读取 systemd 配置加载顺序，检测在后面覆盖的显式冲突，并检查 `/etc/sysctl.conf`；不会覆盖已有同名文件。其他配置已经持久启用 BBR/FQ 时不接管。卸载只删除内容匹配本模块的文件；当前值被改动或存在冲突策略时保留运行值，不擅自恢复为某个固定算法。

默认 `fq` 是给系统选新队列的默认值，`tc qdisc show` 才代表网卡当前所用队列；两者可以不同。缺少 `ip`/`tc` 时仅提示，不安装诊断工具。BBR 不能突破物理上行或云厂商限速。

官方资料：[Linux sysctl 网络参数](https://docs.kernel.org/admin-guide/sysctl/net.html) · [systemd sysctl.d 规范](https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html)。
