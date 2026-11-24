#!/bin/bash
set -Eeuo pipefail
umask 077
export LC_ALL=C PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive
readonly src=/etc/apt/sources.list.d/linux-scripts-docker.sources key=/etc/apt/keyrings/linux-scripts-docker.asc
readonly state=/var/lib/linux-scripts-docker
readonly -a packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
yes=0 purge=0 allow_running=0 phrase='' tmp=''
red='' green='' reset=''
if [[ -t 2 && ! ${NO_COLOR+x} ]] && colors=$(tput colors 2>/dev/null) &&
   [[ $colors =~ ^[0-9]+$ ]] && (( colors >= 8 )); then
    red=$'\e[31m' green=$'\e[32m' reset=$'\e[0m'
fi
die() { printf '%s错误：%s%s\n' "$red" "$*" "$reset" >&2; exit 1; }
exists() { [[ -e $1 || -L $1 ]]; }
usage() {
    printf '%s\n' '用法：sudo bash uninstall.sh [--yes] [--allow-running] [--purge-data]' \
        '默认保留全部数据与配置；运行中容器默认阻止卸载。' \
        '--purge-data 另需在终端输入 DELETE-DEFAULT-DOCKER-DATA，不支持无终端删除。'
}
while (( $# )); do
    case $1 in
        --help) usage; exit 0 ;; --yes) yes=1 ;; --allow-running) allow_running=1 ;;
        --purge-data) purge=1 ;; *) die '未知选项，请使用 --help。' ;;
    esac
    shift
done
cleanup() {
    local rc=$?
    trap - EXIT ERR
    if [[ -n $tmp ]] && ! rm -f -- "$tmp"; then printf '警告：未能清理卸载日志。\n' >&2; fi
    exit "$rc"
}
trap cleanup EXIT
trap 'die "卸载未完成（行 $LINENO）；没有默认删除数据。"' ERR
trap 'die "卸载中断，请检查当前状态。"' HUP INT TERM
[[ $(uname -s) == Linux && $EUID == 0 ]] || die '请在 Linux 上使用 root 或 sudo。'
[[ -d /run/systemd/system && $(< /proc/1/comm) == systemd ]] || die '需要运行中的 systemd。'
for tool in apt-get dpkg-query systemctl flock grep awk sha256sum rm rmdir stat mktemp timeout; do
    command -v "$tool" >/dev/null || die "缺少必要命令 $tool。"
