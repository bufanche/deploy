#!/usr/bin/env bash
# 真实 UFW / iptables 规则测试，必须在隔离网络命名空间内运行。
# docker run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" bfc-systemd-ubuntu bash /src/tests/firewall-test.sh
set -euo pipefail
[ -f /.dockerenv ] || { echo '请在隔离 Docker 容器运行'; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source <(sed '$d' "$ROOT/deploy.sh")
ufw --force enable >/dev/null 2>&1
for family in 4 6; do
  ufw --force reset >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
  any=0.0.0.0/0; [ "$family" = 4 ] || any=::/0
  ufw allow proto tcp from "$any" to "$any" port 24443 comment user-before >/dev/null
  defaults; PORT_reality=24443; fw_open_all
  [[ $FW_RULES != *ufw$family-owned:24443/tcp* ]]
  fw_close_all
  status=$(ufw status)
  grep -q user-before <<< "$status"
  [ "$(grep -c '24443/tcp' <<< "$status")" = 1 ]
  echo "PASS user IPv$family-only UFW rule survives add/remove"
done
ufw --force reset >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
ufw allow 24443/tcp comment user-before >/dev/null
defaults; PORT_reality=24443; fw_open_all
[ -z "$FW_RULES" ]; fw_close_all
[ "$(ufw status | grep -c user-before)" = 2 ]
echo 'PASS pre-existing dual-stack UFW rules remain unowned'
defaults; DOMAIN=example.com; PORT_hy2=24444
fw_open_all
ufw status | grep '80/tcp' >/dev/null
[[ $FW_RULES == *ufw4-owned:80/tcp* && $FW_RULES == *ufw6-owned:80/tcp* ]]
PORT_hy2=; PORT_reality=24443
fw_prune
if ufw status | grep -q '80/tcp'; then exit 1; fi
ufw status | grep user-before >/dev/null
echo 'PASS ACME80 is added for TLS and removed when no longer needed'
ufw --force disable >/dev/null 2>&1
iptables -P INPUT DROP; ip6tables -P INPUT DROP
# 即使存在相同端口的用户规则，bfc 的带标记规则也能独立撤回。
iptables -I INPUT -p tcp --dport 24443 -j ACCEPT
ip6tables -I INPUT -p tcp --dport 24443 -j ACCEPT
defaults; PORT_reality=24443
fw_open_all
[[ $FW_RULES == *iptables-owned:24443/tcp* && $FW_RULES == *ip6tables-owned:24443/tcp* ]]
fw_close_all
iptables -C INPUT -p tcp --dport 24443 -j ACCEPT
ip6tables -C INPUT -p tcp --dport 24443 -j ACCEPT
if iptables -S INPUT | grep -q -- '--comment bfc'; then exit 1; fi
if ip6tables -S INPUT | grep -q -- '--comment bfc'; then exit 1; fi
echo 'PASS iptables and ip6tables preserve user rules and remove only bfc rules'
