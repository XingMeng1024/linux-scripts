# Linux Scripts

面向个人云服务器和低配置 VPS 的独立 Bash 运维工具。四个模块可单独下载、安装和卸载，不依赖仓库里的其他脚本，不需要 Web 面板或额外开发环境。

原项目根目录的 SOCKS5 脚本已迁至 `socks5/`。这不会迁移或覆盖服务器上的现有安装。

| 模块 | 用途 | 官方来源 |
| --- | --- | --- |
| [SOCKS5](socks5/README.md) | 3proxy LTS，口令认证、可选来源限制 | [3proxy 签名 APT](https://3proxy.org/repo/) |
| [BBR](bbr/README.md) | 启用内核 BBR 和默认 FQ，保留网卡根队列 | [Linux 内核文档](https://docs.kernel.org/admin-guide/sysctl/net.html) |
| [Docker](docker/README.md) | Docker Engine、containerd、Buildx、Compose | [Docker Engine 官方签名源](https://docs.docker.com/engine/install/) |
| [FRP](frp/README.md) | 独立部署服务端或客户端，验证 TLS 服务器身份 | [FRP GitHub Releases](https://github.com/fatedier/frp/releases) |

脚本识别 **Debian 12/13、Ubuntu 22.04/24.04、原生 AMD64/ARM64**。要求 root 或 sudo、systemd 为 PID 1。已完成的实测和未覆盖场景请看[测试记录](tests/RESULTS.md)；识别某个系统不等于已在其全部组合上验证。Docker 应给实际镜像和业务留出额外内存和磁盘，512 MB 主机不适合大镜像或多服务并行。

## 一键部署

已下载项目时，从仓库根目录择一运行：

```bash
sudo bash socks5/install.sh
sudo bash bbr/install.sh
sudo bash docker/install.sh
sudo bash frp/install.sh --server
sudo bash frp/install.sh --client  # 交互要求服务端地址、Token 文件和可信证书
```

项目已托管在 [XingMeng1024/linux-scripts](https://github.com/XingMeng1024/linux-scripts)，默认分支为 `main`。优先将单模块脚本下载到私有临时目录，检查后再以 root 执行：

```bash
module=socks5   # 可替换为 bbr、docker、frp；FRP 执行时须选择角色
base=https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main
work=$(mktemp -d)
curl -fSL "$base/$module/install.sh" -o "$work/install.sh"
less "$work/install.sh"
sudo bash "$work/install.sh"
```

已审阅脚本、确认来源后，也支持管道安装（非交互场景预先配置 sudo，别从脚本输入流读取密码）：

```bash
BASE=https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main
curl -fsSL "$BASE/socks5/install.sh" | sudo bash
curl -fsSL "$BASE/bbr/install.sh" | sudo bash
curl -fsSL "$BASE/docker/install.sh" | sudo bash
curl -fsSL "$BASE/frp/install.sh" | sudo bash -s -- --server
curl -fsSL "$BASE/frp/install.sh" | sudo bash -s -- --client
```

FRP 客户端无终端时，按[模块说明](frp/README.md#客户端frpc)传完整参数。当前尚未发布 Release，请使用上面的 `main` 命令。发布固定版本后，可将 Raw URL 的 `main` 换成实际标签，也可以下载 Release 中的单个脚本并用 `SHA256SUMS` 验证（以下以 `v1.0.0` 为例）：

```bash
work=$(mktemp -d)
cd "$work"
release=https://github.com/XingMeng1024/linux-scripts/releases/download/v1.0.0
curl -fSLO "$release/socks5-install.sh" &&
  curl -fSLO "$release/SHA256SUMS" &&
  awk '$2=="socks5-install.sh"' SHA256SUMS | sha256sum -c - &&
  sudo bash ./socks5-install.sh
```

同一共享目录中不建议用固定 `/tmp/install.sh`。校验值不是仓库所有者身份的替代；不要运行未经检查的 root 脚本。

## 管理与卸载

```bash
sudo systemctl status socks5.service docker.service frps.service
sudo journalctl -u socks5.service -n 50 --no-pager
sudo docker compose version
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
tc qdisc show

sudo bash socks5/uninstall.sh --yes
sudo bash bbr/uninstall.sh --yes
sudo bash docker/uninstall.sh --yes
sudo bash frp/uninstall.sh --client --yes
sudo bash frp/uninstall.sh --server --yes
```

远程卸载同样可单独下载 `"$BASE/$module/uninstall.sh"` 后执行。`--yes` 表示已确认，FRP 还须指定角色。Docker 默认不删除数据或中断运行中的容器；BBR 只在没有冲突时恢复原值。更多参数、常见问题和配置路径见各子目录。

**安全提醒：** SOCKS5 口令没有传输加密；限制来源 IP 并收紧云防火墙。Docker daemon 会管理容器网络，发布端口可能绕过部分防火墙规则。FRP TLS 不是外部用户访问业务的 HTTPS；只转发自己获授权管理的服务，妥善保管 Token、私钥及任何代理连接文件。脚本不自动开放防火墙，不关闭 AppArmor/SELinux。SIGKILL、断电或宿主机异常可能留下部分文件；先核对归属再处理，不要盲目删除。

## 测试

GitHub Actions 执行 Bash 语法、ShellCheck、UTF-8/LF、文件结构、参数和保护分支检查：

```bash
bash tests/local.sh
shellcheck */install.sh */uninstall.sh tests/*.sh
```

真实测试使用可丢弃的 Debian 12 systemd VM，而非普通容器。各验收脚本会修改 VM；推荐将 `modules-vm.sh` 放在独立新 VM，或在启用 SOCKS5 可选调优前运行：

```bash
sudo bash tests/modules-vm.sh --disposable-vm
sudo bash tests/frp-vm.sh --disposable-vm
sudo bash tests/socks5-vm.sh --disposable-vm --real-bbr
sudo systemctl reboot
# 重新连接 VM 后
sudo bash tests/socks5-vm.sh --disposable-vm --after-reboot
```

## GitHub 维护与发布

尚无本地 Git 副本时，先克隆已有仓库，不要重新初始化或创建同名仓库：

```bash
git clone https://github.com/XingMeng1024/linux-scripts.git
cd linux-scripts
```

将更新放入克隆目录后，检查并提交：

```bash
git status --short
git add .
git diff --cached --stat
git diff --cached
git commit -m "更新 Linux Scripts"
git push origin main
```

提交前确认没有密码、Token、实际配置、SSH 密钥及第三方二进制。创建 Release 需要仓库发布权限；先通过 `gh auth login` 登录 GitHub CLI，再从固定标签构建脚本和校验清单：

```bash
tag=v1.0.0
git tag -a "$tag" -m "Release $tag"
git push origin "$tag"
out=$(mktemp -d)
for module in socks5 bbr docker frp; do
  for action in install uninstall; do
    git show "$tag:$module/$action.sh" >"$out/$module-$action.sh"
  done
done
(cd "$out" && sha256sum -- *.sh > SHA256SUMS)
gh release create "$tag" "$out"/*.sh "$out/SHA256SUMS" --verify-tag --generate-notes
```

脚本采用 [MIT](LICENSE) 许可证。Docker、3proxy 和 FRP 二进制遵循各自原许可，本仓库不打包或分发第三方程序。
