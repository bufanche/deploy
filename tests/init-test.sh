#!/usr/bin/env bash
# systemd、OpenRC 和系统防火墙这几条路径：普通容器里没有 init，要单独起带 init 的容器测
# 用法：tests/init-test.sh
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
SNAP=$(mktemp); cp deploy.sh "$SNAP"; chmod 644 "$SNAP"   # 测试期间改脚本不影响本次测试
FAIL=0
ARGS="--reality=21001 --hy2=21002 --ss=21005 --no-bbr"
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; FAIL=1; }

run_case() { # $1 名字  $2 镜像  $3 容器启动命令  $4 准备命令  $5 检查服务命令  $6 检查防火墙命令  $7 卸载后防火墙应为空的检查
  local name=bfc-init-$1
  echo "=== $1"
  docker rm -f $name >/dev/null 2>&1
  docker run -d --name $name --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -p 21001:21001/tcp -p 21002:21002/udp -p 21005:21005/tcp -p 21005:21005/udp \
    -v "$SNAP:/root/deploy.sh:ro" "$2" $3 >/dev/null || { bad "容器起不来"; return; }
  sleep 4
  docker exec $name sh -c "$4" >/dev/null 2>&1 || { bad "准备环境失败"; docker rm -f $name >/dev/null; return; }
  if ! docker exec $name sh /root/deploy.sh $ARGS > /tmp/$name.log 2>&1; then bad "安装失败"; tail -15 /tmp/$name.log; docker rm -f $name >/dev/null; return; fi
  docker exec $name sh -c "$5" && ok "服务由 init 管理且在运行" || bad "服务状态不对"
  [ -n "$6" ] && { docker exec $name sh -c "$6" && ok "防火墙已放行" || bad "防火墙没放行"; }
  docker exec $name cat /etc/bfc/client.json > /tmp/$name.client.json
  test_all_clients /tmp/$name.client.json || FAIL=1
  docker exec $name bfc restart >/dev/null 2>&1 && docker exec $name sh -c "$5" && ok "bfc restart" || bad "bfc restart"
  docker exec $name bfc uninstall -y >/dev/null 2>&1
  docker exec $name sh -c '[ ! -e /etc/bfc ] && [ ! -e /usr/local/bin/bfc ]' && ok "卸载干净" || bad "卸载有残留"
  [ -n "$7" ] && { docker exec $name sh -c "$7" && ok "防火墙规则已撤回" || bad "防火墙规则没撤回"; }
  docker rm -f $name >/dev/null
}

# 现成的 systemd 镜像大多没有 ARM 版，自己构建一个
docker build -q -t bfc-systemd-ubuntu - >/dev/null <<'EOF2'
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd systemd-sysv curl ufw iptables >/dev/null
CMD ["/sbin/init"]
EOF2
run_case systemd-ufw bfc-systemd-ubuntu "" \
  "ufw allow 22/tcp && ufw --force enable" \
  "systemctl is-active --quiet bfc && systemctl is-enabled --quiet bfc" \
  "ufw status | grep -q '21001/tcp' && ufw status | grep -q '21002/udp'" \
  "! ufw status | grep -q 2100"

run_case systemd-firewalld rockylinux/rockylinux:9-ubi-init "" \
  "dnf install -y -q firewalld && systemctl start firewalld" \
  "systemctl is-active --quiet bfc" \
  "firewall-cmd --list-ports | grep -q '21001/tcp'" \
  "! firewall-cmd --list-ports | grep -q 2100"

run_case openrc alpine:3.22 "sleep infinity" \
  "apk add --no-cache openrc curl && mkdir -p /run/openrc && touch /run/openrc/softlevel && openrc default" \
  "rc-service bfc status && rc-update show default | grep -q bfc" \
  "" ""

rm -f "$SNAP"
exit $FAIL
