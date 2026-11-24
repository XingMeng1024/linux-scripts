#!/bin/bash
# 只在可丢弃的干净 Debian/Ubuntu systemd 虚拟机内运行。
set -euo pipefail
umask 077
cd "$(dirname "$0")/../socks5"
[[ ${1:-} == --disposable-vm ]] || { printf '仅限可丢弃 VM；需提供 --disposable-vm。\n' >&2; exit 2; }
(( EUID == 0 )) && [[ $(< /proc/1/comm) == systemd ]]
dir=/srv/net-services/socks5 unit=/etc/systemd/system/socks5.service
port=21080 account=svc-3proxy-socks
if [[ ${2:-} == --after-reboot ]]; then
    systemctl is-enabled --quiet socks5.service
    systemctl is-active --quiet socks5.service
    # shellcheck disable=SC1091
    . ./install.sh
    USERNAME=$(awk '/^users / {split($2,a,":"); print a[1]}' "$DIR/3proxy.cfg")
    PASSWORD=$(awk '/^users / {split($2,a,":"); print a[3]}' "$DIR/3proxy.cfg")
    proxy_tests
    tuning=/etc/sysctl.d/90-3proxy-socks5-installer.conf
    tuning_before=''
    if [[ -f $tuning ]]; then tuning_before=$(sha256sum "$tuning"); fi
    touch "$DIR/leave-me"
    if bash ./uninstall.sh --yes 2>/dev/null; then
        printf '卸载器不应移除含非项目文件的目录。\n' >&2
        exit 1
    fi
    [[ -f $DIR/leave-me ]]
    rm -- "$DIR/leave-me"
    bash ./uninstall.sh --yes
    [[ ! -e $dir && ! -e $unit ]]
    if getent passwd "$account" >/dev/null || getent group "$account" >/dev/null; then exit 1; fi
    if [[ -n $tuning_before ]]; then [[ $(sha256sum "$tuning") == "$tuning_before" ]]; fi
    bash ./uninstall.sh --yes
    printf '重启后真实转发及卸载测试通过。\n'
    exit
fi
[[ ! -e $dir && ! -e $unit ]]
if getent passwd "$account" >/dev/null || getent group "$account" >/dev/null; then exit 1; fi
log=$(mktemp)
busy=''
cleanup() {
    if [[ -n $busy ]]; then kill "$busy" 2>/dev/null || :; wait "$busy" 2>/dev/null || :; fi
    rm -f -- "$log"
}
trap cleanup EXIT
expect_failure() {
    local message=$1; shift
    if "$@" >"$log" 2>&1; then printf '预期失败但命令成功：%s\n' "$message" >&2; return 1; fi
    if ! grep -Fq "$message" "$log"; then
        printf '未得到预期错误：%s\n' "$message" >&2
        # 安装前或失败阶段没有成功凭据输出；仍避免写入测试日志。
        grep -E '^\[[0-9]+/10\]|^错误：|^警告：' "$log" >&2 || :
        return 1
    fi
}
assert_clean() {
    [[ ! -e $dir && ! -e $unit ]]
    if getent passwd "$account" >/dev/null || getent group "$account" >/dev/null; then exit 1; fi
    [[ $(systemctl show -p LoadState --value socks5.service) == not-found ]]
    [[ ! -e /etc/systemd/system/multi-user.target.wants/socks5.service ]]
}
expect_failure '请使用 root' runuser -u nobody -- bash ./install.sh
expect_failure '正在运行' flock /run/3proxy-socks5-installer.lock bash ./install.sh
printf 'ID=unsupported\nVERSION_ID=99\n' > "$log"
# 仅在私有挂载命名空间替换 os-release；不修改 VM 真实系统文件。
# shellcheck disable=SC2016
output=$(unshare --mount --propagation private bash -c '
    mount --bind "$1" "$(readlink -f /etc/os-release)"
    exec bash ./install.sh
' sh "$log" 2>&1) && exit 1
[[ $output == *'只支持 Debian 12/13'* ]]
command -v systemd-socket-activate >/dev/null
systemd-socket-activate -l "127.0.0.1:$port" /bin/cat >"$log" 2>&1 &
busy=$!
for (( n=0; n<50; n++ )); do
    if grep -q 'Listening on' "$log"; then break; fi
    sleep 0.1
done
grep -q 'Listening on' "$log"
expect_failure '已被占用' bash ./install.sh --no-bbr
kill "$busy"
wait "$busy" 2>/dev/null || :
busy=''
assert_clean

# 向真实的官方 APT 流程提供无效公钥，必须拒绝索引，不下载或安装 deb。
# shellcheck disable=SC2016
expect_failure '官方 APT 索引更新失败' bash -c '
    source ./install.sh
    repo_https() { printf "invalid test key\n" > "$tmp/apt/key.asc"; }
    main --no-bbr
'
assert_clean

# 用真实 HTTPS 客户端复现官方站点不可达，不编辑系统 DNS、防火墙或源。
# shellcheck disable=SC2016
expect_failure '无法通过 HTTPS 下载' bash -c '
    source ./install.sh
    http() { curl -q --noproxy "*" --connect-timeout 1 --max-time 2 -fsS https://127.0.0.1:1/; }
    main --no-bbr
'
assert_clean

# 在真实服务启动及完整代理测试之后注入可控失败，检查事务回滚。
# shellcheck disable=SC2016
expect_failure '测试专用回滚触发点' bash -c '
    source ./install.sh
    save_connection() { die "测试专用回滚触发点"; }
    main --no-bbr --public-ip proxy.example.com
'
assert_clean

# 用无 BBR 可用的 sysctl/modprobe 替身覆盖降级分支；其他步骤真实执行。
run_install() (
    if [[ ${2:-} == --real-bbr ]]; then
        bash ./install.sh --public-ip proxy.example.com --allow-source 203.0.113.17 --enable-log
        exit
    fi
    # shellcheck disable=SC2016
    bash -c '
        source ./install.sh
        sysctl() {
            case "$*" in
                "-n net.ipv4.tcp_congestion_control") printf "cubic\n" ;;
                "-n net.core.default_qdisc") printf "fq_codel\n" ;;
                "-n net.ipv4.tcp_available_congestion_control") printf "reno cubic\n" ;;
                *) return 1 ;;
            esac
        }
        modprobe() { return 1; }
        lexists() { [[ $1 != "$SYSCTL" && ( -e $1 || -L $1 ) ]]; }
        main --public-ip proxy.example.com --allow-source 203.0.113.17 --enable-log
    '
)
if ! run_install "$@" >"$log" 2>&1; then
    grep -E '^\[[0-9]+/10\]|^错误：|^警告：' "$log" >&2 || :
    exit 1
