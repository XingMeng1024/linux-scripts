# FRP

分别安装 `frps` 服务端和 `frpc` 客户端。脚本校验 [FRP 官方发布包](https://github.com/fatedier/frp/releases)，客户端验证服务端 TLS 证书。适用系统见[项目首页](../README.md)。

## 一键安装

在服务端运行：

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/frp/install.sh -o "$f" &&
  sudo bash "$f" --server)
```

控制端口默认 `7000`，映射端口默认 `17000`，映射只监听服务端的 `127.0.0.1`。确需对外开放时才加 `--public-bind`，并自行配置防火墙。

在客户端运行（需交互终端）：

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/frp/install.sh -o "$f" &&
  sudo bash "$f" --client)
```

先从服务端 `/srv/net-services/frp/frps/` 安全取得 `server.crt` 和 `token.txt`，**不要复制 `server.key`**。客户端 Token 文件须归 root 所有，建议权限 `0600`。默认 TLS 名称为 `frps.local`；证书有效期一年，到期前需轮换。

无终端时显式传入地址和凭据路径。例如，在仓库根目录为本地 `8080` 端口配置映射：

```bash
sudo bash frp/install.sh --client \
  --server-addr frps.example.com --token-file /root/frp-token.txt \
  --tls-ca /root/server.crt --tls-name frps.local \
  --local-port 8080 --remote-port 17000
```

## 查看状态

```bash
sudo systemctl status frps.service  # 客户端改为 frpc.service
```

仅映射你有权管理的服务；FRP 的 TLS 不替代业务 HTTPS。

## 一键卸载

在对应服务器上按角色择一运行，按提示确认；无终端时可加 `--yes`。

服务端：

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/frp/uninstall.sh -o "$f" &&
  sudo bash "$f" --server)
```

客户端：

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/frp/uninstall.sh -o "$f" &&
  sudo bash "$f" --client)
```
