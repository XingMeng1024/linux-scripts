# Linux Scripts

四个独立的 Linux 运维脚本，无需克隆仓库。适用于 Debian 12/13、Ubuntu 22.04/24.04（AMD64/ARM64），需要 systemd 和 root 或 sudo。实测范围见[测试记录](tests/RESULTS.md)。

## 一键安装

不用 `git clone`。在 Linux 服务器上按需复制一条命令，直接从 GitHub 下载并运行。命令需要 `curl`；已是 root 且没有 `sudo` 时，去掉 `sudo`。

[SOCKS5](socks5/README.md)：安装带密码认证的 3proxy。

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/socks5/install.sh -o "$f" &&
  sudo bash "$f")
```

[BBR](bbr/README.md)：启用内核 BBR 和默认 FQ。

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/bbr/install.sh -o "$f" &&
  sudo bash "$f")
```

[Docker](docker/README.md)：安装官方 Docker Engine、Buildx 和 Compose。

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/docker/install.sh -o "$f" &&
  sudo bash "$f")
```

[FRP 服务端](frp/README.md#一键安装)：

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/frp/install.sh -o "$f" &&
  sudo bash "$f" --server)
```

[FRP 客户端](frp/README.md#一键安装)（需终端、服务端地址、Token 文件及证书）：

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/frp/install.sh -o "$f" &&
  sudo bash "$f" --client)
```

命令会先完整下载再执行。`main` 会更新，建议先检查脚本内容；需要固定版本时，可将 URL 中的 `main` 换成已审阅的提交 SHA。

## 一键卸载

无需克隆仓库。在安装过对应模块的服务器上择一运行，按提示输入 `yes` 确认。无终端时，确认无误后可在 `sudo bash "$f"` 的参数末尾加 `--yes`。

**SOCKS5**

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/socks5/uninstall.sh -o "$f" &&
  sudo bash "$f")
```

**BBR**

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/bbr/uninstall.sh -o "$f" &&
  sudo bash "$f")
```

**Docker**（默认保留数据，有运行中的容器时拒绝卸载）

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/docker/uninstall.sh -o "$f" &&
  sudo bash "$f")
```

**FRP 服务端**

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/frp/uninstall.sh -o "$f" &&
  sudo bash "$f" --server)
```

**FRP 客户端**

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/frp/uninstall.sh -o "$f" &&
  sudo bash "$f" --client)
```

## 本地运行

已下载仓库时，在根目录运行 `sudo bash <模块>/install.sh` 或 `sudo bash <模块>/uninstall.sh`，将 `<模块>` 换成 `socks5`、`bbr`、`docker` 或 `frp`。FRP 安装和卸载都要加 `--server` 或 `--client`。使用 `--help` 查看参数。

SOCKS5 不加密，请限制来源 IP；Docker 发布端口可能绕过部分防火墙规则；FRP 的 TLS 不替代业务 HTTPS。脚本不会自动开放防火墙端口。

## 测试与许可

```bash
bash tests/local.sh
shellcheck */install.sh */uninstall.sh tests/*.sh
```

[虚拟机验收](tests/RESULTS.md) · [变更日志](CHANGELOG.md) · [MIT 许可证](LICENSE)
