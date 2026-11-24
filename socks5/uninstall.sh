#!/bin/bash
# 仅卸载本项目，保留系统软件包及共享网络调优。
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin
readonly BASE=/srv/net-services DIR=/srv/net-services/socks5 ACCOUNT=svc-3proxy-socks
readonly UNIT=/etc/systemd/system/socks5.service SERVICE=socks5.service
readonly LOCK=/run/3proxy-socks5-installer.lock OWNER=3proxy-socks5-installer/v1
readonly MARKER=$DIR/.installer-owner
yes=0
red='' yellow='' green='' reset=''
if [[ -t 2 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]] &&
   colors=$(tput colors 2>/dev/null) && [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
    red=$'\e[31m' yellow=$'\e[33m' green=$'\e[32m' reset=$'\e[0m'
fi
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
warn() { printf '%s警告：%s%s\n' "$yellow" "$*" "$reset" >&2; }
lexists() { [[ -e $1 || -L $1 ]]; }
usage() { printf '用法：sudo bash uninstall.sh [--yes]\n默认要求明确确认；--yes 表示确认卸载。\n'; }
safe_path() {
    local uid mode
    [[ ! -L $1 ]] || die "$1 是符号链接；拒绝卸载。"
    read -r uid mode < <(stat -c '%u %a' -- "$1")
    if [[ $uid != 0 ]] || (( (8#$mode & 022) != 0 )); then die "$1 的所有者或写入权限不安全。"; fi
}
main() {
    local manifest uid gid srv_created base_created tag entry actual group_gid members fragment passwd_entries
    case ${1:-} in
        '') [[ $# == 0 ]] || die '未知参数。' ;;
        --yes) [[ $# == 1 ]] || die '未知参数。'; yes=1 ;;
        --help) usage; return 0 ;;
        *) die '未知参数，请使用 --help。' ;;
    esac
    [[ $(uname -s) == Linux ]] || die '仅支持 Linux。'
    (( EUID == 0 )) || die '请使用 root 或 sudo 执行。'
    [[ -d /run/systemd/system && $(< /proc/1/comm) == systemd ]] || die '需要运行中的 systemd。'
    exec 9>"$LOCK"
    flock -n 9 || die '另一个安装或卸载进程正在运行。'
    if ! lexists "$DIR" && ! lexists "$UNIT"; then
        printf '未发现本项目安装，无需卸载。\n'
        return 0
    fi
    for entry in /srv "$BASE" "$DIR" /etc/systemd/system; do
        [[ -d $entry ]] || die "目录结构不完整：$entry；请人工检查。"
        safe_path "$entry"
    done
    [[ -f $MARKER ]] || die '没有本项目的归属记录；拒绝删除。'
    safe_path "$MARKER"
    mapfile -t manifest < "$MARKER"
    (( ${#manifest[@]} == 2 )) && [[ ${manifest[0]} == "$OWNER" &&
       ${manifest[1]} =~ ^([1-9][0-9]*)\ ([1-9][0-9]*)\ ([01])\ ([01])$ ]] ||
        die '归属记录无效，拒绝删除。'
    uid=${BASH_REMATCH[1]} gid=${BASH_REMATCH[2]}
    srv_created=${BASH_REMATCH[3]} base_created=${BASH_REMATCH[4]}
    shopt -s dotglob nullglob
    for entry in "$DIR"/*; do
        case ${entry##*/} in
            3proxy|3proxy.cfg|connection.txt|.installer-owner)
                [[ -f $entry ]] || die "非普通文件：$entry；拒绝卸载。"
                safe_path "$entry" ;;
            *) die "安装目录有非项目文件：$entry；请备份或移走后重试。" ;;
        esac
    done
    if lexists "$UNIT"; then
        [[ -f $UNIT ]] || die '同名服务不是普通文件，拒绝删除。'
        safe_path "$UNIT"
        IFS= read -r tag < "$UNIT"
        [[ $tag == "# $OWNER" ]] || die '同名服务不属于本项目，拒绝删除。'
        fragment=$(systemctl show -p FragmentPath --value "$SERVICE")
        [[ -z $fragment || $fragment == "$UNIT" ]] || die '载入的是其他服务文件，拒绝操作。'
        [[ -z $(systemctl show -p DropInPaths --value "$SERVICE") ]] ||
            die '检测到自定义 systemd 覆盖；请管理员处理后重试。'
    else
        [[ $(systemctl show -p LoadState --value "$SERVICE") == not-found ]] ||
            die '存在其他同名服务或尚未重新加载 systemd；拒绝操作。'
    fi
    actual=''
    if getent passwd "$ACCOUNT" >/dev/null; then
        grep -q "^$ACCOUNT:" /etc/passwd && [[ $(id -u "$ACCOUNT") == "$uid" && $(id -g "$ACCOUNT") == "$gid" ]] ||
            die '同名账号与本项目的本地 UID/GID 不符，拒绝删除。'
        actual=$ACCOUNT
    else [[ $? == 2 ]] || die '无法查询运行账号。'; fi
    entry=''
    if entry=$(getent group "$ACCOUNT"); then
        grep -q "^$ACCOUNT:" /etc/group || die '同名组不是本地组。'
        IFS=: read -r _ _ group_gid members <<< "$entry"
        [[ $group_gid == "$gid" && ( -z $members || $members == "$ACCOUNT" ) ]] ||
            die '同名组与原安装不符或另有成员，拒绝删除。'
        passwd_entries=$(getent passwd) || die '无法检查系统组是否由其他账号使用。'
        if awk -F: -v gid="$gid" -v user="$ACCOUNT" \
            '$4 == gid && $1 != user {found=1} END {exit !found}' <<< "$passwd_entries"; then
            die '其他账号正在使用此组，拒绝删除。'
        fi
    else [[ $? == 2 ]] || die '无法查询运行组。'; fi
    printf '将停止并删除 %s、专用系统账号及 %s 中的项目文件。\n' "$SERVICE" "$DIR" >&2
    printf '连接密码将被删除；保留 APT、共享依赖和全局 BBR/FQ 设置。\n' >&2
    if (( ! yes )); then
        read -r -p '确认卸载？请输入 yes：' tag </dev/tty || die '非交互环境请提供 --yes。'
        if [[ $tag != yes ]]; then printf '已取消卸载。\n'; return 0; fi
    fi
    trap 'die "卸载中断；可能已完成部分操作，检查后可重试。"' INT TERM HUP
    if lexists "$UNIT"; then
        if [[ -n $fragment ]]; then
            systemctl stop "$SERVICE" || die '停止 3proxy 失败，未删除项目文件。'
        fi
        systemctl disable "$SERVICE" >/dev/null || die '无法禁用开机自启。'
        if systemctl is-failed --quiet "$SERVICE"; then systemctl reset-failed "$SERVICE"; fi
        rm -- "$UNIT"
        systemctl daemon-reload || die '无法重新加载 systemd；请修复后重试卸载。'
    fi
    if [[ -n $actual ]]; then userdel "$ACCOUNT" || die '未能删除运行账号。'; fi
    if [[ -n $entry ]] && grep -q "^$ACCOUNT:" /etc/group; then
        groupdel "$ACCOUNT" || die '未能删除运行组。'
    fi
    rm -f -- "$DIR"/{3proxy,3proxy.cfg,connection.txt,.installer-owner}
    rmdir -- "$DIR"
    if (( base_created )); then rmdir -- "$BASE" 2>/dev/null || warn "$BASE 非空或不可删除，已保留。"; fi
    if (( srv_created )); then rmdir -- /srv 2>/dev/null || warn '/srv 非空或不可删除，已保留。'; fi
    if [[ ! -t 1 ]]; then green='' reset=''; fi
    printf '%sSOCKS5 代理已卸载。%s\n' "$green" "$reset"
}
trap 'die "卸载操作失败（行 $LINENO，退出码 $?）。请检查后重试。"' ERR
if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
