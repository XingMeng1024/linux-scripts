#!/bin/bash
# 不修改系统；覆盖模块结构、编码、参数、stdin 及基础保护。
set -euo pipefail
cd "$(dirname "$0")/.."
for module in socks5 bbr docker frp; do
    [[ -s $module/README.md ]]
    for action in install uninstall; do
        file=$module/$action.sh
        [[ -s $file && -x $file ]]
        bash "$file" --help >/dev/null
        bash -s -- --help <"$file" >/dev/null
    done
done
for file in README.md LICENSE .gitignore .gitattributes .github/workflows/test.yml \
    */README.md */install.sh */uninstall.sh tests/*.sh tests/RESULTS.md; do
    [[ -s $file ]]
    iconv -f UTF-8 -t UTF-16LE <"$file" | wc -c >/dev/null
    if grep -q $'\r' "$file"; then printf '非 LF 换行：%s\n' "$file" >&2; exit 1; fi
    [[ -z $(tail -c 1 "$file") ]]
    if [[ $file == *.sh ]]; then bash -n "$file"; fi
done
reject() {
    local needle=$1 script=$2 output
    shift 2
    if output=$(NO_COLOR=1 bash "$script" "$@" 2>&1); then printf '意外成功：%s\n' "$script" >&2; exit 1; fi
    if [[ $output != *"$needle"* || $output == *$'\e'* ]]; then printf '%s\n' "$output" >&2; exit 1; fi
}
for port in 0 1023 65536 021080 '21080;id' '1+21080' "\$(id)"; do
    reject '端口必须' socks5/install.sh --port "$port"
done
for name in 'bad name' 'x:CL:y' 'x,y' '-bad' $'test\nend'; do
    reject '用户名格式不正确' socks5/install.sh --username "$name"
done
for host in 256.0.0.1 1.1.1.01 'https://example.com' 'x..com' '-x.example.com' 'x.example-' \
    '*.example.com' '::1' 'x.example.com&port=80' $'x.example.com\nend'; do
    reject '入站地址必须' socks5/install.sh --public-ip "$host"
done
reject '缺少参数' socks5/install.sh --port
reject '未知选项' socks5/install.sh --password secret
reject '来源必须' socks5/install.sh --allow-source 'x;id'
reject 'CIDR 前缀' socks5/install.sh --allow-source '192.0.2.0/0'
reject 'CIDR 前缀' socks5/install.sh --allow-source '192.0.2.0/33'
reject '未知选项' bbr/install.sh --bogus
reject '未知选项' bbr/uninstall.sh --purge
reject '未知选项' docker/install.sh --upgrade
reject '数据目录必须' docker/install.sh --data-root /mnt/../etc/evil
reject '镜像服务地址必须' docker/install.sh --registry-mirror 'https://a.com";id'
reject '端口超出' docker/install.sh --registry-mirror https://a.com:99999
reject '必须对齐' docker/install.sh --address-pool 10.66.0.1/16 --pool-size 24
reject '仅接受 RFC 1918' docker/install.sh --address-pool 8.8.0.0/16 --pool-size 24
reject '未知选项' docker/uninstall.sh --force
reject '请选择' frp/install.sh
reject '只能指定一个角色' frp/install.sh --server --client
reject '控制端口必须' frp/install.sh --server --port 22
reject '不能与控制端口相同' frp/install.sh --server --remote-port 7000
reject '不接受客户端' frp/install.sh --server --token-file /dev/null
reject 'TLS 证书名称' frp/install.sh --server --tls-name $'a.example.com\nb'
reject '服务端地址非法' frp/install.sh --client --server-addr 'x";id'
reject '映射协议仅支持' frp/install.sh --client --protocol ssh
reject '未知选项' frp/install.sh --token secret
reject '请选择' frp/uninstall.sh --yes
if [[ $(uname -s) != Linux ]]; then
    reject '只支持 Debian/Ubuntu Linux' socks5/install.sh --port 1024 --username A_0-x --public-ip a-b.example.com
    reject '仅支持 Debian/Ubuntu Linux' bbr/install.sh
    reject '仅支持 Debian/Ubuntu Linux' docker/install.sh
    reject '仅支持 Debian/Ubuntu Linux' frp/install.sh --server
else
    if (( EUID != 0 )); then
        reject '请使用 root' socks5/install.sh --port 65535 --public-ip 203.0.113.10
        reject '请使用 root' bbr/install.sh
        reject '请使用 root' docker/install.sh
        reject '请使用 root' frp/install.sh --server
    fi
fi
printf '结构、编码、Bash 语法、stdin 和参数保护测试通过。\n'
