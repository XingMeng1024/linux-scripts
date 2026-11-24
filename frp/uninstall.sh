#!/bin/bash
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
readonly base=/srv/net-services/frp owner=linux-scripts/frp-v1
role='' yes=0
red='' green='' reset=''
if [[ -t 2 && ! ${NO_COLOR+x} ]] && colors=$(tput colors 2>/dev/null) &&
   [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
    red=$'\e[31m' green=$'\e[32m' reset=$'\e[0m'
fi
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
exists() { [[ -e $1 || -L $1 ]]; }
while (( $# )); do
    case $1 in
        --help) printf '用法：sudo bash uninstall.sh --server|--client [--yes]\n只卸载指定角色，不影响另一角色。\n'; exit 0 ;;
        --server|--client)
            [[ -z $role ]] || die '只允许指定一个待卸载角色。'
            if [[ $1 == --server ]]; then role=frps; else role=frpc; fi ;;
        --yes) yes=1 ;; *) die '未知选项，请使用 --help。' ;;
    esac
    shift
done
[[ -n $role ]] || die '请选择 --server 或 --client。'
trap 'die "卸载失败（行 $LINENO）；请检查后重试。"' ERR
trap 'die "操作中断，请检查当前角色的状态。"' HUP INT TERM
[[ $(uname -s) == Linux && $EUID == 0 ]] || die '请在 Linux 上使用 root 或 sudo。'
[[ -d /run/systemd/system && $(< /proc/1/comm) == systemd ]] || die '需要运行中的 systemd。'
for tool in flock systemctl stat id getent awk grep userdel groupdel rm rmdir; do
    command -v "$tool" >/dev/null || die "缺少必要命令 $tool。"
done
dir=$base/$role account=svc-${role}-script unit=$role.service
unit_path=/etc/systemd/system/$unit
exec 9>"/run/linux-scripts-$role.lock"
flock -n 9 || die '同一角色的安装或卸载正在运行。'
if ! exists "$dir" && ! exists "$unit_path"; then printf '没有本模块的 %s 安装。\n' "$role"; exit 0; fi
safe_path() {
    local u m
    [[ -e $1 && ! -L $1 ]] || die "路径缺失或为链接：$1。"
    read -r u m < <(stat -c '%u %a' "$1")
    if [[ $u != 0 ]] || (( (8#$m & 022) != 0 )); then die "路径权限不安全：$1。"; fi
}
for p in /srv /srv/net-services "$base" "$dir" /etc/systemd/system; do
    [[ -d $p ]] || die "目录结构不完整：$p。"
    safe_path "$p"
done
[[ -f $dir/.installer-owner ]] || die '缺少项目归属记录，未删除。'
safe_path "$dir/.installer-owner"
mapfile -t manifest <"$dir/.installer-owner"
pattern='^([1-9][0-9]*) ([1-9][0-9]*)$'
[[ ${#manifest[@]} == 2 && ${manifest[0]} == "$owner" && ${manifest[1]} =~ $pattern ]] ||
    die '项目归属记录无效。'
uid=${BASH_REMATCH[1]} gid=${BASH_REMATCH[2]}
shopt -s nullglob dotglob
for p in "$dir"/*; do
    case $role:${p##*/} in
        frps:frps|frpc:frpc|frps:frps.toml|frpc:frpc.toml|frps:server.crt|frps:server.key|frps:token.txt|frpc:ca.crt|*:.installer-owner)
            [[ -f $p ]] || die "项目路径不是普通文件：$p。"
            safe_path "$p" ;;
        *) die "存在非项目文件 $p，请备份移走后重试。" ;;
    esac
done
if exists "$unit_path"; then
    [[ -f $unit_path ]] || die '当前 unit 不是项目普通文件。'
    safe_path "$unit_path"
    IFS= read -r tag <"$unit_path"
    [[ $tag == "# $owner" ]] || die '当前 unit 不属于本模块。'
    fragment=$(systemctl show -p FragmentPath --value "$unit")
    [[ -z $fragment || $fragment == "$unit_path" ]] || die 'systemd 载入了其他 unit。'
    [[ -z $(systemctl show -p DropInPaths --value "$unit") ]] || die '存在其他覆盖配置，请人工处理。'
else
    [[ $(systemctl show -p LoadState --value "$unit") == not-found ]] || die '发现其他同名服务。'
fi
user_present=0 group_present=0
if getent passwd "$account" >/dev/null; then
    grep -q "^$account:" /etc/passwd &&
        [[ $(id -u "$account") == "$uid" && $(id -g "$account") == "$gid" ]] ||
        die '现有账号 UID/GID 不匹配，未删除。'
    user_present=1
else [[ $? == 2 ]] || die '无法读取账号信息。'; fi
if group_line=$(getent group "$account"); then
    grep -q "^$account:" /etc/group || die '现有组不属于本机。'
    IFS=: read -r _ _ actual members <<< "$group_line"
    passwd=$(getent passwd)
    [[ $actual == "$gid" && ( -z $members || $members == "$account" ) ]] || die '组已更改或有其他成员。'
    if awk -F: -v gid="$gid" -v user="$account" '$4==gid && $1!=user {x=1} END{exit !x}' <<< "$passwd"; then
        die '其他账号正在使用此组。'
    fi
    group_present=1
else [[ $? == 2 ]] || die '无法读取组信息。'; fi
printf '将停止并删除 %s 的程序、项目配置、证书及专用账号，不影响另一角色。\n' "$role" >&2
if (( ! yes )); then
    read -r -p '请输入 yes 确认：' reply </dev/tty || die '非交互环境请提供 --yes。'
    if [[ $reply != yes ]]; then printf '已取消。\n'; exit 0; fi
fi
if exists "$unit_path"; then
    if [[ -n $fragment ]]; then systemctl stop "$unit" || die '服务未停止，未移除项目文件。'; fi
    systemctl disable "$unit" >/dev/null || die '未能禁用服务自启。'
    if systemctl is-failed --quiet "$unit"; then systemctl reset-failed "$unit"; fi
    rm -- "$unit_path"
    systemctl daemon-reload
fi
if (( user_present )); then userdel "$account" || die '未能删除运行账号。'; fi
if (( group_present )) && grep -q "^$account:" /etc/group; then groupdel "$account" || die '未能删除专用组。'; fi
if [[ $role == frps ]]; then rm -f -- "$dir"/{frps,frps.toml,server.crt,server.key,token.txt}
else rm -f -- "$dir"/{frpc,frpc.toml,ca.crt}; fi
rm -- "$dir/.installer-owner"
rmdir -- "$dir"
if [[ ! -t 1 ]]; then green='' reset=''; fi
printf '%s%s 已卸载。%s\n' "$green" "$role" "$reset"
