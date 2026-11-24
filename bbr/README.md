# BBR

启用内核自带的 BBR 和默认 FQ。不升级内核，不替换网卡当前队列。

## 一键安装

适用系统和下载提示见[项目首页](../README.md)。

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/bbr/install.sh -o "$f" &&
  if [ "$(id -u)" -eq 0 ]; then bash "$f"; else sudo bash "$f"; fi)
```

## 查看状态

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
tc qdisc show
```

`tc qdisc show` 显示网卡当前队列，可能与默认队列不同。

## 一键卸载

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/bbr/uninstall.sh -o "$f" &&
  if [ "$(id -u)" -eq 0 ]; then bash "$f"; else sudo bash "$f"; fi)
```

按提示确认；无终端时可加 `--yes`。配置位于 `/etc/sysctl.d/99-linux-scripts-bbr.conf`，卸载仅在没有冲突时恢复原值。
