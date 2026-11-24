#!/bin/bash
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
readonly conf=/etc/sysctl.d/99-linux-scripts-bbr.conf
readonly cc=net.ipv4.tcp_congestion_control q=net.core.default_qdisc
readonly marker='# linux-scripts/bbr v1'
red='' yellow='' green='' reset='' stage='' oldcc='' oldq='' changedcc=0 changedq=0 published=0 done=0
if [[ -t 2 && ! ${NO_COLOR+x} ]] && colors=$(tput colors 2>/dev/null) &&
   [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
    red=$'\e[31m' yellow=$'\e[33m' green=$'\e[32m' reset=$'\e[0m'
fi
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
warn() { printf '%s警告：%s%s\n' "$yellow" "$*" "$reset" >&2; }
cleanup() {
    local rc=$?
    trap - EXIT ERR
    trap '' HUP INT TERM
    if (( ! done )); then
        if (( published )) && ! rm -- "$conf"; then warn '未能删除本次配置。'; fi
        if (( changedq )) && ! sysctl -qw "$q=$oldq"; then warn '恢复原默认队列失败。'; fi
        if (( changedcc )) && ! sysctl -qw "$cc=$oldcc"; then warn '恢复原拥塞算法失败。'; fi
    fi
    if [[ -n $stage ]] && ! rm -f -- "$stage"; then warn '未能清理临时配置。'; fi
    exit "$rc"
}
case ${1:-} in
    --help) printf '用法：sudo bash install.sh\n启用内核自带 BBR 和默认 FQ；不修改网卡根队列。\n'; exit 0 ;;
    '') [[ $# == 0 ]] || die '不接受空参数。' ;;
    *) die '未知选项，请使用 --help。' ;;
esac
trap cleanup EXIT
trap 'die "已中断，正在恢复本次修改。"' HUP INT TERM
trap 'die "执行失败（行 $LINENO）。"' ERR
[[ $(uname -s) == Linux && -r /etc/os-release ]] || die '仅支持 Debian/Ubuntu Linux。'
(( EUID == 0 )) || die '请使用 root 或 sudo。'
# shellcheck disable=SC1091
. /etc/os-release
case ${ID:-}:${VERSION_ID:-}:$(uname -m) in
    debian:12:x86_64|debian:12:aarch64|debian:13:x86_64|debian:13:aarch64|\
    ubuntu:22.04:x86_64|ubuntu:22.04:aarch64|ubuntu:24.04:x86_64|ubuntu:24.04:aarch64) ;;
    *) die '仅支持 Debian 12/13、Ubuntu 22.04/24.04 的 AMD64/ARM64。' ;;
esac
for tool in apt-get sysctl flock awk stat mktemp ln rm uname grep; do
    command -v "$tool" >/dev/null || die "缺少命令 $tool；本模块不自动装包。"
done
[[ -d /run/systemd/system && $(< /proc/1/comm) == systemd ]] || die '需要 systemd 为 PID 1。'
sysd=/usr/lib/systemd/systemd-sysctl
[[ -x $sysd ]] || sysd=/lib/systemd/systemd-sysctl
[[ -x $sysd ]] || die '缺少 systemd-sysctl。'
exec 9>/run/linux-scripts-bbr.lock
flock -n 9 || die '其他网络调优正在运行。'
printf '[1/3] 检测内核 %s 及当前网络设置。\n' "$(uname -r)"
if ! oldcc=$(sysctl -n "$cc") || ! oldq=$(sysctl -n "$q"); then die '内核未暴露所需 sysctl。'; fi
[[ $oldcc =~ ^[a-zA-Z0-9_-]+$ && $oldq =~ ^[a-zA-Z0-9_-]+$ ]] || die '当前内核参数格式异常。'
printf '当前拥塞算法：%s；默认队列：%s。\n' "$oldcc" "$oldq"
if command -v ip >/dev/null && command -v tc >/dev/null; then
    dev=$(ip -4 route show default | awk 'NR==1 {for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); break}}')
    if [[ -n $dev ]]; then printf '默认网卡 %s 的实际队列：\n' "$dev"; tc qdisc show dev "$dev" || warn '无法读取实际队列。'; fi
else warn '缺少 ip/tc，无法显示实际网卡队列；不会安装诊断工具。'; fi
if [[ -e $conf || -L $conf ]]; then
    [[ -f $conf && ! -L $conf ]] || die '持久化路径被占用；未修改。'
    IFS= read -r tag < "$conf"
    if [[ $tag == "$marker" && $oldcc == bbr && $oldq == fq ]]; then
        printf '本模块已启用 BBR/FQ，无需重复配置。\n'; exit 0
    fi
    die '已存在同名配置或运行值已变，请人工检查，不覆盖。'
