# 测试记录

2026-11-24：静态检查在 macOS ARM64 完成；运行验收使用 Debian 12.15 ARM64、systemd 252 虚拟机。

| 模块 | 已验证 |
| --- | --- |
| 静态检查 | Bash 语法、ShellCheck、编码、参数校验和 stdin 执行 |
| SOCKS5 | 安装、认证、来源限制、日志、失败回滚、重启自启和卸载 |
| BBR | 启用及恢复 BBR/FQ、不替换网卡队列、拒绝冲突配置 |
| Docker | 实际运行无网络容器、配置选项、卸载保留数据；Docker Hub 连接超时 |
| FRP | 两角色安装、认证和证书校验、HTTP 转发、按角色卸载 |

未完成 Debian 12 AMD64、Debian 13 和 Ubuntu 22.04/24.04 的端到端验收。也未测试公网入站、跨机 FRP、UDP 业务、512 MiB 性能或实际删除 Docker 数据。

## 复测

在仓库根目录运行：

```bash
bash tests/local.sh
```

下列命令会修改系统，只在可丢弃的 Debian 12 systemd 虚拟机上运行：

```bash
sudo bash tests/modules-vm.sh --disposable-vm
sudo bash tests/frp-vm.sh --disposable-vm
sudo bash tests/socks5-vm.sh --disposable-vm --real-bbr
sudo systemctl reboot
# 重连虚拟机后：
sudo bash tests/socks5-vm.sh --disposable-vm --after-reboot
```
