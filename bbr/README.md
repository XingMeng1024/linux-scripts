# BBR

启用内核自带的 BBR 和默认 FQ。不升级内核，不替换网卡当前队列。

## 一键安装

适用系统和下载提示见[项目首页](../README.md)。

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/bbr/install.sh -o "$f" &&
  sudo bash "$f")
```

## 查看与卸载

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
tc qdisc show
sudo bash bbr/uninstall.sh
```

`tc qdisc show` 显示网卡当前队列，可能与默认队列不同。配置写入 `/etc/sysctl.d/99-linux-scripts-bbr.conf`；卸载仅在没有冲突时恢复原值。卸载命令在仓库根目录运行，无终端时可加 `--yes`。
