# 验证记录

日期：2026-11-24。静态检查使用 macOS ARM64 上的 Bash、ShellCheck 0.11.0；运行测试使用独立的 Debian 12.15 ARM64 官方 genericcloud 虚拟机（Lima / Apple Virtualization，systemd 252，内核 `6.1.0-54-cloud-arm64`，1–2 GiB 内存，10 GiB 虚拟磁盘）。不是用普通容器替代 systemd。

| 范围 | 实测 |
| --- | --- |
| 静态检查 | 所有安装/卸载脚本及测试脚本通过 Bash 语法和 ShellCheck。检查必要文件、执行位、UTF-8/LF、普通及 stdin 执行帮助、无 root 或不支持系统、参数注入、变量边界。 |
| 官方包 | 核对四个发行版对应 Docker 官方 `stable` 索引和 AMD64/ARM64 架构。分别检查了 AMD64 3proxy LTS deb、FRP Linux 归档的 SHA256 与 ELF；ARM64 通过安装时的签名/校验值、类型和架构检查。 |
| SOCKS5 | `0.9.9.4` LTS 安装、端口归属、转发和鉴权测试；拒绝未认证、错误密码、私网、IPv6（含映射 IPv4）、UDP 与 BIND，拒绝来源白名单外的 IPv4。检查启用访问日志后有记录且不含密码。验证无效 APT 公钥、官方 HTTPS 不可达注入、重复执行、端口/锁冲突、安装失败回滚。实际重启后自启、再次转发和卸载。 |
| BBR | 在内核上实际从 `cubic/fq_codel` 启用 `bbr/fq`，重复安装不改，卸载恢复原值；确认 `tc qdisc` 输出未被修改，验证后置配置冲突时拒绝写入。SOCKS5 可选调优另外验证了重启后的持久化、无 BBR 的模拟降级。 |
| Docker | Engine `29.10.0`、Compose `v5.8.0`、Buildx `v0.39.1`。真实运行临时无网络容器并清理，拒绝重复接管，卸载后保留卷及 containerd 数据。验证自定义数据目录、日志驱动、镜像设置、地址池分配及卸载保留配置；拒绝自动销毁自定义目录。Docker Hub 在此环境连接超时，因此运行自检不依赖 registry。 |
| FRP | `0.72.0` 从官方归档独立安装两角色；错误 Token、错误证书名及未授权端口分别被拒绝并回滚。使用已认证通道完成实际 HTTP 转发；客户端卸载不停止服务端，再独立卸载服务端。 |

## 未覆盖

- Debian 12 AMD64、Debian 13、Ubuntu 22.04/24.04 未完成端到端验收；包与发行版支持信息不等同于实测。
- 未测试公网入站、真实 Telegram 客户端、跨机 FRP/UDP 业务流量、Docker 镜像加速服务可达性、512 MiB 性能、长时间负载、异常断电或所有安全策略组合。没有实际删除 Docker 数据的测试；只验证默认保留与自定义目录删除拒绝。
- 项目已发布到 [GitHub 仓库](https://github.com/XingMeng1024/linux-scripts)。本次核对时尚无 Release，也未看到 GitHub Actions 运行记录。复测及发布命令见[根目录 README](../README.md)。
