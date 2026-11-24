#!/bin/bash
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
readonly version=0.72.0 base=/srv/net-services/frp owner=linux-scripts/frp-v1
role='' port=7000 remote=17000 local_port=8080 local_host=127.0.0.1 server=''
name=app proto=tcp tls_name=frps.local ca='' token_file='' proxy_bind=127.0.0.1
tmp='' stage='' own_dir=0 own_user=0 own_unit=0 enabling=0 done=0
red='' yellow='' green='' reset=''
if [[ -t 2 && ! ${NO_COLOR+x} ]] && colors=$(tput colors 2>/dev/null) &&
   [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
    red=$'\e[31m' yellow=$'\e[33m' green=$'\e[32m' reset=$'\e[0m'
fi
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
warn() { printf '%s警告：%s%s\n' "$yellow" "$*" "$reset" >&2; }
exists() { [[ -e $1 || -L $1 ]]; }
usage() {
    cat <<'EOF'
用法：sudo bash install.sh --server|--client [选项]
  --server                 安装 frps（监听 IPv4）
  --client                 安装 frpc
  --port N                 frps 控制端口，默认 7000，可用于两个角色
  --remote-port N          服务端允许/客户端映射的单一端口，默认 17000
  --tls-name HOST          证书中的 DNS 名，默认 frps.local，双方一致
服务端：
  --public-bind            将映射监听在公网接口；默认仅监听服务端环回
客户端：
  --server-addr HOST      frps IPv4 地址或域名
  --token-file PATH       root 拥有的私密 Token 文件（权限 0600 或更严）
  --tls-ca PATH           从可信渠道取得的 frps 公共证书文件
  --local-addr HOST       本地服务 IPv4 地址或域名，默认 127.0.0.1
  --local-port N          本地服务端口，默认 8080
  --name NAME             代理名，默认 app
  --protocol tcp|udp      映射协议，默认 tcp
缺少客户端地址、Token 或证书路径时，仅在有终端时安全提示输入。
EOF
}
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 >= $2 && $1 <= 65535 )); }
valid_dns() {
    local label
    local -a labels
    [[ ${#1} -le 253 && $1 =~ ^[A-Za-z0-9.-]+$ && $1 != .* && $1 != *. && $1 != *..* &&
       ${1##*.} =~ [A-Za-z] ]] || return 1
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}
valid_host() {
    local n
    local -a octets
    if [[ $1 =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]]; then
        IFS=. read -r -a octets <<< "$1"
        for n in "${octets[@]}"; do (( n <= 255 )) || return 1; done
        return 0
    fi
    valid_dns "$1"
}
parse() {
    local client_opts=0
    while (( $# )); do
        case $1 in
            --help) usage; exit 0 ;;
            --server|--client)
                [[ -z $role ]] || die '必须且只能指定一个角色。'
                if [[ $1 == --server ]]; then role=frps; else role=frpc; fi
                shift ;;
            --public-bind) proxy_bind=0.0.0.0; shift ;;
            --port|--remote-port|--tls-name|--server-addr|--token-file|--tls-ca|--local-addr|--local-port|--name|--protocol)
                [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 缺少参数。"
                case $1 in
                    --port) port=$2 ;; --remote-port) remote=$2 ;; --tls-name) tls_name=$2 ;;
                    --server-addr) server=$2; client_opts=1 ;; --token-file) token_file=$2; client_opts=1 ;;
                    --tls-ca) ca=$2; client_opts=1 ;; --local-addr) local_host=$2; client_opts=1 ;;
                    --local-port) local_port=$2; client_opts=1 ;; --name) name=$2; client_opts=1 ;;
                    --protocol) proto=$2; client_opts=1 ;;
                esac
                shift 2 ;;
            *) die '未知选项，请使用 --help。' ;;
        esac
    done
    [[ -n $role ]] || die '请选择 --server 或 --client。'
    if [[ $role == frps ]] && (( client_opts )); then die 'frps 不接受客户端专用选项。'; fi
    if [[ $role == frpc && $proxy_bind != 127.0.0.1 ]]; then die '--public-bind 仅用于 frps。'; fi
    if [[ $role == frps ]]; then valid_port "$port" 1024 || die '控制端口必须为 1024-65535。'
    else valid_port "$port" 1 || die '服务器端口必须为 1-65535。'; fi
    valid_port "$remote" 1024 || die '映射端口必须为 1024-65535。'
    valid_port "$local_port" 1 || die '本地端口必须为 1-65535。'
    [[ $remote != "$port" ]] || die '映射端口不能与控制端口相同。'
    valid_dns "$tls_name" || die 'TLS 证书名称必须为合法的 DNS 名。'
    if [[ -n $server ]]; then valid_host "$server" || die '服务端地址非法。'; fi
    valid_host "$local_host" || die '本地服务地址非法。'
    [[ $name =~ ^[A-Za-z0-9_][A-Za-z0-9_-]{0,31}$ ]] || die '代理名称格式错误。'
    [[ $proto == tcp || $proto == udp ]] || die '映射协议仅支持 tcp 或 udp。'
}
cleanup() {
    local rc=$? keep=0
    trap - EXIT ERR
    trap '' HUP INT TERM
    set +e
    if (( ! done )); then
        if (( own_unit )); then
            if (( enabling )) && ! systemctl disable "$unit" >/dev/null 2>&1; then keep=1; fi
            if ! systemctl stop "$unit" >/dev/null 2>&1 &&
               [[ $(systemctl show -p LoadState --value "$unit" 2>/dev/null) != not-found ]]; then keep=1; fi
            if (( ! keep )); then
                systemctl reset-failed "$unit" >/dev/null 2>&1
                rm -f -- "$unit_path" || keep=1
                systemctl daemon-reload || warn '回滚后重新加载 systemd 失败。'
            else warn '无法安全回滚服务，保留项目配置以便检查。'; fi
        fi
        if (( ! keep )); then
            if (( own_dir )); then
                rm -f -- "$dir"/{"$role","$role.toml",server.crt,server.key,ca.crt,token.txt,.installer-owner}
                rmdir -- "$dir" || warn '安装目录中仍有文件，请检查。'
            fi
            if (( own_user )); then
                userdel "$account" || warn '未能删除本次创建的账号。'
                if grep -q "^$account:" /etc/group; then groupdel "$account" || warn '未能删除本次创建的组。'; fi
            fi
        fi
    fi
    if [[ -n $stage ]]; then rm -f -- "$stage" || warn '未能清理 unit 临时文件。'; fi
    if [[ -n $tmp ]]; then rm -rf -- "$tmp" || warn '未能清理下载目录。'; fi
    exit "$rc"
}
safe_parent() {
    local path=$1 u m
    [[ -d $path && ! -L $path ]] || die "不安全的目录：$path。"
    read -r u m < <(stat -c '%u %a' "$path")
    if [[ $u != 0 ]] || (( (8#$m & 022) != 0 )); then die "$path 必须由 root 拥有且其他用户不可写。"; fi
}
port_free() {
    local p=$1 tcp udp
    if ! tcp=$(ss -H -ltn "sport = :$p") || ! udp=$(ss -H -lun "sport = :$p"); then
        die '无法检查监听端口。'
    fi
    [[ -z $tcp && -z $udp ]] || die "端口 $p 已被占用。"
}
parse "$@"
trap cleanup EXIT
trap 'die "安装中断，正在撤回本次创建的资源。"' INT TERM HUP
trap 'die "安装失败（行 $LINENO）。"' ERR
[[ $(uname -s) == Linux && -r /etc/os-release ]] || die '仅支持 Debian/Ubuntu Linux。'
(( EUID == 0 )) || die '请使用 root 或 sudo。'
# shellcheck disable=SC1091
. /etc/os-release
case ${ID:-}:${VERSION_ID:-} in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
    *) die '仅支持 Debian 12/13、Ubuntu 22.04/24.04。' ;;
esac
for tool in apt-get dpkg curl tar sha256sum od flock df getent stat install mkdir mktemp \
    grep awk ln chmod chown rmdir rm timeout systemctl systemd-analyze journalctl runuser \
    useradd userdel groupdel id sleep; do
    command -v "$tool" >/dev/null || die "缺少 $tool；请按 README 补齐必要依赖。"
done
if [[ $role == frps ]]; then
    for tool in openssl ss; do command -v "$tool" >/dev/null || die "服务端需要 $tool，请按 README 安装。"; done
fi
[[ -s /etc/ssl/certs/ca-certificates.crt ]] || die '缺少 CA 证书，请安装 ca-certificates。'
arch=$(dpkg --print-architecture)
case $arch:$(uname -m) in
    amd64:x86_64) hash=daf719b32ca2778770bb92955e231a07414d754378b9af328aa2642862479804; machine=3e00 ;;
    arm64:aarch64) hash=02180b857480302fd934e9ddbd50fe2f73229f99062f88756abc6de9df5e95cf; machine=b700 ;;
    *) die '仅支持原生 AMD64/ARM64。' ;;