fi
active=$("$sysd" --cat-config) || die '无法读取 systemd 的 sysctl 配置顺序。'
later=$(awk -v filename="${conf##*/}" '
    /^# \// {n=split($2,a,"/"); later=(a[n]>filename || a[n]=="sysctl.conf"); next}
    later && /^[[:space:]]*-?[[:space:]]*net[./]/ {
        if (!index($0,"=")) next
        split($0,p,"="); k=p[1]; gsub(/[[:space:]-]/,"",k); gsub("/",".",k)
        v=p[2]; sub(/^[[:space:]]*/,"",v); sub(/[[:space:]#;].*$/,"",v)
        if ((k=="net.ipv4.tcp_congestion_control" && v!="bbr") ||
            (k=="net.core.default_qdisc" && v!="fq")) print k
    }
' <<< "$active")
[[ -z $later ]] || die '存在加载顺序更靠后的冲突设置；请先协调 sysctl 配置。'
if [[ -r /etc/sysctl.conf ]]; then
    manual=$(awk -F= '
        /^[[:space:]]*-?[[:space:]]*net[./]/ {
            k=$1; v=$2; gsub(/[[:space:]-]/,"",k); gsub("/",".",k)
            sub(/^[[:space:]]*/,"",v); sub(/[[:space:]#;].*$/,"",v)
            if ((k=="net.ipv4.tcp_congestion_control" && v!="bbr") ||
                (k=="net.core.default_qdisc" && v!="fq")) print k
        }' /etc/sysctl.conf)
    [[ -z $manual ]] || die '/etc/sysctl.conf 存在可覆盖的冲突设置；未修改。'
fi
if [[ $oldcc == bbr && $oldq == fq ]] &&
   grep -Eq '^[[:space:]]*-?net[./]ipv4[./]tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$' <<< "$active" &&
   grep -Eq '^[[:space:]]*-?net[./]core[./]default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$' <<< "$active"; then
    # 其他配置可能覆盖较早的设置；只在最终明确值一致时跳过。
    effective=$(awk -F= '/^[[:space:]]*-?net[./]/ {k=$1; v=$2; gsub(/[[:space:]-]/,"",k); gsub("/",".",k);
        gsub(/[[:space:]]/,"",v); if(k=="net.ipv4.tcp_congestion_control") a=v;
        if(k=="net.core.default_qdisc") b=v} END{print a,b}' <<< "$active")
    if [[ $effective == 'bbr fq' ]]; then printf '已有其他配置持久化 BBR/FQ，无需接管。\n'; exit 0; fi
fi
printf '[2/3] 检查内核的 BBR 和 FQ 能力。\n'
available=$(sysctl -n net.ipv4.tcp_available_congestion_control)
if [[ " $available " != *' bbr '* ]] && command -v modprobe >/dev/null; then
    if modprobe tcp_bbr 2>/dev/null; then available=$(sysctl -n net.ipv4.tcp_available_congestion_control); fi
fi
[[ " $available " == *' bbr '* ]] || die '当前内核未提供可用 BBR；不会升级内核。'
[[ -d /etc/sysctl.d && ! -L /etc/sysctl.d ]] || die 'sysctl.d 不是安全目录。'
read -r uid mode < <(stat -c '%u %a' /etc/sysctl.d)
if [[ $uid != 0 ]] || (( (8#$mode & 022) != 0 )); then die 'sysctl.d 权限不安全。'; fi
stage=$(mktemp /etc/sysctl.d/.linux-scripts-bbr.XXXXXXXX) || die '不能创建临时配置，请检查容量和权限。'
printf '%s\n# original %s %s\n%s = bbr\n%s = fq\n' "$marker" "$oldcc" "$oldq" "$cc" "$q" >"$stage"
printf '[3/3] 应用并验证 BBR 和默认 FQ。\n'
if [[ $oldcc != bbr ]]; then sysctl -qw "$cc=bbr" || die '写入 BBR 失败。'; changedcc=1; fi
if [[ $oldq != fq ]]; then sysctl -qw "$q=fq" || die '内核无法设置 FQ。'; changedq=1; fi
[[ $(sysctl -n "$cc") == bbr && $(sysctl -n "$q") == fq ]] || die '运行值验证失败。'
ln -- "$stage" "$conf" || die '无法发布持久化配置，未覆盖已有文件。'
published=1
done=1
if [[ ! -t 1 ]]; then green='' reset=''; fi
printf '%s已启用 BBR 和默认 FQ；未替换网卡实际队列。%s\n' "$green" "$reset"