fi
if [[ ${2:-} != --real-bbr ]]; then grep -Fq '内核未提供可用 BBR' "$log"; fi
grep -q '本机认证、HTTPS 转发和拒绝策略通过' "$log"
[[ $(stat -c '%a:%U:%G' "$dir/3proxy.cfg") == "640:root:$account" ]]
[[ $(stat -c '%a:%U:%G' "$dir/3proxy") == "750:root:$account" ]]
[[ $(stat -c '%a:%U:%G' "$dir") == "750:root:$account" ]]
[[ $(stat -c '%a:%U:%G' "$dir/connection.txt") == 600:root:root ]]
[[ $(stat -c '%a:%U:%G' "$unit") == 644:root:root ]]
if runuser -u "$account" -- test -r "$dir/connection.txt"; then exit 1; fi
(
    # shellcheck disable=SC1091
    . ./install.sh
    USERNAME=$(awk '/^users /{split($2,a,":"); print a[1]}' "$DIR/3proxy.cfg")
    PASSWORD=$(awk '/^users /{split($2,a,":"); print a[3]}' "$DIR/3proxy.cfg")
    [[ -n $USERNAME && ${#PASSWORD} == 32 ]]
    addr=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src"){print $(i+1); break}}')
    [[ -n $addr && $addr != 127.* ]]
    socks_probe good '\x01' '\x01\x01\x01\x01\x01' '\x01\xbb' 0502 "$addr"
    sleep 1
    inv=$(systemctl show -p InvocationID --value "$SERVICE")
    log_lines=$(journalctl --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$inv")
    [[ $log_lines != *"$PASSWORD"* ]]
    grep -Eq '^[0-9]{9,} [0-9]+ 127\.0\.0\.1:' <<< "$log_lines"
)
fingerprint=$(sha256sum "$dir/3proxy.cfg")
expect_failure '已存在；不会覆盖' bash ./install.sh
[[ $(sha256sum "$dir/3proxy.cfg") == "$fingerprint" ]]
printf '初次安装、拒绝策略、权限、冲突及回滚测试通过。请重启 VM，再执行 --disposable-vm --after-reboot。\n'