esac
[[ -d /run/systemd/system && $(< /proc/1/comm) == systemd ]] || die '需要 systemd 为 PID 1。'
dir=$base/$role account=svc-${role}-script unit=$role.service
unit_path=/etc/systemd/system/$unit
exec 9>"/run/linux-scripts-$role.lock"
flock -n 9 || die '同一角色的安装或卸载正在执行。'
printf '[1/5] 检测 %s %s、%s 和内核 %s。\n' "$ID" "$VERSION_ID" "$arch" "$(uname -r)"
for p in "$dir" "$unit_path" "/etc/systemd/system/$unit.d" "/run/systemd/system/$unit.d"; do
    if exists "$p"; then die "已有路径 $p；不会覆盖。"; fi
done
[[ $(systemctl show -p LoadState --value "$unit") == not-found ]] || die '同名 systemd 服务已存在。'
for db in passwd group; do
    if getent "$db" "$account" >/dev/null; then die '运行账号或组已存在，不会接管。'
    else [[ $? == 2 ]] || die '无法检查账号。'; fi
done
nearest=/
for p in /srv /srv/net-services "$base"; do
    if exists "$p"; then safe_parent "$p"; nearest=$p; fi
done
safe_parent /etc/systemd/system
for p in "$nearest" /var/tmp /etc/systemd/system; do
    space=$(df -Pk -- "$p" | awk 'END{print $4}')
    if [[ ! $space =~ ^[0-9]+$ ]] || (( space < 131072 )); then die "$p 需要至少 128 MiB 可用空间。"; fi
