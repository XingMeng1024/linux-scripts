# SOCKS5：3proxy LTS

使用官方签名 APT `lts/main` 的 **3proxy 0.9.9.4**（`0.9.9.4-261121091843`）。仅提取 `./bin/3proxy`，不会安装上游服务、编译源码或引入容器。AMD64 与 ARM64 使用各自的固定 SHA256；官方包适用于 Debian 12/13、Ubuntu 22.04/24.04，实测范围见[测试记录](../tests/RESULTS.md)。

## 安装

```bash
sudo bash socks5/install.sh
sudo bash socks5/install.sh --port 31080 --username myuser --public-ip proxy.example.com
sudo bash socks5/install.sh --allow-source 203.0.113.17 --allow-source 198.51.100.0/24
sudo bash socks5/install.sh --no-bbr --enable-log
bash socks5/install.sh --help
```

| 参数 | 用途 |
| --- | --- |
| `--port` | IPv4 TCP 监听端口，默认 `21080`，范围 `1024–65535` |
| `--username` | 默认 `tgproxy`；1–32 位 ASCII 字母、数字、下划线或连字符，不以连字符开头 |
| `--public-ip` | 连接信息里的公网 IPv4 或域名，不影响实际监听 |
| `--allow-source` | 可重复，允许指定 IPv4 或 `/1`–`/32` CIDR；仍保留 `127.0.0.1` 本机自检 |
| `--no-bbr` | 不修改全局 BBR/FQ |
| `--enable-log` | 访问元数据写入 journal（含客户端、目标地址及流量，不记录密码）；默认关闭 |

密码是 32 位十六进制随机串，最多 256 并发。使用 `socks5.service`、专用用户 `svc-3proxy-socks`，开机自启，故障重启。只允许经过口令认证的 TCP CONNECT；拦截私网、环回、链路本地、元数据、CGNAT、组播及保留 IP，禁止 IPv6、UDP 和 BIND。自定义路由或 DNAT 将公网地址映射成内部地址时，应另加出站限制。

**普通 SOCKS5 协商传输未加密。** 请先在云安全组及本机防火墙按来源放行单个 TCP 端口，再部署。脚本不会替你修改防火墙。自动查到的是出口地址；如 NAT 或外部端口有转发，需要手动填写入站端点。安装自检是本机测试，不代表公网可达或 Telegram 已连通。

## 管理与排查

```bash
sudo cat /srv/net-services/socks5/connection.txt  # 明文，权限 0600，勿分享
sudo systemctl status socks5.service
sudo systemctl start socks5.service
sudo systemctl stop socks5.service
sudo systemctl restart socks5.service
sudo journalctl -u socks5.service -n 80 --no-pager
sudo ss -ltnp 'sport = :21080'
sudo ss -tnp state established 'sport = :21080'
sudo /srv/net-services/socks5/3proxy --help
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
sudo bash socks5/uninstall.sh --yes
```

改端口时编辑 `3proxy.cfg` 的 `socks ... -p端口`；改口令时更新 `users NAME:CL:PASSWORD`，改账号还需修改 `allow NAME ...`。以 root 编辑、保留配置 `0640`、同步更新连接文件和防火墙，重启后复测。使用 `od -An -v -tx1 -N16 /dev/urandom | tr -d ' \n'` 生成新密码。不支持重复安装覆盖或就地升级。

如遇 `CHDIR` 或 `EXEC`，用 `namei -l /srv/net-services/socks5/3proxy` 和 `findmnt -T /srv/net-services/socks5` 检查所有上级目录、挂载及 AppArmor/SELinux 日志，不关闭防护。软件源不可达时检查 `getent ahostsv4 3proxy.org`、时钟与 CA，不能关闭验证。如果必要依赖需要升级已有库，先按系统维护策略处理再重跑。

条件补齐 `curl`、`ca-certificates`、`iproute2`、APT 签名工具、PCRE2 和 OpenSSL 3 运行库，只新增不升级或移除已安装软件包。安装文件在 `/srv/net-services/socks5/`，unit 在 `/etc/systemd/system/`。上级目录若已存在则不修改权限。使用临时 APT 目录，不永久添加 3proxy 软件源。独立 BBR 模块配置存在时不重复调优；否则可选调优写入 `/etc/sysctl.d/90-3proxy-socks5-installer.conf`，卸载保留所有共享依赖及全局网络配置。

官方资料：[签名软件源及指纹](https://3proxy.org/repo/) · [LTS Release](https://github.com/3proxy/3proxy/releases/tag/0.9.9.4) · [配置手册](https://3proxy.org/doc/man3/3proxy.cfg.3.html) · [上游许可证](https://github.com/3proxy/3proxy/blob/0.9.9.4/copying)。
