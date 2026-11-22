#!/usr/bin/env bash
# 隔离容器专项测试：需要 NET_ADMIN、bash、curl 和 BusyBox nc。
# docker run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" alpine:3.22 sh -c 'apk add --no-cache bash curl >/dev/null && bash /src/tests/safety-test.sh'
set -euo pipefail
[ -f /.dockerenv ] || { echo '请在隔离 Docker 容器运行'; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
SCRIPT=$scratch/deploy.sh
cp "$ROOT/deploy.sh" "$SCRIPT"
pass(){ echo "PASS $*"; }
proxy_get(){
  local pass
  pass=$(bash -c 'source /etc/bfc/state; printf %s "$PASS"')
  curl --noproxy '' -fsS --max-time 15 -x "socks5h://bufanche:$pass@127.0.0.1:21011" "$1"
}
unchanged(){
  sha256sum /etc/bfc/config.json /etc/bfc/state /etc/bfc/links.txt /usr/local/bin/bfc /usr/local/bin/bfc-sing-box > "$scratch/after"
  cmp "$scratch/before" "$scratch/after"
  kill -0 "$(cat /run/bfc.pid)"
}
expect_failure(){
  if "$@" > "$scratch/failure.log" 2>&1; then echo 'FAIL expected nonzero exit'; exit 1; fi
  unchanged
}
make_variant(){ sed '$d' "$SCRIPT" > "$1"; cat >> "$1"; }
ip addr add 93.184.215.14/32 dev lo
ip -6 addr add 2001:4860:ffff::1/128 dev lo
printf '\n93.184.215.14 bfc-self.test\n' >> /etc/hosts
bash "$SCRIPT" --socks=21011 --ss=21005 --no-bbr > "$scratch/install.log" 2>&1 || { cat "$scratch/install.log"; exit 1; }
pass 'installation with current script'
sha256sum /etc/bfc/config.json /etc/bfc/state /etc/bfc/links.txt /usr/local/bin/bfc /usr/local/bin/bfc-sing-box > "$scratch/before"
oldpid=$(cat /run/bfc.pid)
bash "$SCRIPT" --socks=21011 --ss=21005 --dry-run > /dev/null
bfc add --hy2=21002 --dry-run > /dev/null
unchanged; [ "$(cat /run/bfc.pid)" = "$oldpid" ]
pass 'real dry-run preserves running PID and all configuration files'
expect_failure bfc add --naive
pass 'missing domain failure restores original service'
expect_failure bfc add --anytls=21005
pass 'port conflict restores original service'
make_variant "$scratch/config-fail.sh" <<'VARIANT'
write_config(){ echo corrupt > "$CONF"; die 'injected config failure'; }
main "$@"
VARIANT
expect_failure bash "$scratch/config-fail.sh" add --hy2=21002
pass 'config failure restores configuration, state, links and executable files'
make_variant "$scratch/output-fail.sh" <<'VARIANT'
write_outputs(){ echo corrupt > "$DIR/links.txt"; die 'injected output failure'; }
main "$@"
VARIANT
expect_failure bash "$scratch/output-fail.sh" add --hy2=21002
pass 'output failure restores original links and service'
make_variant "$scratch/start-fail.sh" <<'VARIANT'
eval "$(declare -f svc_start | sed '1s/svc_start/original_svc_start/')"
svc_start(){ if grep -q hysteria2 "$CONF"; then die 'injected start failure'; fi; original_svc_start; }
main "$@"
VARIANT
expect_failure bash "$scratch/start-fail.sh" add --hy2=21002
pass 'startup failure restores and restarts original service'
make_variant "$scratch/ipv6-fail.sh" <<'VARIANT'
public_ip(){ [ "$1" != 4 ] || echo 203.0.113.1; return 0; }
main "$@"
VARIANT
expect_failure bash "$scratch/ipv6-fail.sh" --socks=21011 --ss=21005 --ipv6 --no-bbr
pass 'requested unavailable IPv6 fails without changing the installation'
make_variant "$scratch/new-bad.sh" <<'VARIANT'
install_singbox(){ echo corrupt > "$BIN"; }
write_config(){ die 'injected updated binary/config incompatibility'; }
main "$@"
VARIANT
make_variant "$scratch/updater.sh" <<'VARIANT'
SCRIPT_URL=$1; SCRIPT_URL_BACKUP=$1
do_update
VARIANT
expect_failure bash "$scratch/updater.sh" "file://$scratch/new-bad.sh"
pass 'failed update restores old binary and keeps old management script'
bash "$scratch/updater.sh" "file://$SCRIPT" > "$scratch/update.log" 2>&1 || { cat "$scratch/update.log"; exit 1; }
unchanged
pass 'successful update preserves node links and credentials'
# 先验证目标 HTTP 服务确实可访问，再从代理访问同一地址。
for target in 93.184.215.14 2001:4860:ffff::1; do
  (
    while :; do
      printf 'HTTP/1.1 200 OK\r\nContent-Length: 18\r\nConnection: close\r\n\r\nlocal-admin-marker' | nc -l -s "$target" -p 18080 > /dev/null || true
    done
  ) &
done
sleep 0.3
[ "$(curl --noproxy '' -g -fsS --max-time 5 http://93.184.215.14:18080/)" = local-admin-marker ]
[ "$(curl --noproxy '' -g -fsS --max-time 5 'http://[2001:4860:ffff::1]:18080/')" = local-admin-marker ]
for target in 127.0.0.1 93.184.215.14 '[::ffff:93.184.215.14]' '[2001:4860:ffff::1]' bfc-self.test; do
  if proxy_get "http://$target:18080/" > "$scratch/proxy.log" 2>&1; then echo "FAIL proxy reached local service via $target"; exit 1; fi
  pass "proxy blocks local destination $target"
done
proxy_get https://www.cloudflare.com/cdn-cgi/trace | grep '^ip=' >/dev/null
pass 'ordinary external HTTPS still works through the proxy'
# Alpine 自带 crontab，更新、重跑之后仍只能有一条 bfc 开机项。
[ "$(crontab -l | grep -c '# bfc-managed$')" = 1 ]
pass 'actual crontab remains deduplicated after update'
bfc uninstall -y > /dev/null
[ ! -e /etc/bfc ]; [ ! -e /usr/local/bin/bfc ]; [ ! -e /run/bfc.pid ]
if crontab -l 2>/dev/null | grep -q bfc-managed; then exit 1; fi
pass 'uninstall removes node files and its own crontab entry'