done
if [[ $role == frps ]]; then
    port_free "$port"; port_free "$remote"
else
    if [[ -z $server ]]; then read -r -p 'frps 地址：' server </dev/tty || die '请指定 --server-addr。'; fi
    if [[ -z $token_file ]]; then read -r -p 'Token 文件路径：' token_file </dev/tty || die '请指定 --token-file。'; fi
    if [[ -z $ca ]]; then read -r -p '可信证书路径：' ca </dev/tty || die '请指定 --tls-ca。'; fi
    valid_host "$server" || die 'frps 地址非法。'
    [[ -f $token_file && ! -L $token_file ]] || die 'Token 必须来自普通文件，不能用符号链接。'
    read -r uid mode size < <(stat -c '%u %a %s' -- "$token_file")
    if [[ $uid != 0 ]] || (( (8#$mode & 077) != 0 || size > 129 )); then die 'Token 文件必须由 root 拥有、仅 root 可访问且不超过 129 字节。'; fi
    token=$(<"$token_file")
    [[ $token =~ ^[A-Za-z0-9_.~-]{24,128}$ ]] || die 'Token 必须为 24-128 个安全 ASCII 字符。'
    [[ -s $ca && -f $ca && ! -L $ca && $(stat -c '%s' -- "$ca") -le 1048576 ]] || die '可信证书文件无效。'
    timeout 10 getent ahostsv4 "$server" >/dev/null || die '无法解析 frps 的 IPv4 地址。'
fi
timeout 10 getent ahosts github.com >/dev/null || die '无法解析官方 GitHub Releases。'
printf '[2/5] 下载并校验 FRP %s 官方存档。\n' "$version"
tmp=$(mktemp -d /var/tmp/linux-scripts-frp.XXXXXXXX) || die '无法创建临时目录。'
dist="frp_${version}_linux_$arch"
curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 8 --max-time 90 --retry 2 --retry-all-errors --retry-max-time 110 --max-filesize 67108864 \
    -o "$tmp/frp.tar.gz" "https://github.com/fatedier/frp/releases/download/v$version/$dist.tar.gz" ||
    die '下载失败；请检查 GitHub 连通性、TLS、系统时间和磁盘。'
printf '%s  %s\n' "$hash" "$tmp/frp.tar.gz" | sha256sum --check --status || die 'FRP 存档 SHA256 不匹配。'
tar -xzf "$tmp/frp.tar.gz" --no-same-owner -C "$tmp" -- "$dist/$role" || die '归档缺少指定角色二进制。'
bin=$tmp/$dist/$role
[[ -f $bin && ! -L $bin && -x $bin ]] || die '所选文件不是普通 ELF 可执行文件。'
header=$(od -An -v -tx1 -N20 -- "$bin")
header=${header//[[:space:]]/}
[[ ${#header} == 40 && $header == 7f454c46020101* && ${header:32:4} =~ ^0[23]00$ &&
   ${header:36:4} == "$machine" ]] || die 'ELF 类型或架构不匹配。'
[[ $(timeout 10 "$bin" --version) == "$version" ]] || die '不能执行官方二进制或版本不符。'

printf '[3/5] 创建非 root 账号、配置及 TLS 材料。\n'
for p in /srv /srv/net-services "$base"; do
    if ! exists "$p"; then mkdir -m 0755 -- "$p" || [[ -d $p ]]; fi
    safe_parent "$p"
done
useradd --system --user-group --no-create-home --home-dir "$dir" --shell /usr/sbin/nologin "$account" ||
    die '创建专用运行账号失败。'
own_user=1
mkdir -m 0700 -- "$dir"
own_dir=1
chown "root:$account" "$dir"
chmod 0750 "$dir"
printf '%s\n%s %s\n' "$owner" "$(id -u "$account")" "$(id -g "$account")" >"$dir/.installer-owner"
install -o root -g "$account" -m 0750 -- "$bin" "$dir/$role"
if [[ $role == frps ]]; then
    token=$(od -An -v -tx1 -N32 /dev/urandom)
    token=${token//[[:space:]]/}
    [[ $token =~ ^[a-f0-9]{64}$ ]] || die '系统随机源未返回完整 Token。'
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 365 \
        -subj "/CN=$tls_name" -addext "subjectAltName=DNS:$tls_name" \
        -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
        -addext 'extendedKeyUsage=serverAuth' -keyout "$dir/server.key" -out "$dir/server.crt" \
        >"$tmp/openssl.log" 2>&1 || die '生成 TLS 证书失败。'
    chown "root:$account" "$dir"/{server.key,server.crt}
    chmod 0640 "$dir"/{server.key,server.crt}
    printf '%s\n' "$token" >"$dir/token.txt"
    cat >"$dir/$role.toml" <<EOF
# 控制连接和映射监听分别配置；不启用 Dashboard 或其他入口。
bindAddr = "0.0.0.0"
bindPort = $port
proxyBindAddr = "$proxy_bind"
allowPorts = [{single = $remote}]
maxPortsPerClient = 1
auth.method = "token"
auth.token = "$token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.tls.force = true
transport.tls.certFile = "$dir/server.crt"
transport.tls.keyFile = "$dir/server.key"
log.to = "console"
log.disablePrintColor = true
EOF
else
    install -o root -g "$account" -m 0640 -- "$ca" "$dir/ca.crt"
    cat >"$dir/$role.toml" <<EOF
# 使用显式信任的证书校验 frps 身份。
serverAddr = "$server"
serverPort = $port
loginFailExit = true
auth.method = "token"
auth.token = "$token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
transport.tls.enable = true
transport.tls.trustedCaFile = "$dir/ca.crt"
transport.tls.serverName = "$tls_name"
log.to = "console"
log.disablePrintColor = true

[[proxies]]
name = "$name"
type = "$proto"
localIP = "$local_host"
localPort = $local_port
remotePort = $remote
EOF
fi
unset token
chown "root:$account" "$dir/$role.toml"
chmod 0640 "$dir/$role.toml"
runuser -u "$account" -- "$dir/$role" verify -c "$dir/$role.toml" >"$tmp/config.log" 2>&1 ||
    die '以运行账号检验配置失败；请检查目录遍历、TLS 文件权限和配置语法。'

printf '[4/5] 创建并启动 systemd 服务。\n'
stage=$(mktemp /etc/systemd/system/.linux-scripts-frp.XXXXXXXX)
cat >"$stage" <<EOF
# $owner
[Unit]
Description=FRP $role
Wants=network-online.target
After=network-online.target
StartLimitBurst=5
StartLimitIntervalSec=60

[Service]
Type=exec
User=$account
Group=$account
WorkingDirectory=$dir
ExecStart=$dir/$role -c $dir/$role.toml
Restart=on-failure
RestartSec=3s
TimeoutStopSec=10s
NoNewPrivileges=yes
CapabilityBoundingSet=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET
UMask=0077
LimitCORE=0

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$stage"
ln -- "$stage" "$unit_path" || die '同名服务路径已占用，未覆盖。'
own_unit=1
systemd-analyze verify "$unit_path" >"$tmp/systemd.log" 2>&1 || die 'systemd 单元检查失败。'
systemctl daemon-reload
[[ $(systemctl show -p FragmentPath --value "$unit") == "$unit_path" &&
   -z $(systemctl show -p DropInPaths --value "$unit") ]] || die '发现其他覆盖配置，拒绝启动。'
systemctl start "$unit" || die "启动失败；请查看 journalctl -u $unit。"
printf '[5/5] 验证进程、监听或客户端注册，再设置开机自启。\n'
ready=0
for (( n=0; n<48; n++ )); do
    if ! systemctl is-active --quiet "$unit" || [[ $(systemctl show -p NRestarts --value "$unit") != 0 ]]; then break; fi
    pid=$(systemctl show -p MainPID --value "$unit")
    if [[ $pid =~ ^[1-9][0-9]*$ && /proc/$pid/exe -ef $dir/$role ]]; then
        if [[ $role == frps ]]; then
            sockets=$(ss -H -ltnp "sport = :$port")
            if [[ $sockets == *"pid=$pid,"* && $sockets =~ [[:space:]]0\.0\.0\.0:${port}[[:space:]] ]]; then ready=1; break; fi
        else
            invocation=$(systemctl show -p InvocationID --value "$unit")
            if [[ $invocation =~ ^[a-f0-9]{32}$ ]]; then
                journal=$(journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$invocation")
                if [[ $journal == *'login to server success'* && $journal == *"[$name] start proxy success"* ]]; then ready=1; break; fi
            fi
        fi
    fi
    sleep 0.5
done
(( ready )) || die "未验证稳定监听或客户端登录与映射注册；检查 journalctl -u $unit。"
enabling=1
if ! systemctl enable "$unit" >/dev/null 2>&1 || ! systemctl is-enabled --quiet "$unit"; then
    die '开机自启设置失败。'
fi
done=1
if [[ ! -t 1 ]]; then green='' reset=''; fi
printf '%s%s %s 已启动并启用开机自启。%s\n' "$green" "$role" "$version" "$reset"
if [[ $role == frps ]]; then
    printf 'IPv4 控制端口：%s；允许映射：%s:%s\nToken 文件：%s/token.txt\n需安全分发的公有证书：%s/server.crt（证书名 %s）\n' \
        "$port" "$proxy_bind" "$remote" "$dir" "$dir" "$tls_name"
    warn '脚本未修改防火墙；请限制控制连接来源并独立验证入站连通性。'
else
    printf '已验证服务端登录及 %s 映射注册；未验证外部业务流量和防火墙。\n' "$name"
fi
