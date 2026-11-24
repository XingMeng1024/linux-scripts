# Docker

从 Docker 官方签名源安装 Engine、containerd、Buildx 和 Compose。安装至少需要 1 GiB 可用空间，镜像和业务另计。

## 一键安装

适用系统和下载提示见[项目首页](../README.md)。

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/docker/install.sh -o "$f" &&
  if [ "$(id -u)" -eq 0 ]; then bash "$f"; else sudo bash "$f"; fi)
```

已有 Docker 或历史数据时不接管。默认不写 `daemon.json`、不添加用户到 `docker` 组。自定义数据目录、日志轮转、镜像源和地址池参数见 `bash docker/install.sh --help`。

## 查看状态

```bash
sudo docker compose version
sudo docker ps -a
sudo journalctl -u docker.service -n 50 --no-pager
```

发布容器端口前，先阅读 [Docker 防火墙说明](https://docs.docker.com/engine/network/packet-filtering-firewalls/)。

## 一键卸载

```bash
(f=$(mktemp) && trap 'rm -f "$f"' EXIT &&
  curl -fsSL https://raw.githubusercontent.com/XingMeng1024/linux-scripts/main/docker/uninstall.sh -o "$f" &&
  if [ "$(id -u)" -eq 0 ]; then bash "$f"; else sudo bash "$f"; fi)
```

按提示确认；无终端时可加 `--yes`。默认保留数据，有运行中的容器时会拒绝卸载。`--purge-data` 会不可逆地删除符合条件的默认数据，且必须在终端确认；不会自动删除自定义数据目录。
