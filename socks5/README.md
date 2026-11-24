# SOCKS5

安装 3proxy LTS，只允许通过密码认证的 TCP 代理。默认端口 `21080`、用户名 `tgproxy`，密码随机生成。

## 一键安装

适用系统和下载提示见[项目首页](../README.md)。SOCKS5 不加密，请在云安全组和本机防火墙限制来源 IP。

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/socks5/install.sh -o "$f" &&
  sudo bash "$f")
```

可在 `sudo bash "$f"` 后追加 `--port`、`--username`、`--public-ip` 或 `--allow-source`。`--no-bbr` 跳过全局网络调优；`--enable-log` 启用访问日志。完整参数见 `bash socks5/install.sh --help`。

## 查看与卸载

```bash
sudo cat /srv/net-services/socks5/connection.txt
sudo systemctl status socks5.service
sudo journalctl -u socks5.service -n 50 --no-pager
sudo bash socks5/uninstall.sh
```

连接文件含明文密码，请勿分享。脚本的本机自检不代表公网可达。卸载命令在仓库根目录运行，无终端时可加 `--yes`；卸载会保留共享依赖和全局网络配置。
