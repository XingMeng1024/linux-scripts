# FRP：内网服务映射

固定使用 [FRP 0.72.0 官方 Releases](https://github.com/fatedier/frp/releases/tag/v0.72.0) 的 AMD64/ARM64 Linux 归档，按官方发布的 SHA256 校验，仅提取选中的角色。需要 Debian 12/13 或 Ubuntu 22.04/24.04、systemd 和 root。没有编译、Docker 或 Go 运行依赖。

系统需要 `curl`、`ca-certificates`，服务端还需 `openssl`、`iproute2`。缺少时脚本指出具体命令，由管理员用发行版签名 APT 补齐（例如 `sudo apt-get -s install --no-install-recommends openssl` 先审阅升级及附加依赖计划）。

## 服务端：frps

```bash
sudo bash frp/install.sh --server
sudo bash frp/install.sh --server --port 7000 --remote-port 17000 --tls-name frps.local
# 仅在需要向其他设备公开映射时启用：
sudo bash frp/install.sh --server --remote-port 17000 --public-bind
```

控制端默认监听 IPv4 TCP `7000`，不启用 Dashboard，只允许显式指定的一个映射端口（默认 `17000`）；映射默认监听服务器 `127.0.0.1`，只有客户端成功注册才建立监听。`--public-bind` 才监听所有 IPv4 接口，脚本不自动修改防火墙。控制端只接受 TLS，并生成 64 字符随机 Token。

安装目录 `/srv/net-services/frp/frps/`：`token.txt` 是 root 专用明文凭据（`0600`），`server.crt` 是应通过可信渠道分发的公开证书，**不要分发 `server.key`**。证书有效期一年；到期前由管理员轮换并向客户端更新信任。`--tls-name` 是证书确认名（默认 `frps.local`），不要求和连接 IP/域名相同，但客户端必须使用同一名称。

## 客户端：frpc

先通过可信渠道取得 `server.crt`，并将配对 Token 保存为 root 拥有、权限为 `0600` 的普通文件。不要在命令行、历史记录或仓库里写 Token：

```bash
sudo bash frp/install.sh --client \
  --server-addr frps.example.com --port 7000 \
  --token-file /root/frp-token.txt --tls-ca /root/server.crt --tls-name frps.local \
  --local-addr 127.0.0.1 --local-port 8080 --remote-port 17000 \
  --name app --protocol tcp
```

仅有终端时可以用 `--client` 交互填写必需的地址及凭据路径；非交互部署须传完整参数。支持 TCP、UDP，默认 TCP。使用当前 TOML 格式；客户端验证证书而不只是加密。frpc 通过认证并成功注册映射才算安装成功，外部业务流量需要用户自行测试。

```bash
bash frp/install.sh --help
sudo systemctl status frps.service frpc.service
sudo systemctl restart frps.service
sudo journalctl -u frpc.service -n 80 --no-pager
sudo ss -ltnp 'sport = :7000'
sudo bash frp/uninstall.sh --client --yes
sudo bash frp/uninstall.sh --server --yes
```

两个角色各用独立低权限账号、目录、systemd unit，启用自启和故障重启。只卸载指定角色。启动失败时，检查控制端口、防火墙、Token 是否匹配、证书名/有效期和服务器允许的映射端口。仅映射你有权管理的服务；FRP 的 TLS 保护 `frpc`↔`frps`，不替代应用访问者端的 HTTPS 或身份验证。

官方资料：[配置文件](https://gofrp.org/en/docs/features/common/configure/) · [TLS 配置](https://gofrp.org/en/docs/features/common/network/network-tls/) · [认证](https://gofrp.org/en/docs/features/common/authentication/)。
