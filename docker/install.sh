#!/bin/bash
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive
readonly src=/etc/apt/sources.list.d/linux-scripts-docker.sources key=/etc/apt/keyrings/linux-scripts-docker.asc
readonly state=/var/lib/linux-scripts-docker signer=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
readonly daemon=/etc/docker/daemon.json
readonly -a packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
readonly -a apt_opts=(-o DPkg::Lock::Timeout=15 -o Acquire::Retries=2 -o Acquire::https::Timeout=20
    -o Acquire::http::Timeout=20 -o Acquire::AllowInsecureRepositories=false
    -o Acquire::AllowDowngradeToInsecureRepositories=false -o APT::Get::AllowUnauthenticated=false
    -o Acquire::https::Verify-Peer=true -o Acquire::https::Verify-Host=true)
tmp='' key_stage='' src_stage='' smoke='' smoke_name=''
own_src=0 own_key=0 own_state=0 own_config_dir=0 installing=0 done=0
data_root='' mirror='' pool='' pool_size='' log_rotate=0 config_hash=''
red='' yellow='' green='' reset=''
if [[ -t 2 && ! ${NO_COLOR+x} ]] && colors=$(tput colors 2>/dev/null) &&
   [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
    red=$'\e[31m' yellow=$'\e[33m' green=$'\e[32m' reset=$'\e[0m'
fi
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
warn() { printf '%s警告：%s%s\n' "$yellow" "$*" "$reset" >&2; }
exists() { [[ -e $1 || -L $1 ]]; }
pkg_status() { dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null; }
pkg_present() {
    local status
    status=$(pkg_status "$1") || return 1
    [[ $status != not-installed && -n $status ]]
}
local_docker() { timeout -k 5 35 docker --host unix:///var/run/docker.sock "$@"; }
remove_new() {
    local p plan name
    local -a remove=()
    for p in "${packages[@]}"; do if pkg_present "$p"; then remove+=("$p"); fi; done
    (( ${#remove[@]} )) || return 0
    plan=$(apt-get "${apt_opts[@]}" -s --no-auto-remove remove "${remove[@]}") || return 1
    if grep -Eq '^Inst ' <<< "$plan"; then return 1; fi
    while read -r name; do
        [[ -z $name || " ${remove[*]} " == *" ${name%%:*} "* ]] || return 1
    done < <(awk '/^Remv /{print $2}' <<< "$plan")
    apt-get "${apt_opts[@]}" -y --no-auto-remove remove "${remove[@]}" >"$tmp/rollback.log" 2>&1
}
cleanup() {
    local rc=$? keep=0
    trap - EXIT ERR
    trap '' INT TERM HUP
    set +e
    if [[ -n $smoke ]]; then
        if [[ -n $smoke_name ]] && local_docker container inspect "$smoke_name" >/dev/null 2>&1; then
            local_docker rm -f "$smoke_name" >/dev/null 2>&1
        fi
        local_docker image rm "$smoke" >/dev/null 2>&1 || warn '未能删除本次临时测试镜像。'
    fi
    if (( ! done )); then
        if (( installing )) && ! remove_new; then
            warn "无法安全回滚 Docker 软件包；保留 $state 及软件源，供管理员处理。"
            keep=1
        fi
        if (( ! keep )); then
            if (( own_src )); then rm -f -- "$src" || warn '未能移除本次软件源。'; fi
            if (( own_key )); then rm -f -- "$key" || warn '未能移除本次签名公钥。'; fi
            if (( own_state )); then
                rm -f -- "$state"/sources.sha256
                rmdir -- "$state" || warn '未能清理归属目录。'
            fi
            if (( own_config_dir )); then
                if [[ -n $config_hash && -f $daemon && ! -L $daemon && $(sha256sum -- "$daemon") == "$config_hash" ]]; then
                    rm -- "$daemon" || warn '未能移除本次创建的 daemon.json。'
                fi
                rmdir -- /etc/docker 2>/dev/null || warn '保留非空或无法删除的 /etc/docker。'
            fi
        fi
        if (( installing )); then warn '保留运行时数据目录和共享依赖；请确认归属后人工处理残留。'; fi
    fi
    if [[ -n $key_stage ]]; then rm -f -- "$key_stage" || warn '未能清理公钥临时文件。'; fi
    if [[ -n $src_stage ]]; then rm -f -- "$src_stage" || warn '未能清理软件源临时文件。'; fi
    if [[ -n $tmp ]]; then rm -rf -- "$tmp" || warn '未能清理下载临时文件。'; fi
    exit "$rc"
}
usage() {
    cat <<'EOF'
用法：sudo bash install.sh [选项]
  --data-root PATH        新的 Docker 数据目录；父目录必须存在且安全
  --log-rotate            json-file 日志轮转，每份 10m，最多 3 份
  --registry-mirror URL   用户指定的 HTTPS 镜像服务根地址，不含凭据
  --address-pool CIDR     自定义私网 IPv4 CIDR；必须配合 --pool-size
  --pool-size BITS        从地址池分配的子网前缀长度，最大 30
不接管现有安装；无上述选项时不写 daemon.json。
EOF
}
while (( $# )); do
    case $1 in
        --help) usage; exit 0 ;;
        --log-rotate) log_rotate=1; shift ;;
        --data-root|--registry-mirror|--address-pool|--pool-size)
            [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 缺少参数。"
            case $1 in --data-root) data_root=$2 ;; --registry-mirror) mirror=$2 ;;
                --address-pool) pool=$2 ;; --pool-size) pool_size=$2 ;; esac
            shift 2 ;;
        *) die '未知选项，请使用 --help。' ;;
    esac