done
exec 9>/run/linux-scripts-docker.lock
flock -n 9 || die '另一个 Docker 安装或卸载正在运行。'
if ! exists "$state"; then printf '未发现由本模块管理的 Docker 安装；不操作其他环境。\n'; exit 0; fi
[[ -d $state && ! -L $state ]] || die '归属目录不安全。'
for file in "$state" "$state/sources.sha256" "$src" "$key"; do
    [[ ! -L $file && -e $file ]] || die '归属记录、软件源或公钥不存在或为链接。'
    read -r uid mode < <(stat -c '%u %a' "$file")
    if [[ $uid != 0 ]] || (( (8#$mode & 022) != 0 )); then die "权限不安全：$file。"; fi
done
[[ -f $state/sources.sha256 && -f $src && -f $key ]] || die '归属文件格式错误。'
[[ $(sha256sum "$src" "$key") == "$(< "$state/sources.sha256")" ]] ||
    die '软件源或公钥已由管理员修改，拒绝自动移除。'
shopt -s dotglob nullglob
files=("$state"/*)
(( ${#files[@]} == 1 )) || die '归属目录中有其他文件，请先人工检查。'
local_docker() { timeout -k 5 35 docker --host unix:///var/run/docker.sock "$@"; }
count() { awk 'NF{n++} END{print n+0}'; }
if [[ -S /var/run/docker.sock ]] && systemctl is-active --quiet docker.service; then
    running=$(local_docker ps -q | count) || die '无法检查运行中的容器。'
    all=$(local_docker ps -aq | count) || die '无法检查全部容器。'
    images=$(local_docker image ls -aq --no-trunc | awk 'NF&&!seen[$0]++{n++} END{print n+0}') ||
        die '无法检查镜像。'
    volumes=$(local_docker volume ls -q | count) || die '无法检查卷。'
    networks=$(local_docker network ls -q | count) || die '无法检查网络。'
    printf '容器：运行中 %s，未运行 %s；镜像：%s；卷：%s；网络：%s（含内置网络）。\n' \
        "$running" "$((all-running))" "$images" "$volumes" "$networks"
    if (( running && ! allow_running )); then die '有运行中容器；请先停止，或明确使用 --allow-running 接受中断。'; fi
else
    engine=$(dpkg-query -W -f='${db:Status-Status}' docker-ce 2>/dev/null) || engine=''
    if [[ $engine == installed ]]; then die 'Docker 未运行，无法清点容器和数据；请先启动服务再卸载。'; fi
    (( ! purge )) || die '无法运行 Docker 清点，不允许销毁数据。'
fi
if (( purge )); then
    [[ ${running:-0} == 0 ]] || die '销毁数据前请先停止所有容器。'
    [[ $(local_docker info --format '{{.DockerRootDir}}') == /var/lib/docker ]] ||
        die '发现自定义 Docker 数据目录，不允许自动删除。'
    for unit in docker.service containerd.service; do
        [[ -z $(systemctl show -p DropInPaths --value "$unit") ]] || die '发现自定义 unit 设置，不允许自动删除数据。'
    done
    for tool in ctr findmnt containerd; do
        command -v "$tool" >/dev/null || die "缺少 $tool，无法验证数据归属。"
    done
    config=$(timeout 10 containerd config dump) || die '无法读取 containerd 默认配置路径。'
    grep -Fxq "root = '/var/lib/containerd'" <<< "$config" ||
        die 'containerd 有自定义数据目录或无法验证，只允许保留数据卸载。'
    namespaces=$(timeout 10 ctr --address /run/containerd/containerd.sock namespaces list -q) ||
        die '无法清点 containerd 命名空间。'
    if grep -Eqv '^(moby|plugins\.moby|)$' <<< "$namespaces"; then die 'containerd 有其他命名空间，拒绝删除。'; fi
    verify_data_paths() {
        local dir mounts
        for dir in /var/lib/docker /var/lib/containerd; do
            [[ -d $dir && ! -L $dir && $(stat -c %u "$dir") == 0 ]] || return 1
            mounts=$(findmnt -rn -o TARGET) || return 1
            if awk -v d="$dir" '$0==d || index($0,d"/")==1 { found=1 } END { exit !found }' <<< "$mounts"; then
                return 1
            fi
        done
    }
    verify_data_paths || die '默认数据目录含挂载或路径不安全，不允许删除。'
    printf '不可逆操作：将删除两个默认数据目录及其中的镜像、容器、卷。不会删除自定义目录。\n' >&2
    read -r -p '请输入 DELETE-DEFAULT-DOCKER-DATA 确认：' phrase </dev/tty || die '销毁数据必须在终端确认。'
    [[ $phrase == DELETE-DEFAULT-DOCKER-DATA ]] || die '未确认，未执行卸载。'
elif (( ! yes )); then
    printf '将停止并卸载 Docker 和 containerd；保留全部数据、配置及共享依赖。\n' >&2
    read -r -p '请输入 yes 确认：' phrase </dev/tty || die '非交互环境请提供 --yes。'
    if [[ $phrase != yes ]]; then printf '已取消。\n'; exit 0; fi
fi
opts=(-o DPkg::Lock::Timeout=15 --no-auto-remove)
present=()
for pkg in "${packages[@]}"; do
    status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null) || status=''
    case $status in ''|not-installed|config-files) ;; *) present+=("$pkg") ;; esac
done
if (( ${#present[@]} )); then
    plan=$(apt-get "${opts[@]}" -s remove "${present[@]}") || die '无法模拟卸载。'
    if grep -Eq '^Inst ' <<< "$plan"; then die '卸载会安装额外包，已停止。'; fi
    while read -r pkg; do
        [[ -z $pkg || " ${present[*]} " == *" ${pkg%%:*} "* ]] || die "卸载会影响其他包 $pkg，已停止。"
    done < <(awk '/^Remv /{print $2}' <<< "$plan")
    tmp=$(mktemp)
    apt-get "${opts[@]}" -y remove "${present[@]}" >"$tmp" 2>&1 ||
        die '卸载软件包失败；暂未删除软件源和数据。请检查 APT 锁和 dpkg 状态。'
fi
for unit in docker.service docker.socket containerd.service; do
    if systemctl is-active --quiet "$unit"; then die "$unit 仍在运行，保留归属记录和数据。"; fi
done
if (( purge )); then
    verify_data_paths || die '数据路径卸载后发生变化，已保留。'
    rm -rf --one-file-system -- /var/lib/docker /var/lib/containerd
fi
rm -- "$src" "$key" "$state/sources.sha256"
rmdir -- "$state"
if [[ ! -t 1 ]]; then green='' reset=''; fi
printf '%sDocker 已卸载。用户配置及共享依赖未删除。%s\n' "$green" "$reset"
