#!/usr/bin/env bash
# 在 Docker 里装一遍，再用本机 sing-box 当客户端逐个协议连通测试
# 用法：tests/docker-test.sh debian:12 [更多镜像...]
# 需要：docker、本机 sing-box（客户端）、jq、curl
set -uo pipefail
cd "$(dirname "$0")/.."
. tests/lib.sh
SNAP=$(mktemp); cp deploy.sh "$SNAP"; chmod 644 "$SNAP"   # 测试期间改脚本不影响本次测试

ALL="--reality=21001 --hy2=21002 --tuic=21003 --anytls=21004 --ss=21005 --shadowtls=21006 --trojan=21007 --vmess=21008 --hysteria=21009 --snell=21010 --socks=21011"
FAIL=0

prep_cmd() { # 各发行版容器里装上运行脚本最少要的东西
  case $1 in
    alpine*) echo "apk add --no-cache curl >/dev/null" ;;
    debian*|ubuntu*) echo "apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null" ;;
    *) echo "true" ;;
  esac
}

for img in "$@"; do
  name=bfc-test-$(echo "$img" | tr ':/.' '---')
  echo "=== $img"
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" --platform "${PLATFORM:-linux/amd64}" \
    -p 21001-21011:21001-21011/tcp -p 21001-21011:21001-21011/udp \
    -v "$SNAP:/root/deploy.sh:ro" "$img" sleep infinity >/dev/null || { FAIL=1; continue; }
  docker exec "$name" sh -c "$(prep_cmd "$img")"
  if ! docker exec "$name" sh /root/deploy.sh $ALL --no-bbr > "/tmp/$name.log" 2>&1; then
    echo "安装失败："; tail -20 "/tmp/$name.log"; FAIL=1; docker rm -f "$name" >/dev/null; continue
  fi
  echo "安装成功"
  docker exec "$name" cat /etc/bfc/client.json > "/tmp/$name.client.json"
  test_all_clients "/tmp/$name.client.json" || FAIL=1
  # 管理命令：删一个、加回来、重跑同一条命令链接不变
  before=$(docker exec "$name" cat /etc/bfc/links.txt)
  docker exec "$name" bfc del socks >/dev/null 2>&1 && docker exec "$name" grep -q socks5 /etc/bfc/links.txt && { echo "  ✗ bfc del"; FAIL=1; }
  docker exec "$name" bfc add --socks=21011 >/dev/null 2>&1 || { echo "  ✗ bfc add"; FAIL=1; }
  docker exec "$name" sh /root/deploy.sh $ALL --no-bbr >/dev/null 2>&1
  [ "$before" = "$(docker exec "$name" cat /etc/bfc/links.txt)" ] && echo "  ✓ 重跑链接不变" || { echo "  ✗ 重跑后链接变了"; FAIL=1; }
  docker exec "$name" bfc uninstall -y >/dev/null 2>&1
  docker exec "$name" sh -c '[ ! -e /etc/bfc ] && [ ! -e /usr/local/bin/bfc-sing-box ]' && echo "  ✓ 卸载干净" || { echo "  ✗ 卸载有残留"; FAIL=1; }
  docker rm -f "$name" >/dev/null
done
rm -f "$SNAP"
exit $FAIL
