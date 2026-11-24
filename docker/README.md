# Docker：官方 Engine 和 Compose

在 Debian 12/13、Ubuntu 22.04/24.04 的原生 AMD64/ARM64 安装 Docker stable：`docker-ce`、`docker-ce-cli`、`containerd.io`、`docker-buildx-plugin` 和 `docker-compose-plugin`。不安装旧版 `docker-compose`、不添加普通用户到 `docker` 组；默认不写 `daemon.json`。预留至少 1 GiB 可用空间给安装操作；镜像与实际业务另需空间和内存。

```bash
sudo bash docker/install.sh
bash docker/install.sh --help
sudo docker compose version
sudo docker info
sudo docker ps -a
sudo systemctl status docker.service containerd.service
sudo journalctl -u docker.service -n 80 --no-pager
sudo docker compose -f compose.yaml up -d   # 在自己已审阅的应用目录操作
```

可选配置仅在全新安装时明确传入（示例镜像域名须替换为自己的可信镜像源）：

```bash
sudo bash docker/install.sh --data-root /srv/docker-data --log-rotate \
  --registry-mirror https://mirror.example.com --address-pool 10.66.0.0/16 --pool-size 24
```

`--data-root` 接受 `/srv`、`/var/lib`、`/mnt` 或 `/data` 下尚不存在的路径，所有上级目录必须安全且已存在；不会移动 containerd 自己的数据目录。`--log-rotate` 将 `json-file` 日志限制为每份 10m、最多 3 份；`--address-pool` 配合 `--pool-size` 接受对齐的 RFC 1918 网段，使用前请确认不与现有路由相交。未指定选项时不创建配置；退出或卸载不会主动删除业务数据。

通过 Docker 官方 HTTPS 软件源和固定签名主密钥指纹 `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` 验证包。项目专属 APT 源与公钥保留以便常规维护，写入 `/etc/apt/sources.list.d/linux-scripts-docker.sources`、`/etc/apt/keyrings/linux-scripts-docker.asc`；归属记录位于 `/var/lib/linux-scripts-docker/`。

遇到现有 Docker/兼容包、服务、自定义配置或历史数据目录即停止，不自动删除。只有缺少 `curl`、CA、APT 验签工具或必要软件包时才补齐；若需升级已有库或删除其他软件包则退出。真实运行测试从本机已装的 `/bin/true` 和所需系统库构造临时镜像，在无网络、只读容器中执行并清理。**这个测试不验证 Docker Hub 连通性或生产应用。**

Docker daemon 本身会管理容器网络和防火墙规则；已发布的容器端口可能绕过某些 UFW/firewalld 规则。启用端口前请阅读[官方防火墙说明](https://docs.docker.com/engine/network/packet-filtering-firewalls/)，优先绑定明确的地址。Docker socket 与 `docker` 组权限近似 root。

## 卸载与数据保护

```bash
sudo bash docker/uninstall.sh
sudo bash docker/uninstall.sh --yes
```

卸载前清点运行/未运行容器、镜像、卷和网络。若守护进程停止而尚有安装，需先启动以完成清点；有运行中的容器时默认拒绝。只有明确接受中断，才使用 `--yes --allow-running`。默认保留 `/var/lib/docker`、`/var/lib/containerd`、自定义数据、用户配置和共享依赖。不卸载非本模块安装的 Docker，不执行 `autoremove`。

`--purge-data` 是不可逆选项：必须在终端输入 `DELETE-DEFAULT-DOCKER-DATA`，无终端不执行；只考虑两个标准数据目录，拒绝运行中的容器、自定义根目录、非 Docker 的 containerd 命名空间、覆盖单元或目录内挂载。自定义数据不提供自动删除，须由管理员备份并核对归属。

官方资料：[Debian 安装](https://docs.docker.com/engine/install/debian/) · [Ubuntu 安装](https://docs.docker.com/engine/install/ubuntu/) · [Compose 文档](https://docs.docker.com/compose/)。
