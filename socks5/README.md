# SOCKS5

安装 3proxy LTS，只允许通过密码认证的 TCP 代理。默认端口 `21080`，新安装的用户名和密码随机生成。

## 一键安装

适用系统和下载提示见[项目首页](../README.md)。SOCKS5 不加密，请在云安全组和本机防火墙限制来源 IP。

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/socks5/install.sh -o "$f" &&
  if [ "$(id -u)" -eq 0 ]; then bash "$f"; else sudo bash "$f"; fi)
```

可在两个 `bash "$f"` 分支后追加 `--port`、`--username`、`--public-ip` 或 `--allow-source`。`--no-bbr` 跳过全局网络调优；`--enable-log` 启用访问日志。完整参数见 `bash socks5/install.sh --help`。

## 一键更新

在交互终端运行不带参数的安装命令，检测到本项目的正常安装时会询问是否更新，输入 `yes` 确认。无终端或已确认要更新时，运行：

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/socks5/install.sh -o "$f" &&
  if [ "$(id -u)" -eq 0 ]; then bash "$f" --update; else sudo bash "$f" --update; fi)
```

更新会替换为脚本固定的 3proxy 版本（不追踪最新版），保留账号、密码、端口和原配置。更新时会重启服务、短暂断开连接；自检失败会尝试恢复旧程序和服务。`--update` 不与安装参数混用。

如果目录不属于本项目、服务未正常运行或配置不兼容，脚本会拒绝覆盖。请先检查安装来源、备份旧配置，再决定如何迁移；不要直接删除目录。

## 查看状态

```bash
sudo cat /srv/net-services/socks5/connection.txt
sudo systemctl status socks5.service
sudo journalctl -u socks5.service -n 50 --no-pager
```

连接文件含明文密码，请勿分享。脚本的本机自检不代表公网可达。

## 一键卸载

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/socks5/uninstall.sh -o "$f" &&
  if [ "$(id -u)" -eq 0 ]; then bash "$f"; else sudo bash "$f"; fi)
```

按提示确认；无终端时可加 `--yes`。卸载会保留共享依赖和全局网络配置。
