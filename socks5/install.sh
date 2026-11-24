#!/bin/bash
# 3proxy SOCKS5 全新安装；此文件可独立下载运行。
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset CDPATH

readonly BASE=/srv/net-services DIR=/srv/net-services/socks5 ACCOUNT=svc-3proxy-socks
readonly UNIT=/etc/systemd/system/socks5.service SERVICE=socks5.service
readonly LOCK=/run/3proxy-socks5-installer.lock OWNER=3proxy-socks5-installer/v1
readonly SYSCTL=/etc/sysctl.d/90-3proxy-socks5-installer.conf
readonly REPO=https://3proxy.org/repo PROXY_VERSION=0.9.9.4 DEB_VERSION=0.9.9.4-261121091843
readonly SIGNER=FC12214499FCC7BA1CFF6CDC0312384E3A73940B
readonly -a TEST_URLS=(https://www.debian.org/ https://www.iana.org/)
PORT=21080 USERNAME=tgproxy PUBLIC='' BBR=1 ACCESS_LOG=0 SOURCES=''
tmp='' unit_stage='' dir_created=0 base_created=0 srv_created=0 user_created=0
unit_created=0 enable_attempted=0 committed=0
red='' yellow='' green='' reset='' phase=参数检查
if [[ -t 2 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]] &&
   colors=$(tput colors 2>/dev/null) && [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
    red=$'\e[31m' yellow=$'\e[33m' green=$'\e[32m' reset=$'\e[0m'
fi
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
warn() { printf '%s警告：%s%s\n' "$yellow" "$*" "$reset" >&2; }
step() { phase=$2; printf '[%s/10] %s...\n' "$1" "$2" >&2; }
usage() {
    cat <<'EOF'
用法：sudo bash install.sh [选项]
  --port PORT        IPv4 监听端口，1024-65535，默认 21080
  --username NAME    账号：1-32 个 ASCII 字母、数字、下划线或连字符
  --public-ip HOST   客户端入站 IPv4 地址或 DNS 域名（仅用于连接信息）
  --allow-source IP[/BITS]
                     限制客户端来源 IPv4/CIDR（可重复；保留本机自检）
  --enable-log       将访问元数据写入 journal（默认关闭）
  --no-bbr           不修改 BBR 和默认队列算法
  --help             显示帮助
EOF
}

lexists() { [[ -e $1 || -L $1 ]]; }
ipv4() {
    local octet
    [[ $1 =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
    local -a parts
    IFS=. read -r -a parts <<< "$1"
    for octet in "${parts[@]}"; do (( octet <= 255 )) || return 1; done
}
public_address() {
    local label
    local -a labels
    ipv4 "$1" && return 0
    [[ ${#1} -le 253 && $1 =~ ^[A-Za-z0-9.-]+$ && $1 == *.* &&
       $1 != .* && $1 != *. && $1 != *..* &&
       ${1##*.} =~ [a-zA-Z] ]] || return 1
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    done
}
parse_args() {
    while (( $# )); do
        case $1 in
            --help) usage; exit 0 ;;
            --no-bbr) BBR=0; shift ;;
            --enable-log) ACCESS_LOG=1; shift ;;
            --port|--username|--public-ip|--allow-source)
                [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 缺少参数。"
                case $1 in
                    --port) PORT=$2 ;;
                    --username) USERNAME=$2 ;;
                    --public-ip) PUBLIC=$2 ;;
                    --allow-source)
                        ipv4 "${2%%/*}" || die '来源必须是 IPv4 或 IPv4 CIDR。'
                        if [[ $2 == */* && ! ${2#*/} =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]; then
                            die '来源 CIDR 前缀必须是 1-32。'
                        fi
                        (( ${#SOURCES} < 600 )) || die '来源规则过多。'
                        SOURCES="${SOURCES:+$SOURCES,}$2"
                        ;;
                esac
                shift 2 ;;
            *) die '未知选项，请使用 --help。' ;;
        esac
    done
    if [[ ! $PORT =~ ^[1-9][0-9]{3,4}$ ]] || (( PORT < 1024 || PORT > 65535 )); then
        die '端口必须为 1024-65535 的十进制整数。'
    fi
    [[ $USERNAME =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]{0,31}$ ]] || die '用户名格式不正确。'
    [[ -z $PUBLIC ]] || public_address "$PUBLIC" || die '入站地址必须是 IPv4 或合法 DNS 域名。'
}

cleanup() {
    local rc=$? keep=0
    trap - EXIT ERR
    trap '' INT TERM HUP
    set +e
    if (( ! committed )); then
        if (( unit_created )); then
            if (( enable_attempted )) && ! systemctl disable "$SERVICE" >/dev/null 2>&1; then
                warn '回滚开机自启失败；保留项目文件以便人工处理。'
                keep=1
            fi
            if ! systemctl stop "$SERVICE" >/dev/null 2>&1; then
                # 在 daemon-reload 之前失败时，服务可能从未被加载。
                if [[ $(systemctl show -p LoadState --value "$SERVICE" 2>/dev/null) != not-found ]]; then
                    warn '回滚时无法确认服务已停止；保留项目文件以便人工处理。'
                    keep=1
                fi
            fi
            if (( ! keep )); then
                systemctl reset-failed "$SERVICE" >/dev/null 2>&1
                if ! rm -f -- "$UNIT"; then
                    warn '未能删除项目服务文件。'
                    keep=1
                fi
                systemctl daemon-reload || warn '回滚后重新加载 systemd 失败。'
            fi
        fi
        if (( ! keep )); then
            if (( dir_created )); then
                if ! rm -f -- "$DIR"/{3proxy,3proxy.cfg,connection.txt,.installer-owner} ||
                   ! rmdir -- "$DIR"; then warn "未能清理 $DIR；请检查非项目文件。"; fi
            fi
            if (( user_created )); then
                userdel "$ACCOUNT" || warn "未能删除本次创建的账号 $ACCOUNT。"
                if grep -q "^$ACCOUNT:" /etc/group; then
                    groupdel "$ACCOUNT" || warn "未能删除本次创建的组 $ACCOUNT。"
                fi
            fi
            if (( base_created )); then rmdir -- "$BASE" || warn "$BASE 非空或无法删除。"; fi
            if (( srv_created )); then rmdir -- /srv || warn '/srv 非空或无法删除。'; fi
        fi
    fi
    if [[ -n $unit_stage ]]; then rm -f -- "$unit_stage" || warn '未能清理服务临时文件。'; fi
    if [[ -n $tmp ]]; then rm -rf -- "$tmp" || warn '未能清理下载临时目录。'; fi
    exit "$rc"
}

safe_parent() {
    local owner mode
    [[ -d $1 && ! -L $1 ]] || die "$1 不是普通目录，拒绝修改。"
    read -r owner mode < <(stat -c '%u %a' -- "$1")
    if [[ $owner != 0 ]] || (( (8#$mode & 022) != 0 )); then
        die "$1 必须由 root 拥有且其他用户不可写；未修改原有权限。"
    fi
    if [[ $1 == /srv || $1 == "$BASE" ]]; then
        (( (8#$mode & 001) != 0 )) ||
            die "$1 未开放遍历；请管理员为新运行用户规划遍历权限。"
    fi
}
check_mount() {
    local opts space inodes
    opts=$(findmnt -n -o OPTIONS -T "$1") || die "无法检查 $1 的挂载状态。"
    [[ ,$opts, == *,rw,* ]] || die "$1 位于只读文件系统。"
    if [[ $2 == exec ]]; then [[ ,$opts, != *,noexec,* ]] || die "$1 所在文件系统禁止执行。"; fi
    space=$(df -Pk -- "$1" | awk 'END {print $4}')
    inodes=$(df -Pi -- "$1" | awk 'END {print $4}')
    if [[ ! $space =~ ^[0-9]+$ || ! $inodes =~ ^[0-9]+$ ]] ||
       (( space < 65536 || inodes < 512 )); then
        die "$1 可用空间或 inode 不足（至少 64 MiB、512 inode）。"
    fi
}
check_conflicts() {
    local state name socket_state target proc
    lexists "$DIR" && die "$DIR 已存在；不会覆盖。"
    for target in /etc/systemd/system /run/systemd/system /usr/lib/systemd/system /lib/systemd/system; do
        for name in "$target/$SERVICE" "$target/$SERVICE.d"; do
            lexists "$name" && die "发现同名服务或覆盖配置：$name。"
        done
    done
    state=$(systemctl show -p LoadState --value "$SERVICE") || die '无法检查 systemd 单元。'
    [[ $state == not-found ]] || die "同名服务已存在（$state）；不会覆盖。"
    for name in passwd group; do
        if getent "$name" "$ACCOUNT" >/dev/null; then die "运行账号或同名组 $ACCOUNT 已存在。"
        else [[ $? == 2 ]] || die '无法查询系统账号。'; fi
    done
    printf -v target ':%04X' "$PORT"
    for proc in /proc/net/tcp /proc/net/tcp6; do
        [[ -r $proc ]] || continue
        while read -r _ name _ socket_state _; do
            if [[ $name == *"$target" && $socket_state == 0A ]]; then die "TCP 端口 $PORT 已被占用。"; fi
        done < "$proc"
    done
}
preflight() {
    local tool nearest route iface dest flags now
    [[ $(uname -s) == Linux && -r /etc/os-release ]] || die '只支持 Debian/Ubuntu Linux。'
    (( EUID == 0 )) || die '请使用 root 或 sudo 执行。'
    # shellcheck disable=SC1091
    . /etc/os-release
    case ${ID:-}:${VERSION_ID:-} in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
        *) die '只支持 Debian 12/13、Ubuntu 22.04/24.04；不会编译源码。' ;;
    esac
    for tool in apt-get dpkg dpkg-deb dpkg-query awk grep stat mkdir rmdir rm install mktemp \
        findmnt df flock sha256sum od timeout date getent runuser useradd userdel groupdel \
        systemctl systemd-analyze ldd env ln cat chmod chown id sleep; do
        command -v "$tool" >/dev/null || die "缺少基础系统命令 $tool，请先修复系统。"
    done
    ARCH=$(dpkg --print-architecture)
    case $ARCH:$(uname -m) in
        amd64:x86_64) pkg_hash=3263cf86b6200183062d4d7c7f672032d7e9735a5d071b94297a2008726632e8; elf_machine=3e00 ;;
        arm64:aarch64) pkg_hash=5e8932d22eebeb5e91945edf244e6041047d304d95b8d3f905ce2868b1d2fffa; elf_machine=b700 ;;
        *) die '仅支持原生 AMD64 和 ARM64 的 64 位系统。' ;;
    esac
    [[ -d /run/systemd/system && $(< /proc/1/comm) == systemd ]] || die '需要以 systemd 为 PID 1 的服务器。'
    printf '检测到 %s %s，内核 %s，架构 %s。\n' "$ID" "$VERSION_ID" "$(uname -r)" "$ARCH" >&2
    exec 9>"$LOCK"
    flock -n 9 || die '另一个安装或卸载进程正在运行。'
    now=$(date +%s)
    (( now >= 1795219200 && now < 4102444800 )) || die '系统时间明显异常；请先检查时钟和 NTP。'
    check_conflicts
    nearest=/
    for route in /srv "$BASE"; do
        if lexists "$route"; then safe_parent "$route"; nearest=$route; fi
    done
    check_mount "$nearest" exec
    safe_parent /etc/systemd/system
    check_mount /etc/systemd/system data
    check_mount /var/tmp data
    check_mount /var/cache/apt data
    route=''
    while read -r iface dest _ flags _; do
        if [[ $dest == 00000000 && $flags =~ ^[0-9A-Fa-f]+$ && -d /sys/class/net/$iface ]] &&
            (( 16#$flags & 1 )); then route=$iface; break; fi
    done < /proc/net/route
    [[ -n $route ]] || die '未找到可用的 IPv4 默认路由。'
    timeout 10 getent ahostsv4 3proxy.org >/dev/null || die '解析 3proxy.org 失败，请检查 DNS。'
}

http() {
    curl -q --noproxy '*' --proto '=https' --proto-redir '=https' -4 \
        --connect-timeout 6 --max-time 18 --fail --silent --show-error "$@"
}
repo_https() {
    http --location --retry 2 --retry-max-time 36 --max-filesize 32768 \
        -o "$tmp/apt/key.asc" "$REPO/3proxy-release-key.asc" ||
        die '无法通过 HTTPS 下载官方签名公钥；请检查 DNS、时钟、证书和网络。'
}
installed() { [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]; }

install_dependencies() {
    local ssl arg plan
    local -a missing=() planned=()
    local -a apt_opts=(-o DPkg::Lock::Timeout=10 -o Acquire::Retries=2
        -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15
        -o Acquire::AllowInsecureRepositories=false -o APT::Get::AllowUnauthenticated=false
        -o Acquire::https::Verify-Peer=true -o Acquire::https::Verify-Host=true)
    case $ID:$VERSION_ID in debian:13|ubuntu:24.04) ssl=libssl3t64 ;; *) ssl=libssl3 ;; esac
    if ! installed libc6 || ! dpkg --compare-versions "$(dpkg-query -W -f='${Version}' libc6)" ge 2.34; then
        die '官方包需要 libc6 >= 2.34；不会升级现有系统库。'
    fi
    if ! installed ca-certificates; then missing+=(ca-certificates); fi
    if ! command -v curl >/dev/null; then missing+=(curl); fi
    if ! command -v ip >/dev/null || ! command -v ss >/dev/null; then missing+=(iproute2); fi
    if ! command -v gpgv >/dev/null && ! command -v sqv >/dev/null; then missing+=(gpgv); fi
    for arg in "$ssl" libpcre2-8-0; do
        if ! installed "$arg"; then missing+=("$arg"); fi
    done
    if (( ! ${#missing[@]} )); then return 0; fi

    warn "缺少必要依赖：${missing[*]}。仅允许新增软件包，不升级或移除系统包。"
    timeout -k 5 240 apt-get "${apt_opts[@]}" -o APT::Update::Error-Mode=any update \
        >"$tmp/apt-deps.log" 2>&1 || die '更新发行版 APT 索引失败；请检查已有软件源或 APT 锁。'
    plan=$(apt-get "${apt_opts[@]}" -s --no-install-recommends install "${missing[@]}" 2>"$tmp/apt-deps.log") ||
        die '无法解析依赖，请检查发行版软件源和 dpkg 状态。'
    if grep -Eq '^Remv |^Inst [^ ]+ \[' <<< "$plan"; then
        die '安装依赖需要升级或移除已有软件包（可能包括共享库）；请管理员先处理，本脚本未执行安装。'
    fi
    mapfile -t planned < <(awk '/^Inst / {v=$3; sub(/^\(/,"",v); sub(/\)$/,"",v); print $2 "=" v}' <<< "$plan")
    (( ${#planned[@]} > 0 && ${#planned[@]} <= 12 )) ||
        die '依赖计划为空或超过 12 个新增软件包；请管理员先补齐依赖。'
    printf '%s\n' "${planned[@]}" > "$tmp/apt-plan"
    # 此钩子由 APT 在持锁时运行，防止模拟之后出现升级或计划外的 deb。
    cat > "$tmp/apt-guard" <<'EOF'
#!/bin/bash
set -euo pipefail
dir=${0%/*}
while IFS= read -r archive; do
    pkg=$(dpkg-deb -f "$archive" Package)
    ver=$(dpkg-deb -f "$archive" Version)
    arch=$(dpkg-deb -f "$archive" Architecture)
    status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg:$arch" 2>/dev/null) || status=''
    [[ -z $status || $status == not-installed || $status == config-files ]] || exit 1
    grep -Fxq -- "$pkg=$ver" "$dir/apt-plan" || grep -Fxq -- "$pkg:$arch=$ver" "$dir/apt-plan" || exit 1
done
EOF
    DEBIAN_FRONTEND=noninteractive apt-get "${apt_opts[@]}" \
        -o "DPkg::Pre-Install-Pkgs::=/bin/bash $tmp/apt-guard" \
        --no-install-recommends --no-upgrade --no-remove -y install "${planned[@]}" \
        >"$tmp/apt-deps.log" 2>&1 || die '依赖安装失败或实际计划已变化。请检查 APT 锁、网络、磁盘空间及 dpkg 状态。'
}

fetch_package() {
    local -a isolated
    local -a files
    printf 'deb [arch=%s signed-by=%s/apt/key.asc,%s] %s/deb lts main\n' \
        "$ARCH" "$tmp" "$SIGNER" "$REPO" >"$tmp/apt/source.list"
    isolated=(-o "Dir::Etc::sourcelist=$tmp/apt/source.list" -o Dir::Etc::sourceparts=-
        -o "Dir::State::lists=$tmp/apt/lists" -o Dir::Cache::pkgcache= -o Dir::Cache::srcpkgcache=
        -o Acquire::Languages=none -o Acquire::ForceIPv4=true -o APT::Update::Error-Mode=any
        -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false
        -o APT::Get::AllowUnauthenticated=false -o Acquire::Check-Date=true -o Acquire::Check-Valid-Until=true
        -o Acquire::https::Verify-Peer=true -o Acquire::https::Verify-Host=true
        -o Acquire::https::AllowRedirect=false -o Acquire::https::Timeout=12 -o Acquire::Retries=2)
    timeout -k 5 100 apt-get "${isolated[@]}" update >"$tmp/official-apt.log" 2>&1 ||
        die '官方 APT 索引更新失败：可能是 DNS、网络超时、时钟、TLS 或固定公钥签名不符。'
    (
        cd "$tmp/download"
        timeout -k 5 70 apt-get "${isolated[@]}" download "3proxy:$ARCH=$DEB_VERSION"
    ) >"$tmp/official-apt.log" 2>&1 ||
        die "官方源中无法获取 3proxy $DEB_VERSION ($ARCH)；不回退到源码或第三方包。"
    files=("$tmp/download/"*.deb)
    (( ${#files[@]} == 1 )) && [[ -f ${files[0]} && ! -L ${files[0]} ]] || die '下载结果不是唯一的 deb。'
    pkg=$tmp/package.deb
    install -m 0600 -- "${files[0]}" "$pkg"
    printf '%s  %s\n' "$pkg_hash" "$pkg" | sha256sum --check --status ||
        die '软件包 SHA256 不符，下载可能不完整或上游包已发生变化。'
}

verify_binary() {
    local header libs
    [[ $(dpkg-deb -f "$pkg" Package) == 3proxy && $(dpkg-deb -f "$pkg" Architecture) == "$ARCH" &&
       $(dpkg-deb -f "$pkg" Version) == "$DEB_VERSION" ]] || die 'deb 元数据损坏或版本、架构不匹配。'
    dpkg-deb -x "$pkg" "$tmp/extracted" || die '无法解包官方 deb。'
    binary=$tmp/extracted/bin/3proxy
    [[ -d $tmp/extracted/bin && ! -L $tmp/extracted/bin && -f $binary && ! -L $binary && -x $binary ]] ||
        die '官方 deb 中固定路径 /bin/3proxy 不是可执行普通文件。'
    header=$(od -An -v -tx1 -N20 -- "$binary")
    header=${header//[[:space:]]/}
    [[ ${#header} == 40 && $header == 7f454c46020101* &&
       ${header:32:4} =~ ^0[23]00$ && ${header:36:4} == "$elf_machine" ]] ||
        die '不是预期架构的 64 位小端 Linux ELF 可执行程序。'
    # 只对已经过 APT 认证及固定 SHA256 校验的 ELF 运行 ldd。
    libs=$(env -i PATH="$PATH" LC_ALL=C ldd "$binary" 2>&1) ||
        die '无法解析 ELF 动态链接依赖，可能不兼容当前系统。'
    [[ $libs != *'not found'* && $libs == *libc.so.6* && $libs == *libssl.so.3* &&
       $libs == *libcrypto.so.3* && $libs == *libpcre2-8.so.0* ]] ||
        die '官方 ELF 的动态库缺失或加载失败；不会升级系统库。'
}

direct_probe() {
    local url
    for url in "${TEST_URLS[@]}"; do
        if runuser -u "$ACCOUNT" -- curl -q --noproxy '*' --proto '=https' -4 \
            --connect-timeout 5 --max-time 9 --silent --fail -o /dev/null "$url"; then return 0; fi
    done
    die '实际服务用户不能直连 HTTPS 测试站点；请检查 DNS 和出站网络。'
}
prepare_service() {
    local uid gid
    useradd --system --user-group --no-create-home --home-dir "$DIR" \
        --shell /usr/sbin/nologin "$ACCOUNT" || die '无法创建专用系统账号。'
    user_created=1
    if ! lexists /srv; then mkdir -m 0755 -- /srv; srv_created=1; fi
    if ! lexists "$BASE"; then mkdir -m 0755 -- "$BASE"; base_created=1; fi
    safe_parent /srv
    safe_parent "$BASE"
    mkdir -m 0700 -- "$DIR"
    dir_created=1
    chown "root:$ACCOUNT" "$DIR"
    chmod 0750 "$DIR"
    uid=$(id -u "$ACCOUNT")
    gid=$(id -g "$ACCOUNT")
    [[ $uid != 0 && $gid != 0 ]] || die '运行账号的 UID/GID 不得为 0。'
    printf '%s\n%s %s %s %s\n' "$OWNER" "$uid" "$gid" "$srv_created" "$base_created" > "$DIR/.installer-owner"
    install -o root -g "$ACCOUNT" -m 0750 -- "$binary" "$DIR/3proxy"
    runuser -u "$ACCOUNT" -- test -x "$DIR/3proxy" || die '运行用户不能遍历目录或执行 ELF。'
    direct_probe
}
write_config() {
    local source_acl='*' log_flag=-l/dev/null log_output=null
    if [[ -n $SOURCES ]]; then source_acl="127.0.0.1,$SOURCES"; fi
    if (( ACCESS_LOG )); then log_flag=-l; log_output=journal; fi
    # 16 字节均匀系统随机数，编码为 32 个十六进制字符（128 位熵）。
    PASSWORD=$(od -An -v -tx1 -N16 /dev/urandom)
    PASSWORD=${PASSWORD//[[:space:]]/}
    [[ $PASSWORD =~ ^[0-9a-f]{32}$ ]] || die '系统随机源未返回完整密码。'
    cat > "$DIR/3proxy.cfg" <<EOF
# 并发上限，必须位于 socks 指令之前。
maxconn 256
# 仅接受口令认证，不启用鉴权缓存。
users $USERNAME:CL:$PASSWORD
auth strong
# 先拒绝 BIND 和 UDP ASSOCIATE，再限制实际解析出的目标地址。
deny * * * * BIND,UDPASSOC
deny * * 0.0.0.0/8,10.0.0.0/8,100.64.0.0/10,127.0.0.0/8,169.254.0.0/16,172.16.0.0/12,192.168.0.0/16
deny * * 192.0.0.0/24,192.0.2.0/24,192.88.99.0/24,198.18.0.0/15,198.51.100.0/24,203.0.113.0/24,224.0.0.0/3
deny * * ::/0,168.63.129.16
allow $USERNAME $source_acl 0.0.0.0/0 * CONNECT
deny *
# 日志只包含连接元数据，不包含凭据及请求内容。
logformat "L%t %E %C:%c %R:%r %I %O"
socks -4 -u2 -i0.0.0.0 -p$PORT $log_flag
EOF
    chown "root:$ACCOUNT" "$DIR/3proxy.cfg"
    chmod 0640 "$DIR/3proxy.cfg"
    # shellcheck disable=SC2016
    runuser -u "$ACCOUNT" -- /bin/sh -c 'cd "$1" && test -x ./3proxy && test -r ./3proxy.cfg' sh "$DIR" ||
        die '运行用户不能进入工作目录、执行程序或读取配置。'
    unit_stage=$(mktemp /etc/systemd/system/.socks5-install.XXXXXXXX)
    cat > "$unit_stage" <<EOF
# $OWNER
[Unit]
Description=3proxy SOCKS5
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=exec
User=$ACCOUNT
Group=$ACCOUNT
WorkingDirectory=$DIR
ExecStart=$DIR/3proxy $DIR/3proxy.cfg
Restart=on-failure
RestartSec=3s
TimeoutStopSec=10s
UMask=0077
LimitNOFILE=4096
LimitCORE=0
NoNewPrivileges=yes
CapabilityBoundingSet=
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET
StandardOutput=$log_output
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$unit_stage"
    ln -- "$unit_stage" "$UNIT" || die '同名 unit 已出现或无法发布，不会覆盖。'
    unit_created=1
    systemd-analyze verify "$UNIT" >"$tmp/unit-verify.log" 2>&1 ||
        die 'systemd 单元校验失败，请检查 systemd 版本、依赖和执行路径。'
}

listener_ok() {
    local pid sockets
    pid=$(systemctl show -p MainPID --value "$SERVICE") || return 1
    [[ $pid =~ ^[1-9][0-9]*$ && /proc/$pid/exe -ef $DIR/3proxy ]] || return 1
    sockets=$(ss -H -ltnp "sport = :$PORT") || return 1
    [[ $sockets != *$'\n'* && $sockets == *"pid=$pid,"* &&
       $sockets =~ [[:space:]]0\.0\.0\.0:${PORT}[[:space:]] ]]
}
start_service() {
    local n
    systemctl daemon-reload || die 'systemd 无法重新加载单元。'
    [[ $(systemctl show -p FragmentPath --value "$SERVICE") == "$UNIT" &&
       -z $(systemctl show -p DropInPaths --value "$SERVICE") ]] ||
        die '发现其他 systemd 单元或覆盖规则，取消启动。'
    systemctl start "$SERVICE" || die '无法启动服务；请检查 journalctl -u socks5.service（CHDIR、EXEC、配置或端口错误）。'
    for (( n=0; n<40; n++ )); do
        if systemctl is-active --quiet "$SERVICE" && listener_ok; then return; fi
        [[ $(systemctl show -p NRestarts --value "$SERVICE") == 0 ]] ||
            die '进程启动后退出并发生重启，请检查服务日志。'
        sleep 0.25
    done
    die '未在规定时间内检测到属于 3proxy 主进程的 IPv4 监听，请检查服务日志。'
}

socks_reply() {
    local fd=$1 expected=$2 got
    got=$(timeout 4 od -An -v -tx1 -N2 <&"$fd") || return 1
    if [[ $expected == udp-deny ]]; then
        # 上游在 UDP 控制描述符初始化前拒绝时会立即关闭 TCP。
        # 只接受干净 EOF 或明确拒绝码，不接受超时、成功码或读错误。
        [[ -z $got || ${got//[[:space:]]/} == 0502 ]]
        return
    fi
    [[ ${got//[[:space:]]/} == "$expected" ]]
}
socks_probe() (
    local mode=$1 command=$2 address=$3 portbytes=$4 expected=$5 host=${6:-127.0.0.1}
    local fd secret=$PASSWORD userlen passlen
    exec {fd}<>"/dev/tcp/$host/$PORT" || exit 1
    if [[ $mode == none ]]; then
        printf '\x05\x01\x00' >&"$fd" && socks_reply "$fd" 05ff
        exit $?
    fi
    if [[ $mode == wrong ]]; then secret="x${secret:1}"; fi
    printf -v userlen '\\x%02x' "${#USERNAME}"
    printf -v passlen '\\x%02x' "${#secret}"
    printf '\x05\x01\x02' >&"$fd" && socks_reply "$fd" 0502 || exit 1
    printf '\x01%b%s%b%s' "$userlen" "$USERNAME" "$passlen" "$secret" >&"$fd" &&
        socks_reply "$fd" 0100 || exit 1
    printf '\x05%b\x00%b%b' "$command" "$address" "$portbytes" >&"$fd" || exit 1
    socks_reply "$fd" "$expected"
)
proxy_tests() {
    local url ok=0 loopback
    # 凭据通过 stdin 传给 curl，避免出现在命令行、环境变量或诊断日志中。
    for url in "${TEST_URLS[@]}"; do
        if printf 'proxy-user = "%s:%s"\n' "$USERNAME" "$PASSWORD" |
            curl -q --config - --noproxy '' --proxy "socks5h://127.0.0.1:$PORT" \
                --proto '=https' --silent --fail --connect-timeout 7 --max-time 15 -o /dev/null "$url"; then
            ok=1; break
        fi
    done
    (( ok )) || die '正确凭据未能通过代理访问任一 HTTPS 站点；请检查认证、DNS 或出站规则。'
    # 此版本在 CONNECT 请求阶段才对 RFC 1929 口令做最终校验。
    socks_probe wrong '\x01' '\x01\x01\x01\x01\x01' '\x01\xbb' 0502 ||
        die '错误密码未得到明确拒绝。'
    socks_probe none '' '' '' '' || die '无密码协商未得到明确拒绝。'
    local address
    for address in '\x01\x7f\x00\x00\x01' '\x01\x0a\x00\x00\x01' '\x01\xc0\xa8\x00\x01' \
        '\x01\xac\x10\x00\x01' '\x01\xa9\xfe\xa9\xfe' '\x01\x64\x40\x00\x01' \
        '\x01\xe0\x00\x00\x01' '\x01\xf0\x00\x00\x01'; do
        socks_probe good '\x01' "$address" '\x00\x50' 0502 || die '非公网 IPv4 目标未被 ACL 明确拒绝。'
    done
    loopback=$(timeout 5 getent ahostsv4 localhost) || die '无法解析 localhost，无法验证解析后的目标 ACL。'
    [[ $loopback == 127.* ]] || die 'localhost 未解析为环回地址，请修复系统解析配置。'
    socks_probe good '\x01' '\x03\x09localhost' '\x00\x50' 0502 ||
        die '解析到环回地址的域名未被明确拒绝。'
    socks_probe good '\x01' '\x04\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\x01' '\x00\x50' 0508 ||
        die 'IPv6 环回请求未被明确拒绝。'
    socks_probe good '\x01' '\x04\0\0\0\0\0\0\0\0\0\0\xff\xff\x7f\0\0\x01' '\x00\x50' 0508 ||
        die 'IPv4 映射 IPv6 请求未被明确拒绝。'
    socks_probe good '\x02' '\x01\x01\x01\x01\x01' '\x00\x50' 0502 ||
        die 'BIND 请求未被明确拒绝。'
    socks_probe good '\x03' '\x01\0\0\0\0' '\0\0' udp-deny ||
        die 'UDP ASSOCIATE 请求未被明确拒绝。'
    systemctl is-active --quiet "$SERVICE" && listener_ok &&
        [[ $(systemctl show -p NRestarts --value "$SERVICE") == 0 ]] ||
        die '代理测试后服务未保持稳定运行。'
}

network_tuning() (
    local cc=net.ipv4.tcp_congestion_control q=net.core.default_qdisc
    local old_cc old_q available stage parent_owner parent_mode set_cc=0 set_q=0
    (( BBR )) || { warn '已按要求跳过 BBR/FQ 配置。'; return 0; }
    exec 8>/run/linux-scripts-bbr.lock
    flock -n 8 || { warn '其他网络调优正在运行，跳过 BBR/FQ。'; return 0; }
    if lexists /etc/sysctl.d/99-linux-scripts-bbr.conf; then
        warn '独立 BBR 模块的配置已存在，SOCKS5 不再修改。'
        return 0
    fi
    command -v sysctl >/dev/null || { warn '缺少 sysctl，跳过 BBR/FQ。'; return 0; }
    if ! old_cc=$(sysctl -n "$cc" 2>/dev/null) || ! old_q=$(sysctl -n "$q" 2>/dev/null); then
        warn '无法读取当前 BBR/FQ 设置，跳过网络优化。'
        return 0
    fi
    if [[ $old_cc == bbr && $old_q == fq ]]; then return 0; fi
    if lexists "$SYSCTL"; then warn "保留已有 $SYSCTL，不覆盖。"; return 0; fi
    if [[ ! -d /etc/sysctl.d || -L /etc/sysctl.d ]] ||
       ! read -r parent_owner parent_mode < <(stat -c '%u %a' /etc/sysctl.d) ||
       [[ $parent_owner != 0 ]] || (( (8#$parent_mode & 022) != 0 )); then
        warn 'sysctl.d 不可用或权限不安全，不修改全局参数。'
        return 0
    fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) || available=''
    if [[ " $available " != *' bbr '* ]] && command -v modprobe >/dev/null; then
        if modprobe tcp_bbr 2>/dev/null; then
            available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) || available=''
        fi
    fi
    [[ " $available " == *' bbr '* ]] || { warn '当前内核未提供可用 BBR，继续安装。'; return 0; }
    stage=$(mktemp /etc/sysctl.d/.socks5-tune.XXXXXXXX 2>/dev/null) ||
        { warn '无法创建持久化配置，跳过全局设置。'; return 0; }
    trap 'rm -f -- "$stage"' EXIT
    if [[ $old_cc != bbr ]]; then
        if sysctl -qw "$cc=bbr" 2>/dev/null; then set_cc=1
        else warn '无法启用 BBR，继续安装。'; return 0; fi
    fi
    if [[ $old_q != fq ]]; then
        if sysctl -qw "$q=fq" 2>/dev/null; then set_q=1; else warn '无法设置默认 FQ；未修改任何网卡根队列。'; fi
    fi
    if (( set_cc || set_q )) && ! (
        {
            printf '# %s：默认值不会替换网卡现有根队列。\n' "$OWNER" || exit 1
            if (( set_cc )); then printf '%s = bbr\n' "$cc" || exit 1; fi
            if (( set_q )); then printf '%s = fq\n' "$q" || exit 1; fi
        } > "$stage" && ln -- "$stage" "$SYSCTL"
    ) 2>/dev/null; then
        warn '无法持久化网络设置，将尝试恢复本次修改。'
        if (( set_q )) && ! sysctl -qw "$q=$old_q" 2>/dev/null; then warn '未能恢复原默认队列。'; fi
        if (( set_cc )) && ! sysctl -qw "$cc=$old_cc" 2>/dev/null; then warn '未能恢复原拥塞控制。'; fi
    fi
    return 0
)

save_connection() {
    local result host
    if [[ -z $PUBLIC ]]; then
        if result=$(http --max-time 5 --max-filesize 64 https://api.ipify.org 2>/dev/null) &&
            ipv4 "$result"; then
            PUBLIC=$result
            warn '自动发现的是出口 IPv4；若有 NAT，请用实际入站地址替换。'
        else
            warn '未检测到公网地址；请手动填写入站 IPv4 或域名。'
        fi
    fi
    host=${PUBLIC:-PUBLIC_IPV4_OR_DOMAIN}
    cat > "$DIR/connection.txt" <<EOF
服务器地址：$host
代理端口：$PORT
代理类型：SOCKS5
用户名：$USERNAME
密码：$PASSWORD

Telegram 代理链接：
https://t.me/socks?server=$host&port=$PORT&user=$USERNAME&pass=$PASSWORD

SOCKS5 连接地址：
socks5://$USERNAME:$PASSWORD@$host:$PORT
EOF
}

main() {
    local cc_status='未知' q_status='未知'
    parse_args "$@"
    trap cleanup EXIT
    trap 'die "收到中断信号；正在回滚本次安装。"' INT TERM HUP
    trap 'die "步骤「$phase」失败（行 $LINENO，退出码 $?）。"' ERR
    step 1 '正在检测服务器环境'
    preflight
    step 2 '正在检查系统依赖'
    tmp=$(mktemp -d /var/tmp/3proxy-socks5.XXXXXXXX)
    chmod 0711 "$tmp"
    mkdir -m 0755 "$tmp/apt"
    if command -v curl >/dev/null && installed ca-certificates; then
        repo_https
    fi
    install_dependencies
    ip -4 route get 1.1.1.1 >/dev/null 2>&1 || die 'IPv4 路由不可用。'
    step 3 '正在验证签名并获取官方软件包'
    [[ -s $tmp/apt/key.asc ]] || repo_https
    chmod 0644 "$tmp/apt/key.asc"
    getent passwd _apt >/dev/null || die '缺少 APT 沙箱账号 _apt，请修复系统 APT。'
    install -d -m 0755 "$tmp/apt/lists"
    install -d -o _apt -m 0700 "$tmp/apt/lists/partial" "$tmp/download"
    fetch_package
    step 4 '正在检查 ELF 和动态链接库'
    verify_binary
    step 5 '正在创建并验证专用运行用户'
    check_conflicts
    prepare_service
    step 6 '正在生成代理配置和 systemd 单元'
    write_config
    step 7 '正在启动服务并检查监听进程'
    start_service
    step 8 '正在测试认证、HTTPS 转发和拒绝策略'
    proxy_tests
    enable_attempted=1
    systemctl enable "$SERVICE" >/dev/null 2>&1 &&
        [[ $(systemctl is-enabled "$SERVICE") == enabled ]] || die '设置持久开机自启失败。'
    save_connection
    step 9 '正在检查 BBR 及默认队列算法'
    # 核心安装已通过，非必要的全局网络优化失败不会卸载已就绪服务。
    committed=1
    network_tuning
    if command -v sysctl >/dev/null; then
        cc_status=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cc_status='不可用'
        q_status=$(sysctl -n net.core.default_qdisc 2>/dev/null) || q_status='不可用'
    fi
    step 10 '正在清理临时文件'
    rm -f -- "$unit_stage"; unit_stage=''
    rm -rf -- "$tmp"; tmp=''
    if [[ ! -t 1 ]]; then green='' reset=''; fi
    printf '\n%s========================================\n       SOCKS5 代理安装成功\n========================================%s\n\n' "$green" "$reset"
    cat -- "$DIR/connection.txt"
    printf '\n3proxy 版本：%s\n服务状态：运行中\n开机自启：已开启\n运行用户：%s\n代理测试：本机认证、HTTPS 转发和拒绝策略通过\nBBR 状态（当前拥塞算法）：%s\n默认队列算法：%s（不代表网卡现有队列）\n安装目录：%s\n连接信息文件：%s/connection.txt\n\n请在云防火墙放行 TCP %s，建议只允许自己的公网 IP。\n公网端口与 Telegram 客户端未测试。\n' \
        "$PROXY_VERSION" "$ACCOUNT" "$cc_status" "$q_status" "$DIR" "$DIR" "$PORT"
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
