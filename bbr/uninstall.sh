#!/bin/bash
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
readonly conf=/etc/sysctl.d/99-linux-scripts-bbr.conf
readonly cc=net.ipv4.tcp_congestion_control q=net.core.default_qdisc
red='' yellow='' green='' reset=''
if [[ -t 2 && ! ${NO_COLOR+x} ]] && colors=$(tput colors 2>/dev/null) &&
   [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
    red=$'\e[31m' yellow=$'\e[33m' green=$'\e[32m' reset=$'\e[0m'
fi
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
warn() { printf '%s警告：%s%s\n' "$yellow" "$*" "$reset" >&2; }
yes=0
case ${1:-}:$# in
    --help:1) printf '用法：sudo bash uninstall.sh [--yes]\n仅移除本模块配置，安全时恢复原值。\n'; exit 0 ;;
    --yes:1) yes=1 ;;
    :0) ;;
    *) die '未知选项，请使用 --help。' ;;
esac
trap 'die "卸载失败（行 $LINENO），请检查当前运行值。"' ERR
trap 'die "已中断，请检查持久配置和运行值。"' HUP INT TERM
[[ $(uname -s) == Linux && $EUID == 0 ]] || die '请在 Linux 上使用 root 或 sudo。'
[[ -d /run/systemd/system && $(< /proc/1/comm) == systemd ]] || die '需要运行中的 systemd。'
for tool in sysctl flock awk stat rm grep; do command -v "$tool" >/dev/null || die "缺少命令 $tool。"; done
sysd=/usr/lib/systemd/systemd-sysctl
[[ -x $sysd ]] || sysd=/lib/systemd/systemd-sysctl
[[ -x $sysd ]] || die '缺少 systemd-sysctl。'
exec 9>/run/linux-scripts-bbr.lock
flock -n 9 || die '其他网络调优正在运行。'
if [[ ! -e $conf && ! -L $conf ]]; then printf '未发现本模块的 BBR 配置。\n'; exit 0; fi
[[ -f $conf && ! -L $conf ]] || die '配置类型不安全，未删除。'
read -r owner mode < <(stat -c '%u %a' "$conf")
if [[ $owner != 0 ]] || (( (8#$mode & 022) != 0 )); then die '配置权限不安全，未删除。'; fi
mapfile -t lines < "$conf"
pattern='^# original ([a-zA-Z0-9_-]+) ([a-zA-Z0-9_-]+)$'
[[ ${#lines[@]} == 4 && ${lines[0]} == '# linux-scripts/bbr v1' &&
   ${lines[2]} == "$cc = bbr" && ${lines[3]} == "$q = fq" &&
   ${lines[1]} =~ $pattern ]] || die '配置不属于本模块或已改动，未删除。'
oldcc=${BASH_REMATCH[1]} oldq=${BASH_REMATCH[2]}
printf '将移除 %s；仅在运行值未变且不与其他配置冲突时恢复旧值。\n' "$conf" >&2
if (( ! yes )); then
    read -r -p '请输入 yes 确认：' reply </dev/tty || die '非交互环境请提供 --yes。'
    if [[ $reply != yes ]]; then printf '已取消。\n'; exit 0; fi
fi
# 事先取出除本模块外的最终显式配置；另检查独立的 sysctl.conf。
all=$("$sysd" --cat-config) || die '无法检查其他 sysctl 文件。'
effective() {
    awk -v own="$conf" -v wanted="$1" '
        /^# \// {skip=($2==own); next}
        !skip && /=/ {split($0,a,"="); k=a[1]; sub(/^[[:space:]]*-?/,"",k);
            gsub(/[[:space:]]/,"",k); gsub("/",".",k); if(k!=wanted) next;
            v=a[2]; sub(/^[[:space:]]*/,"",v); sub(/[[:space:]#;].*$/,"",v); last=v}
        END {print last}' <<< "$all"
}
rm -- "$conf"
restore() {
    local key=$1 set=$2 original=$3 current configured
    [[ $set != "$original" ]] || return 0
    current=$(sysctl -n "$key" 2>/dev/null) || { warn "无法读取 $key，保留运行值。"; return 0; }
    configured=$(effective "$key")
    if [[ -r /etc/sysctl.conf ]]; then
        manual=$(awk -F= -v wanted="$key" '
            /=/ {k=$1; v=$2; sub(/^[[:space:]]*-?/,"",k); gsub(/[[:space:]]/,"",k); gsub("/",".",k)
            if(k==wanted){sub(/^[[:space:]]*/,"",v); sub(/[[:space:]#;].*$/,"",v); last=v}}
            END {print last}' /etc/sysctl.conf)
    else manual=''; fi
    if [[ $current != "$set" || ( -n $configured && $configured != "$original" ) ||
        ( -n $manual && $manual != "$original" ) ]]; then
        warn "$key 已改动或存在其他配置，保留当前运行值。"
    elif ! sysctl -qw "$key=$original"; then
        warn "无法恢复 $key；仅删除了项目持久配置。"
    fi
}
restore "$cc" bbr "$oldcc"
restore "$q" fq "$oldq"
if [[ ! -t 1 ]]; then green='' reset=''; fi
printf '%s本模块的持久化配置已移除；未修改网卡根队列。%s\n' "$green" "$reset"