done
if [[ -n $data_root ]]; then
    [[ $data_root =~ ^(/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+$ ]] ||
        die '数据目录必须是无空格、无点路径段的绝对路径。'
    case $data_root in
        /var/lib/docker|/var/lib/docker/*|/var/lib/containerd|/var/lib/containerd/*|\
        "$state"|"$state"/*|/srv/net-services|/srv/net-services/*)
            die '数据目录不能占用系统或本工具已有的服务路径。' ;;
        /srv/*|/var/lib/*|/mnt/*|/data/*) ;;
        *) die '数据目录应位于 /srv、/var/lib、/mnt 或 /data 下。' ;;
    esac
fi
if [[ -n $mirror ]]; then
    [[ $mirror =~ ^https://([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\:([1-9][0-9]{0,4}))?/?$ ]] ||
        die '镜像服务地址必须是无凭据、无查询参数的 HTTPS 根地址。'
    mirror_port=${BASH_REMATCH[5]:-443}
    (( mirror_port <= 65535 )) || die '镜像服务端口超出范围。'
fi
if [[ -n $pool || -n $pool_size ]]; then
    [[ $pool =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([1-3]?[0-9])$ ]] ||
        die '地址池必须是合法的 IPv4 CIDR。'
    octets=("${BASH_REMATCH[@]:1:4}") bits=${BASH_REMATCH[5]}
    ipval=0
    for octet in "${octets[@]}"; do
        if [[ $octet != 0 && $octet == 0* ]] || (( 10#$octet > 255 )); then die '地址池的 IPv4 格式无效。'; fi
        ipval=$(( (ipval<<8) + 10#$octet ))
    done
    if [[ ! $pool_size =~ ^[1-9][0-9]?$ ]] ||
       (( bits < 8 || bits > 30 || pool_size < bits || pool_size > 30 ||
           (ipval & ((1<<(32-bits))-1)) != 0 )); then
        die '地址池必须对齐网段，且 --pool-size 必须介于 CIDR 前缀和 30 之间。'
    fi
    if ! (( ipval>>24 == 10 ||
        (bits >= 12 && ipval>>20 == 2753) ||
        (bits >= 16 && ipval>>16 == 49320) )); then die '仅接受 RFC 1918 私网作为地址池。'; fi
fi
trap cleanup EXIT
trap 'die "安装中断，尝试回滚本次创建的资源。"' HUP INT TERM
trap 'die "安装失败（行 $LINENO），没有报告成功。"' ERR
printf '[1/5] 检测系统及已有容器环境。\n'
[[ $(uname -s) == Linux && -r /etc/os-release ]] || die '仅支持 Debian/Ubuntu Linux。'
(( EUID == 0 )) || die '请使用 root 或 sudo。'
# shellcheck disable=SC1091
. /etc/os-release
case ${ID:-}:${VERSION_ID:-} in
    debian:12) suite=bookworm ;; debian:13) suite=trixie ;;
    ubuntu:22.04) suite=jammy ;; ubuntu:24.04) suite=noble ;;
    *) die '仅支持 Debian 12/13、Ubuntu 22.04/24.04。' ;;
esac
for tool in apt-get apt-cache dpkg dpkg-query dpkg-deb awk grep flock install stat ln sha256sum \
    mkdir mktemp rm rmdir chmod timeout getent df systemctl ldd tar; do
    command -v "$tool" >/dev/null || die "缺少基础命令 $tool。"
done
arch=$(dpkg --print-architecture)
case $arch:$(uname -m) in amd64:x86_64|arm64:aarch64) ;; *) die '仅支持原生 AMD64/ARM64。' ;; esac
[[ -d /run/systemd/system && $(< /proc/1/comm) == systemd ]] || die '需要 systemd 为 PID 1。'
printf '检测到 %s %s，内核 %s，架构 %s。\n' "$ID" "$VERSION_ID" "$(uname -r)" "$arch"
exec 9>/run/linux-scripts-docker.lock
flock -n 9 || die '另一个 Docker 安装或卸载正在运行。'
if [[ -S /var/run/docker.sock ]] && command -v docker >/dev/null; then
    if local_docker info --format '{{.Containers}} 个容器（{{.ContainersRunning}} 个运行中），{{.Images}} 个镜像' 2>/dev/null; then
        die '已有 Docker 环境；请使用现有服务，本模块不接管。'
    fi
fi
for p in "${packages[@]}" docker.io docker-compose docker-compose-v2 docker-doc docker-buildx \
    docker-ce-rootless-extras podman-docker containerd runc moby-engine moby-cli; do
    if pkg_present "$p"; then die "检测到软件包或残留配置 $p；不会移除或接管。"; fi
done
for p in docker dockerd containerd runc; do
    if command -v "$p" >/dev/null || [[ -e /usr/local/bin/$p || -L /usr/local/bin/$p ]]; then
        die "检测到已有程序 $p；不会接管。"
    fi
done
for p in docker.service docker.socket containerd.service; do
    [[ $(systemctl show -p LoadState --value "$p") == not-found ]] ||
        die "已有 $p 或覆盖单元；不会接管。"
done
for p in "$src" "$key" "$state" /var/run/docker.sock /run/containerd/containerd.sock \
    /var/lib/docker /var/lib/containerd /etc/docker /etc/containerd; do
    if exists "$p"; then die "已有 Docker 资源或可能含历史数据：$p；不会修改。"; fi
done
if grep -rIEq 'download\.docker\.com/linux' /etc/apt/sources.list.d 2>/dev/null ||
   { [[ -f /etc/apt/sources.list ]] && grep -Eq 'download\.docker\.com/linux' /etc/apt/sources.list; }; then
    die '已有 Docker APT 软件源；请由管理员处理。'
fi
if group_line=$(getent group docker); then
    gid=$(awk -F: '{print $3}' <<< "$group_line")
    users=$(getent passwd)
    if [[ -n ${group_line##*:} ]] || awk -F: -v id="$gid" '$4==id {a=1} END{exit !a}' <<< "$users"; then
        die '已有账号属于 docker 组；拒绝隐式授予 root 等价权限。'
    fi
fi
for dir in /var/lib /var/tmp /var/cache/apt; do
    space=$(df -Pk "$dir" | awk 'END{print $4}')
    if [[ ! $space =~ ^[0-9]+$ ]] || (( space < 1048576 )); then die "$dir 需要至少 1 GiB 可用空间。"; fi
done
if [[ -n $data_root ]]; then
    if exists "$data_root"; then die '自定义数据目录必须是尚未创建的新路径。'; fi
    parent=${data_root%/*}
    for (( ; ${#parent}; )); do
        [[ -d $parent && ! -L $parent ]] || die "数据目录上级 $parent 不存在或为链接。"
        read -r uid mode < <(stat -c '%u %a' "$parent")
        if [[ $uid != 0 ]] || (( (8#$mode & 022) != 0 )); then die "数据目录上级 $parent 权限不安全。"; fi
        parent=${parent%/*}
    done
    data_space=$(df -Pk "${data_root%/*}" | awk 'END{print $4}')
    if [[ ! $data_space =~ ^[0-9]+$ ]] || (( data_space < 1048576 )); then
        die '自定义数据目录所在磁盘需要至少 1 GiB 可用空间。'
    fi
fi
timeout 10 getent ahosts download.docker.com >/dev/null || die '无法解析 Docker 官方仓库。'
tmp=$(mktemp -d /var/tmp/linux-scripts-docker.XXXXXXXX) || die '无法创建临时目录。'
cat > "$tmp/guard" <<'EOF'
#!/bin/bash
set -euo pipefail
while IFS= read -r deb; do
    pkg=$(dpkg-deb -f "$deb" Package)
    arch=$(dpkg-deb -f "$deb" Architecture)
    ver=$(dpkg-deb -f "$deb" Version)
    status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg:$arch" 2>/dev/null) || status=''
    [[ -z $status || $status == not-installed || $status == config-files ]] || exit 1
    grep -Fxq -- "$pkg=$ver" "${0%/*}/plan" || grep -Fxq -- "$pkg:$arch=$ver" "${0%/*}/plan" || exit 1
done
EOF
apt_update() {
    timeout -k 8 240 apt-get "${apt_opts[@]}" -o APT::Update::Error-Mode=any update >"$tmp/apt.log" 2>&1 ||
        die 'APT 索引更新失败；请检查已有源、官方签名、时钟、TLS、网络或 APT 锁。'
}
apt_install() {
    local plan
    local -a versions
    plan=$(apt-get "${apt_opts[@]}" -s --no-install-recommends install "$@" 2>"$tmp/apt.log") ||
        die '无法解析包依赖；请检查软件源与 dpkg 状态。'
    if grep -Eq '^Remv |^Inst [^ ]+ \[' <<< "$plan"; then
        die '依赖需要升级或移除已装包（可能含共享库）；请管理员处理，本脚本未执行此计划。'
    fi
    mapfile -t versions < <(awk '/^Inst /{v=$3; sub(/^\(/,"",v); sub(/\)$/,"",v); print $2 "=" v}' <<< "$plan")
    (( ${#versions[@]} && ${#versions[@]} <= 20 )) || die '新增依赖为空或超过 20 个，请先检查系统。'
    printf '%s\n' "${versions[@]}" >"$tmp/plan"
    apt-get "${apt_opts[@]}" -o "DPkg::Pre-Install-Pkgs::=/bin/bash $tmp/guard" \
        -y --no-install-recommends --no-upgrade --no-remove install "${versions[@]}" \
        >"$tmp/apt.log" 2>&1 || die '安装软件包失败或依赖计划已变化；请检查网络、磁盘及 dpkg 状态。'
}
printf '[2/5] 获取并配置 Docker 官方签名仓库。\n'
deps=()
if ! command -v curl >/dev/null; then deps+=(curl); fi
if [[ $(pkg_status ca-certificates || :) != installed ]]; then deps+=(ca-certificates); fi
if ! command -v gpgv >/dev/null && ! command -v sqv >/dev/null; then deps+=(gpgv); fi
if (( ${#deps[@]} )); then apt_update; apt_install "${deps[@]}"; fi
repo=https://download.docker.com/linux/$ID
curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 8 --max-time 20 --retry 2 --retry-all-errors --retry-max-time 50 --max-filesize 32768 \
    -o "$tmp/key" "$repo/gpg" || die '无法经 HTTPS 获取 Docker 公钥。'
if ! exists /etc/apt/keyrings; then mkdir -m 0755 /etc/apt/keyrings; fi
for p in /etc/apt/keyrings /etc/apt/sources.list.d; do
    [[ -d $p && ! -L $p ]] || die "$p 不是安全目录。"
    read -r owner mode < <(stat -c '%u %a' "$p")
    if [[ $owner != 0 ]] || (( (8#$mode & 022) != 0 )); then die "$p 权限不安全。"; fi
done
key_stage=$(mktemp /etc/apt/keyrings/.linux-scripts.XXXXXXXX)
src_stage=$(mktemp /etc/apt/sources.list.d/.linux-scripts.XXXXXXXX)
install -m 0644 -- "$tmp/key" "$key_stage"
printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: %s %s\n' \
    "$repo" "$suite" "$arch" "$key" "$signer" >"$src_stage"
chmod 0644 "$src_stage"
ln -- "$key_stage" "$key" || die '密钥路径已被占用。'
own_key=1
ln -- "$src_stage" "$src" || die '软件源路径已被占用。'
own_src=1
rm -- "$key_stage" "$src_stage"
key_stage='' src_stage=''
mkdir -m 0700 -- "$state"
own_state=1
sha256sum "$src" "$key" >"$state/sources.sha256"
apt_update

printf '[3/5] 安装官方 stable 软件包。\n'
requested=()
for p in "${packages[@]}"; do
    version=$(apt-cache madison "$p" | awk -F'|' -v repo="$repo" -v suite="$suite" \
        '$3 ~ repo" "suite"/stable " {gsub(/[[:space:]]/,"",$2); if (!seen++) print $2}')
    [[ -n $version ]] || die "官方 stable 未找到 $p ($arch/$suite)。"
    requested+=("$p=$version")
done
settings=()
if [[ -n $data_root ]]; then settings+=("\"data-root\":\"$data_root\""); fi
if (( log_rotate )); then settings+=('"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}'); fi
if [[ -n $mirror ]]; then settings+=("\"registry-mirrors\":[\"$mirror\"]"); fi
if [[ -n $pool ]]; then settings+=("\"default-address-pools\":[{\"base\":\"$pool\",\"size\":$pool_size}]"); fi
if (( ${#settings[@]} )); then
    mkdir -m 0755 /etc/docker || die '/etc/docker 已存在，不写入配置。'
    own_config_dir=1
    (set -o noclobber; IFS=,; printf '{%s}\n' "${settings[*]}" >"$daemon") || die '无法安全创建 daemon.json。'
    config_hash=$(sha256sum -- "$daemon")
fi
installing=1
apt_install "${requested[@]}"
printf '[4/5] 验证守护进程及插件。\n'
if (( own_config_dir )); then
    dockerd --validate --config-file "$daemon" >"$tmp/config.log" 2>&1 || die 'Docker 拒绝自定义 daemon.json。'
fi
systemctl enable --now containerd.service docker.service >"$tmp/systemd.log" 2>&1 ||
    die 'Docker/containerd 启动或自启失败，请查阅 systemd 日志。'
for p in containerd.service docker.service; do
    if ! systemctl is-active --quiet "$p" || ! systemctl is-enabled --quiet "$p"; then die "$p 未正常运行或未自启。"; fi
done
local_docker version --format 'Docker Engine {{.Server.Version}}' || die '无法连接本地 Docker 守护进程。'
if [[ -n $data_root && $(local_docker info --format '{{.DockerRootDir}}') != "$data_root" ]]; then
    die 'Docker 未使用指定数据目录。'
fi
local_docker compose version || die 'Docker Compose 插件不可用。'
local_docker buildx version || die 'Docker Buildx 插件不可用。'
printf '[5/5] 运行隔离的最小测试容器（不下载镜像）。\n'
mkdir -m 0755 "$tmp/rootfs"
install -m 0755 -- /bin/true "$tmp/rootfs/probe"
libs=$(ldd /bin/true) || die '无法检查本机探针的动态库。'
mapfile -t lib_paths < <(awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) {print $i; break}}' <<< "$libs")
(( ${#lib_paths[@]} )) || die '未找到探针需要的系统动态库。'
for lib in "${lib_paths[@]}"; do install -D -m 0755 -- "$lib" "$tmp/rootfs$lib"; done
tar -C "$tmp/rootfs" -cf "$tmp/probe.tar" .
smoke=$(local_docker import "$tmp/probe.tar" 2>"$tmp/container.log") || die '无法导入本地测试镜像。'
[[ $smoke =~ ^sha256:[0-9a-f]{64}$ ]] || die 'Docker 未返回有效的测试镜像 ID。'
smoke_name="linux-scripts-probe-${tmp##*.}"
local_docker run --name "$smoke_name" --pull=never --rm --network none --read-only \
    --cap-drop ALL --security-opt no-new-privileges "$smoke" /probe >"$tmp/container.log" 2>&1 ||
    die '本机测试容器运行失败；请检查 cgroup、磁盘和内核。'
local_docker image rm "$smoke" >/dev/null || die '测试容器成功，但未能清理测试镜像。'
smoke=''
done=1
if [[ ! -t 1 ]]; then green='' reset=''; fi
printf '%sDocker Engine 与 Compose 已安装并通过容器测试。%s\n' "$green" "$reset"
warn 'Docker 发布端口可能绕过部分防火墙规则；发布业务前请阅读 README。'
