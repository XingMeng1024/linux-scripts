#!/bin/bash
# 仅限可丢弃且无 FRP 的 systemd VM。
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
[[ ${1:-} == --disposable-vm && $EUID == 0 && $(< /proc/1/comm) == systemd ]]
dir=/srv/net-services/frp
[[ ! -e $dir/frps && ! -e $dir/frpc ]]
tmp=$(mktemp -d)
backend=''
cleanup() {
    if [[ -n $backend ]]; then kill "$backend" 2>/dev/null || :; wait "$backend" 2>/dev/null || :; fi
    if [[ -e $dir/frpc/.installer-owner ]]; then bash frp/uninstall.sh --client --yes >&2 || :; fi
    if [[ -e $dir/frps/.installer-owner ]]; then bash frp/uninstall.sh --server --yes >&2 || :; fi
    rm -f -- "$tmp"/{negative.toml,probe.log}
    rmdir -- "$tmp"
}
trap cleanup EXIT
# shellcheck disable=SC2016
systemd-socket-activate --inetd --accept -l 127.0.0.1:18080 /bin/bash -c '
    while IFS= read -r line && [[ $line != $'\''\r'\'' ]]; do :; done
    printf "HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nfrp-probe"
' >"$tmp/probe.log" 2>&1 &
backend=$!
for (( n=0; n<40; n++ )); do
    if grep -q 'Listening on' "$tmp/probe.log"; then break; fi
    sleep 0.1
done
grep -q 'Listening on' "$tmp/probe.log"
cat frp/install.sh | bash -s -- --server
args=(--client --server-addr 127.0.0.1 --local-port 18080 --tls-ca "$dir/frps/server.crt")
bash frp/install.sh "${args[@]}" --token-file "$dir/frps/token.txt"
[[ $(curl -q --noproxy '*' --fail --silent --max-time 8 http://127.0.0.1:17000/) == frp-probe ]]
systemctl is-enabled --quiet frps.service
systemctl is-enabled --quiet frpc.service
[[ $(stat -c '%a' "$dir/frps/token.txt") == 600 ]]
# 使用已校验并安装的客户端做负向探针，避免每个用例重新下载归档。
negative() {
    local edit=$1 expected=$2 output rc=0
    sed "$edit" "$dir/frpc/frpc.toml" >"$tmp/negative.toml"
    output=$(timeout -k 2 7 "$dir/frpc/frpc" -c "$tmp/negative.toml" 2>&1) || rc=$?
    (( rc != 0 ))
    [[ $output == *"$expected"* ]]
}
negative 's/^auth\.token = .*/auth.token = "invalid-token-for-disposable-frp-test"/' \
    "token in login doesn't match"
negative 's/^transport\.tls\.serverName = .*/transport.tls.serverName = "wrong.example"/' \
    'certificate is valid for frps.local, not wrong.example'
negative 's/^remotePort = .*/remotePort = 17001/; s/^name = .*/name = "unauthorized-port"/' 'port not allowed'
[[ -z $(ss -H -ltn 'sport = :17001') ]]
bash frp/uninstall.sh --client --yes
systemctl is-active --quiet frps.service
[[ -f $dir/frps/frps.toml && ! -e $dir/frpc ]]
bash frp/uninstall.sh --server --yes
[[ ! -e $dir/frps && ! -e $dir/frpc ]]
printf 'FRP TLS、口令、允许端口、真实 TCP 转发及角色独立卸载测试通过。\n'
