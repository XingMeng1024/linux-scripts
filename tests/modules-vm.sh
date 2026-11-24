#!/bin/bash
# 仅限可丢弃、没有 Docker 与自定义 BBR/FQ 的 systemd VM。
set -euo pipefail
cd "$(dirname "$0")/.."
[[ ${1:-} == --disposable-vm && $EUID == 0 && $(< /proc/1/comm) == systemd ]]
cc=net.ipv4.tcp_congestion_control q=net.core.default_qdisc
file=/etc/sysctl.d/99-linux-scripts-bbr.conf
[[ ! -e $file && ! -e /etc/sysctl.d/90-3proxy-socks5-installer.conf ]]
original_cc=$(sysctl -n "$cc")
original_q=$(sysctl -n "$q")
before=$(tc qdisc show)
bash bbr/install.sh
[[ $(sysctl -n "$cc") == bbr && $(sysctl -n "$q") == fq && $(tc qdisc show) == "$before" ]]
bash bbr/install.sh
bash bbr/uninstall.sh --yes
[[ ! -e $file && $(sysctl -n "$cc") == "$original_cc" && $(sysctl -n "$q") == "$original_q" ]]
bash docker/install.sh
[[ -z $(docker image ls -aq) ]]
if bash docker/install.sh; then exit 1; fi
docker volume create linux-scripts-test >/dev/null
bash docker/uninstall.sh --yes
[[ -d /var/lib/docker/volumes/linux-scripts-test && -d /var/lib/containerd ]]
bash docker/uninstall.sh --yes
printf 'BBR 实际设置与恢复、Docker 容器运行及保留卷卸载测试通过。\n'
