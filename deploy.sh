#!/bin/sh
# 不翻车一键部署 sing-box 节点
# 网页生成命令：https://bufanche.com/tools/deploy/
# 源码：https://github.com/bufanche/deploy （MIT 许可）
#
# 用法：sh deploy.sh [选项]     装好以后输入 bfc 管理
#       sh deploy.sh --help     查看全部选项

# 这一段用 POSIX sh 写，保证 Alpine 这类默认没有 bash 的系统也能先跑起来
if [ -z "${BASH_VERSION:-}" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    for arg in "$@"; do
      if [ "$arg" = --dry-run ]; then echo "预览需要 bash；请先手动安装 bash，本次没有改动系统" >&2; exit 1; fi
    done
    echo "正在安装 bash ..."
    if command -v apk >/dev/null 2>&1; then apk add --no-cache bash >/dev/null
    elif command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get install -y -qq bash >/dev/null
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q bash
    elif command -v yum >/dev/null 2>&1; then yum install -y -q bash
    else echo "找不到 bash，请先手动安装 bash 再运行"; exit 1; fi
  fi
  exec bash "$0" "$@"
fi

set -uo pipefail

SCRIPT_VERSION="1.0.1"
SB_VERSION="1.14.4"
# sing-box 官方发布的 musl 静态版（所有发行版通用），sha256 由本项目下载后核对写入
declare -A SB_SHA256=(
  [amd64]=8f7c5f0651238850d96a0e488e5473cd77ec1a0098f63942e943f475a12057ca
  [arm64]=b95e25f921dc5e17a4cf13327243d1177642c7e35425bf5372862c477c359f56
  [armv7]=27c225479cd675e6d9b43e3e293c00ace72b693781c4a25b5c0de313d8c712df
)
SCRIPT_URL="https://bufanche.com/deploy.sh"
SCRIPT_URL_BACKUP="https://raw.githubusercontent.com/bufanche/deploy/main/deploy.sh"

DIR=/etc/bfc
STATE=$DIR/state
CONF=$DIR/config.json
BIN=/usr/local/bin/bfc-sing-box
CMD=/usr/local/bin/bfc
LOG=/var/log/bfc.log
SYSCTL_FILE=/etc/sysctl.d/99-bfc.conf
SWAP_FILE=/bfc.swap

# 协议：标识、显示名、网络类型
PROTOS=(reality hy2 tuic anytls ss shadowtls trojan vmess naive hysteria snell socks argo)
declare -A P_NAME=(
  [reality]="VLESS-REALITY" [hy2]="Hysteria2" [tuic]="TUIC-v5" [anytls]="AnyTLS"
  [ss]="SS-2022" [shadowtls]="ShadowTLS-v3" [trojan]="Trojan" [vmess]="VMess-WS"
  [naive]="NaiveProxy" [hysteria]="Hysteria-v1" [snell]="Snell-v5" [socks]="SOCKS5" [argo]="Argo-VLESS"
)
declare -A P_NET=(
  [reality]=tcp [hy2]=udp [tuic]=udp [anytls]=tcp [ss]=both [shadowtls]=tcp [trojan]=tcp
  [vmess]=tcp [naive]=tcp [hysteria]=udp [snell]=tcp [socks]=both [argo]=local
)

# REALITY / ShadowTLS 默认握手网站：取自 bufanche.com/tools/reality/ 每周扫描结果，
# 都是 TLS 1.3 + H2 + X25519MLKEM768、不跳转、证书链不长的网站。每台机器随机选一个。
SNI_LIST=(www.nike.com www.sony.co.jp www.honda.co.jp www.nissan.co.jp www.agoda.com
  www.zara.com www.walmart.com www.starbucks.com www.dailymotion.com www.costco.com)

# ---------- 输出 ----------
if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'; else R= G= Y= B= D= N=; fi
info() { echo "${G}▸${N} $*"; }
warn() { echo "${Y}! $*${N}" >&2; }
die()  { echo "${R}✗ $*${N}" >&2; exit 1; }
step() { echo; echo "${B}$*${N}"; }
banner() { # 窗口不到 68 列时只显示一行字，免得折行
  local cols; cols=$(tput cols 2>/dev/null || echo 80)
  if [ "${cols:-80}" -ge 68 ]; then
    printf '%s' "$G"; printf '%s\n' \
'██████╗ ██╗   ██╗███████╗ █████╗ ███╗   ██╗ ██████╗██╗  ██╗███████╗' \
'██╔══██╗██║   ██║██╔════╝██╔══██╗████╗  ██║██╔════╝██║  ██║██╔════╝' \
'██████╔╝██║   ██║█████╗  ███████║██╔██╗ ██║██║     ███████║█████╗  ' \
'██╔══██╗██║   ██║██╔══╝  ██╔══██║██║╚██╗██║██║     ██╔══██║██╔══╝  ' \
'██████╔╝╚██████╔╝██║     ██║  ██║██║ ╚████║╚██████╗██║  ██║███████╗' \
'╚═════╝  ╚═════╝ ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝ ╚═════╝╚═╝  ╚═╝╚══════╝'; printf '%s' "$N"
    echo "           ${B}不翻车一键部署 v$SCRIPT_VERSION${N} · bufanche.com"
  else
    echo "${G}${B}不翻车一键部署 v$SCRIPT_VERSION${N} · bufanche.com"
  fi
}

usage() {
  cat <<EOF
不翻车一键部署 v$SCRIPT_VERSION（sing-box $SB_VERSION）
网页版选项说明：https://bufanche.com/tools/deploy/

安装：sh deploy.sh [协议] [选项]
  不带协议参数时，默认装 VLESS-REALITY（TCP 443）+ Hysteria2（UDP 443）

协议（后面加 =端口 可指定端口，不写就自动选）：
  --reality    VLESS + Vision + REALITY，不需要域名，首选
  --hy2        Hysteria2，基于 UDP，速度快
  --tuic       TUIC v5，基于 UDP
  --anytls     AnyTLS
  --ss         Shadowsocks 2022
  --shadowtls  ShadowTLS v3（套在 SS 2022 外面）
  --trojan     Trojan + TLS
  --vmess      VMess + WebSocket（有域名时自动加 TLS）
  --naive      NaiveProxy，必须配 --domain
  --hysteria   Hysteria v1（老客户端兼容用）
  --snell      Snell v5（Surge 用）
  --socks      SOCKS5（带用户名密码，不建议直接用来翻墙）
  --argo-token=令牌 --argo-domain=域名
               Cloudflare 隧道（VLESS + WS），令牌在 Cloudflare Zero Trust 后台创建隧道时获得

选项：
  --domain=域名      已解析到本机的域名，自动申请证书（需要 80 端口空闲）；不填就用自签证书
  --email=邮箱       申请证书时留的邮箱，可不填
  --sni=网站         REALITY / ShadowTLS 握手网站，默认从内置名单随机选
  --hy2-obfs=类型    Hysteria2 混淆：salamander 或 gecko（gecko 需要 sing-box 1.14 以上客户端）
  --name=名字        节点名前缀，默认 bufanche
  --ipv6             链接里用 IPv6 地址
  --no-bbr           不开启 BBR
  --tune=带宽,延迟   按带宽（Mbps）和到国内的延迟（毫秒）调整 TCP 缓冲区，例如 --tune=1000,180
  --swap=大小        没有 swap 时创建 swap，单位 MB，例如 --swap=1024
  --dry-run          只列出会做什么，不改动系统
  -y                 卸载时不再确认

装好以后：
  bfc            打开管理菜单
  bfc info       查看节点链接        bfc qr        显示二维码
  bfc add --tuic 增加协议            bfc del tuic  删除协议
  bfc restart    重启                bfc log       看日志
  bfc update     更新脚本和 sing-box bfc uninstall 卸载
EOF
}

# ---------- 系统检测 ----------
need_root() { [ "$(id -u)" = 0 ] || die "请用 root 运行：先输入 sudo -i 回车，再粘贴命令"; }

detect_os() {
  OS_ID=unknown; OS_NAME=Linux
  if [ -r /etc/os-release ]; then . /etc/os-release; OS_ID=${ID:-unknown}; OS_NAME=${PRETTY_NAME:-$OS_ID}; fi
  if command -v apt-get >/dev/null; then PM=apt
  elif command -v dnf >/dev/null; then PM=dnf
  elif command -v yum >/dev/null; then PM=yum
  elif command -v apk >/dev/null; then PM=apk
  else PM=none; fi
  if [ -d /run/systemd/system ]; then INIT=systemd
  elif command -v openrc-run >/dev/null || [ -x /sbin/openrc-run ]; then INIT=openrc
  else INIT=none; fi
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    armv7*|armv8l) ARCH=armv7 ;;
    *) die "暂不支持这个 CPU 架构：$(uname -m)（支持 x86_64、arm64、armv7）" ;;
  esac
  # 容器类 VPS（OpenVZ、LXC）改不了内核参数，也加不了 swap
  VIRT=kvm
  if [ -e /proc/user_beancounters ] || [ -d /proc/vz ]; then VIRT=openvz
  elif grep -qa 'container=' /proc/1/environ 2>/dev/null || [ -f /.dockerenv ]; then VIRT=container
  elif command -v systemd-detect-virt >/dev/null; then
    case "$(systemd-detect-virt -c 2>/dev/null)" in lxc*|openvz|docker|podman) VIRT=container ;; esac
  fi
}

pkg_install() {
  case $PM in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1; } ;;
    dnf) dnf install -y -q "$@" >/dev/null 2>&1 ;;
    yum) yum install -y -q "$@" >/dev/null 2>&1 ;;
    apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

install_deps() {
  local need=()
  command -v curl >/dev/null || need+=(curl)
  command -v tar >/dev/null || need+=(tar)
  if ! command -v ip >/dev/null; then
    case $PM in dnf|yum) need+=(iproute) ;; *) need+=(iproute2) ;; esac
  fi
  [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] || need+=(ca-certificates)
  if [ ${#need[@]} -gt 0 ]; then
    info "安装依赖：${need[*]}"
    pkg_install "${need[@]}" || die "依赖安装失败，请手动安装：${need[*]}（系统太老、已停止维护时软件源会失效，建议重装成 Debian 12 或 Ubuntu 24.04）"
  fi
  # 二维码是锦上添花，装不上不影响使用
  if ! command -v qrencode >/dev/null; then
    case $PM in apk) pkg_install libqrencode-tools ;; *) pkg_install qrencode ;; esac || true
  fi
}

# ---------- 端口 ----------
# 直接读 /proc/net，不依赖 ss / netstat，精简系统也能用
port_used() {
  local port=$1 net=$2 hex f
  hex=$(printf '%04X' "$port")
  if [ "$net" != udp ]; then
    for f in /proc/net/tcp /proc/net/tcp6; do
      [ -r $f ] && awk -v p=":$hex" 'NR>1 && $4=="0A" && substr($2,length($2)-4)==p {found=1} END{exit !found}' $f && return 0
    done
  fi
  if [ "$net" != tcp ]; then
    for f in /proc/net/udp /proc/net/udp6; do
      [ -r $f ] && awk -v p=":$hex" 'NR>1 && substr($2,length($2)-4)==p {found=1} END{exit !found}' $f && return 0
    done
  fi
  return 1
}

declare -A TAKEN=() OWN_LISTENERS=()
remember_listeners() {
  local p port n net
  OWN_LISTENERS=()
  svc_active 2>/dev/null || return 0
  for p in $(enabled_protos); do
    port=$(port_of "$p"); net=${P_NET[$p]}
    for n in tcp udp; do
      [ "$net" = "$n" ] || [ "$net" = both ] || continue
      OWN_LISTENERS[$port/$n]=1
    done
  done
  [ -n "$STLS_INNER" ] && OWN_LISTENERS[$STLS_INNER/tcp]=1
  [ -n "$ARGO_PORT" ] && OWN_LISTENERS[$ARGO_PORT/tcp]=1
  return 0
}
port_free() { # 端口没被别的程序占、也没分给本次的其他协议
  local port=$1 net=$2 n
  case $net in
    both) [ -z "${TAKEN[$port/tcp]:-}" ] && [ -z "${TAKEN[$port/udp]:-}" ] ;;
    *) [ -z "${TAKEN[$port/$net]:-}" ] ;;
  esac || return 1
  for n in tcp udp; do
    [ "$net" = "$n" ] || [ "$net" = both ] || continue
    if [ "${DRY_RUN:-0}" = 1 ] && [ -n "${OWN_LISTENERS[$port/$n]:-}" ]; then continue; fi
    port_used "$port" "$n" && return 1
  done
  return 0
}
take_port() {
  local port=$1 net=$2
  case $net in both) TAKEN[$port/tcp]=1; TAKEN[$port/udp]=1 ;; *) TAKEN[$port/$net]=1 ;; esac
}
random_port() {
  local net=$1 p i
  for i in $(seq 1 200); do
    p=$(( (RANDOM * 32768 + RANDOM) % 40000 + 20000 ))
    port_free $p "$net" && { echo $p; return; }
  done
  die "找不到空闲端口"
}

# ---------- 参数 ----------
valid_port()   { [[ $1 =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }

# 解析协议和选项；ADD_MODE=1 时协议在原有基础上增加，否则替换为本次给出的协议
parse_flags() {
  local a k v proto_given=0
  declare -gA WANT=()
  for a in "$@"; do
    k=${a%%=*}; v=; [[ $a == *=* ]] && v=${a#*=}
    case $k in
      --reality|--hy2|--tuic|--anytls|--ss|--shadowtls|--trojan|--vmess|--naive|--hysteria|--snell|--socks)
        k=${k#--}; proto_given=1
        if [ -n "$v" ]; then valid_port "$v" || die "端口不对：$a"; WANT[$k]=$((10#$v)); else WANT[$k]=auto; fi ;;
      --argo-token) [[ $v =~ ^[A-Za-z0-9_=+/.-]{20,}$ ]] || die "Argo 令牌格式不对"; ARGO_TOKEN=$v; WANT[argo]=auto; proto_given=1 ;;
      --argo-domain) valid_domain "$v" || die "Argo 域名格式不对：$v"; ARGO_DOMAIN=$v ;;
      --domain) valid_domain "$v" || die "域名格式不对：$v"; DOMAIN=$v ;;
      --email) [[ $v =~ ^[^@[:space:]]+@[^@[:space:]]+$ && $v != *\"* && $v != *\\* && $v != *[[:cntrl:]]* ]] || die "邮箱格式不对（不支持引号、反斜杠和控制字符）"; EMAIL=$v ;;
      --sni) valid_domain "$v" || die "SNI 格式不对：$v"; SNI=$v ;;
      --hy2-obfs) [[ $v =~ ^(salamander|gecko|none)$ ]] || die "--hy2-obfs 只能是 salamander、gecko 或 none"; HY2_OBFS=${v/none/} ;;
      --name) [[ $v =~ ^[A-Za-z0-9_.-]{1,24}$ ]] || die "--name 只能用英文、数字和 _.-，最长 24 个字符"; NAME=$v ;;
      --ipv6) IPV6=1 ;;
      --no-bbr) BBR=0 ;;
      --tune) [[ $v =~ ^[0-9]+,[0-9]+$ ]] || die "--tune 的写法是 带宽,延迟，例如 --tune=1000,180"; TUNE=$v ;;
      --swap) [[ $v =~ ^[0-9]+$ ]] && [ "$v" -ge 128 ] && [ "$v" -le 8192 ] || die "--swap 填 128 到 8192 之间的数字（MB）"; SWAP=$v ;;
      --dry-run) DRY_RUN=1 ;;
      -y|--yes) YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "不认识的参数：$a（输入 --help 查看全部选项）" ;;
    esac
  done
  if [ "${ADD_MODE:-0}" = 1 ]; then
    [ $proto_given = 1 ] || die "请写要增加的协议，例如：bfc add --tuic"
    for k in "${!WANT[@]}"; do [ -n "$(port_of $k)" ] || set_port $k "${WANT[$k]}"; done
  elif [ $proto_given = 1 ]; then
    # 重跑同一条命令时，自动端口沿用上次的，节点链接不变
    for k in "${PROTOS[@]}"; do
      if [ "${WANT[$k]:-}" = auto ] && [ -n "$(port_of $k)" ]; then continue; fi
      set_port $k "${WANT[$k]:-}"
    done
  elif [ -z "$(enabled_protos)" ]; then
    set_port reality auto; set_port hy2 auto
  fi
}

port_of()  { local n="PORT_$1"; echo "${!n:-}"; }
set_port() { printf -v "PORT_$1" '%s' "$2"; }
enabled_protos() { local p; for p in "${PROTOS[@]}"; do [ -n "$(port_of $p)" ] && echo -n "$p "; done; }

# ---------- 状态 ----------
STATE_VARS=(UUID PASS SS_KEY SNELL_PSK R_PRIV R_PUB R_SID SNI CERT_SNI WS_PATH DOMAIN EMAIL HY2_OBFS HY2_OBFS_PASS
  ARGO_TOKEN ARGO_DOMAIN ARGO_PORT NAME IPV6 BBR TUNE SWAP STLS_INNER FW_RULES SWAP_MADE)
defaults() {
  UUID= PASS= SS_KEY= SNELL_PSK= R_PRIV= R_PUB= R_SID= SNI= CERT_SNI= WS_PATH= DOMAIN= EMAIL= HY2_OBFS= HY2_OBFS_PASS=
  ARGO_TOKEN= ARGO_DOMAIN= ARGO_PORT= NAME=bufanche IPV6=0 BBR=1 TUNE= SWAP= STLS_INNER= FW_RULES= SWAP_MADE=
  local p; for p in "${PROTOS[@]}"; do set_port $p ""; done
}
load_state() { defaults; [ -r $STATE ] && . $STATE; }
save_state() {
  local v p
  { echo "# bfc 状态文件，由脚本维护，请用 bfc 命令修改"
    for v in "${STATE_VARS[@]}"; do printf '%s=%q\n' "$v" "${!v}"; done
    for p in "${PROTOS[@]}"; do printf 'PORT_%s=%q\n' "$p" "$(port_of $p)"; done
  } > $STATE.tmp && chmod 600 $STATE.tmp && mv $STATE.tmp $STATE
}

# ---------- 规划端口 ----------
plan_ports() {
  local p want net def
  TAKEN=()
  # 先登记手动指定的端口，再给自动的分配
  for pass in fixed auto; do
    for p in "${PROTOS[@]}"; do
      want=$(port_of $p); [ -z "$want" ] && continue
      net=${P_NET[$p]}
      if [ "$net" = local ]; then
        [ $pass = fixed ] && set_port $p 0
        continue
      fi
      if [ $pass = fixed ] && [ "$want" != auto ]; then
        port_free "$want" "$net" || die "$want 端口（${net/both/tcp+udp}）已被占用，换一个端口再试"
        take_port "$want" "$net"
      elif [ $pass = auto ] && [ "$want" = auto ]; then
        def=
        case $p in reality|hy2|naive|trojan) def=443 ;; esac
        if [ -n "$def" ] && port_free $def "$net"; then want=$def; else want=$(random_port "$net"); fi
        take_port "$want" "$net"; set_port $p "$want"
      fi
    done
  done
  [ -n "$(port_of shadowtls)" ] && { [ -n "$STLS_INNER" ] && port_free "$STLS_INNER" tcp || STLS_INNER=$(random_port tcp); take_port "$STLS_INNER" tcp; }
  if [ -n "$(port_of argo)" ]; then
    [ -n "$ARGO_TOKEN" ] && [ -n "$ARGO_DOMAIN" ] || die "Argo 隧道需要同时填 --argo-token 和 --argo-domain"
    # 默认 8080，方便在 Cloudflare 后台照着网页教程填 localhost:8080
    [ -n "$ARGO_PORT" ] && port_free "$ARGO_PORT" tcp || { port_free 8080 tcp && ARGO_PORT=8080 || ARGO_PORT=$(random_port tcp); }
    take_port "$ARGO_PORT" tcp
  fi
  [ -n "$(port_of naive)" ] && [ -z "$DOMAIN" ] && die "NaiveProxy 必须有域名：加上 --domain=你的域名（先把域名解析到这台服务器）"
  return 0
}

# ---------- sing-box ----------
install_singbox() {
  if [ -x $BIN ] && $BIN version 2>/dev/null | head -1 | grep -q " $SB_VERSION\$"; then return; fi
  local name="sing-box-$SB_VERSION-linux-$ARCH-musl" tmp
  tmp=$(mktemp -d)
  info "下载 sing-box $SB_VERSION（$ARCH）"
  curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/sb.tgz" \
    "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/$name.tar.gz" \
    || die "下载失败：这台服务器连不上 GitHub。国内机器请换海外 VPS"
  echo "${SB_SHA256[$ARCH]}  $tmp/sb.tgz" | sha256sum -c - >/dev/null 2>&1 || die "sing-box 安装包校验不通过，已停止安装（文件可能被篡改或没下完整）"
  tar xzf "$tmp/sb.tgz" -C "$tmp" && install -m 755 "$tmp/$name/sing-box" $BIN || die "解压失败"
  rm -rf "$tmp"
}

gen_secrets() {
  [ -n "$UUID" ] || UUID=$($BIN generate uuid)
  [ -n "$PASS" ] || PASS=$($BIN generate rand 16 --hex)
  [ -n "$SS_KEY" ] || SS_KEY=$($BIN generate rand 16 --base64)
  [ -n "$SNELL_PSK" ] || SNELL_PSK=$($BIN generate rand 16 --hex)
  [ -n "$R_SID" ] || R_SID=$($BIN generate rand 8 --hex)
  [ -n "$WS_PATH" ] || WS_PATH=/$($BIN generate rand 6 --hex)
  [ -n "$SNI" ] || SNI=${SNI_LIST[RANDOM % ${#SNI_LIST[@]}]}
  [ -n "$CERT_SNI" ] || CERT_SNI=$SNI
  if [ -z "$R_PRIV" ]; then
    local kp; kp=$($BIN generate reality-keypair)
    R_PRIV=$(echo "$kp" | awk '/PrivateKey/{print $2}'); R_PUB=$(echo "$kp" | awk '/PublicKey/{print $2}')
  fi
  if [ -n "$HY2_OBFS" ] && [ -z "$HY2_OBFS_PASS" ]; then HY2_OBFS_PASS=$($BIN generate rand 12 --hex); fi
  # 没有域名时用自签证书，客户端要开“跳过证书验证”
  if [ ! -s $DIR/cert.pem ]; then
    local kp; kp=$($BIN generate tls-keypair "$CERT_SNI" -m 120)
    echo "$kp" | sed -n '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/p' > $DIR/key.pem
    echo "$kp" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > $DIR/cert.pem
    chmod 600 $DIR/key.pem
  fi
}

# ---------- 生成配置 ----------
tls_json() { # $1 = alpn 列表（JSON），可空
  local alpn=${1:+,\"alpn\":$1}
  if [ -n "$DOMAIN" ]; then
    echo "{\"enabled\":true,\"server_name\":\"$DOMAIN\"$alpn,\"certificate_provider\":\"cert\"}"
  else
    echo "{\"enabled\":true,\"server_name\":\"$CERT_SNI\"$alpn,\"certificate_path\":\"$DIR/cert.pem\",\"key_path\":\"$DIR/key.pem\"}"
  fi
}

inbound_json() {
  local p=$1 port; port=$(port_of $p)
  local L="\"tag\":\"$p\",\"listen\":\"::\",\"listen_port\":$port"
  case $p in
    reality) echo "{\"type\":\"vless\",$L,\"users\":[{\"uuid\":\"$UUID\",\"flow\":\"xtls-rprx-vision\"}],\"tls\":{\"enabled\":true,\"server_name\":\"$SNI\",\"reality\":{\"enabled\":true,\"handshake\":{\"server\":\"$SNI\",\"server_port\":443},\"private_key\":\"$R_PRIV\",\"short_id\":[\"$R_SID\"]}}}" ;;
    hy2)
      local obfs=; [ -n "$HY2_OBFS" ] && obfs=",\"obfs\":{\"type\":\"$HY2_OBFS\",\"password\":\"$HY2_OBFS_PASS\"}"
      echo "{\"type\":\"hysteria2\",$L,\"users\":[{\"password\":\"$PASS\"}]$obfs,\"masquerade\":{\"type\":\"proxy\",\"url\":\"https://$SNI\",\"rewrite_host\":true},\"tls\":$(tls_json '["h3"]')}" ;;
    tuic) echo "{\"type\":\"tuic\",$L,\"users\":[{\"uuid\":\"$UUID\",\"password\":\"$PASS\"}],\"congestion_control\":\"bbr\",\"tls\":$(tls_json '["h3"]')}" ;;
    anytls) echo "{\"type\":\"anytls\",$L,\"users\":[{\"password\":\"$PASS\"}],\"tls\":$(tls_json)}" ;;
    ss) echo "{\"type\":\"shadowsocks\",$L,\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"$SS_KEY\",\"multiplex\":{\"enabled\":true}}" ;;
    shadowtls)
      echo "{\"type\":\"shadowtls\",$L,\"version\":3,\"users\":[{\"password\":\"$PASS\"}],\"handshake\":{\"server\":\"$SNI\",\"server_port\":443},\"strict_mode\":true,\"detour\":\"shadowtls-ss\"},"
      echo "{\"type\":\"shadowsocks\",\"tag\":\"shadowtls-ss\",\"listen\":\"127.0.0.1\",\"listen_port\":$STLS_INNER,\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"$SS_KEY\"}" ;;
    trojan) echo "{\"type\":\"trojan\",$L,\"users\":[{\"password\":\"$PASS\"}],\"tls\":$(tls_json '["h2","http/1.1"]')}" ;;
    vmess)
      local tls=; [ -n "$DOMAIN" ] && tls=",\"tls\":$(tls_json '["http/1.1"]')"
      echo "{\"type\":\"vmess\",$L,\"users\":[{\"uuid\":\"$UUID\",\"alterId\":0}],\"transport\":{\"type\":\"ws\",\"path\":\"$WS_PATH\"}$tls}" ;;
    naive) echo "{\"type\":\"naive\",$L,\"users\":[{\"username\":\"$NAME\",\"password\":\"$PASS\"}],\"tls\":$(tls_json)}" ;;
    hysteria) echo "{\"type\":\"hysteria\",$L,\"up_mbps\":1000,\"down_mbps\":1000,\"users\":[{\"auth_str\":\"$PASS\"}],\"tls\":$(tls_json '["h3"]')}" ;;
    snell) echo "{\"type\":\"snell\",$L,\"version\":5,\"psk\":\"$SNELL_PSK\"}" ;;
    socks) echo "{\"type\":\"socks\",$L,\"users\":[{\"username\":\"$NAME\",\"password\":\"$PASS\"}]}" ;;
    argo)
      echo "{\"type\":\"vless\",\"tag\":\"argo\",\"listen\":\"127.0.0.1\",\"listen_port\":$ARGO_PORT,\"users\":[{\"uuid\":\"$UUID\"}],\"transport\":{\"type\":\"ws\",\"path\":\"$WS_PATH\"}},"
      echo "{\"type\":\"cloudflared\",\"tag\":\"cloudflared\",\"token\":\"$ARGO_TOKEN\"}" ;;
  esac
}

needs_cert() {
  [ -n "$DOMAIN" ] || return 1
  local p
  for p in hy2 tuic anytls trojan vmess naive hysteria; do [ -n "$(port_of "$p")" ] && return 0; done
  return 1
}

write_config() {
  local p first=1 tags= certs= cidrs= addr addresses
  if needs_cert; then
    certs="\"certificate_providers\":[{\"type\":\"acme\",\"tag\":\"cert\",\"domain\":[\"$DOMAIN\"],\"disable_tls_alpn_challenge\":true,\"data_directory\":\"$DIR/acme\"${EMAIL:+,\"email\":\"$EMAIL\"}}],"
  fi
  # 同时覆盖直连公网接口、IPv4 映射地址和 NAT 后探测到的公网入口。
  addresses=$(ip -o address show) || die "读取本机接口地址失败"
  for addr in $( { echo "$addresses" | awk '{sub(/\/.*/,"",$4); print $4}'; printf '%s\n' "$IP4" "$IP6"; } | sort -u); do
    if [[ $addr == *:* ]]; then
      cidrs+="${cidrs:+,}\"$addr/128\""
    else
      cidrs+="${cidrs:+,}\"$addr/32\",\"::ffff:$addr/128\""
    fi
  done
  [ -n "$cidrs" ] || die "没有取得本机地址，拒绝生成缺少本机访问限制的配置"
  {
    echo "{\"log\":{\"level\":\"warn\",\"timestamp\":true},$certs\"inbounds\":["
    for p in $(enabled_protos); do
      [ $first = 1 ] || echo ","; first=0
      inbound_json $p
      tags+="${tags:+,}\"$p\""
      [ $p = shadowtls ] && tags+=",\"shadowtls-ss\""
    done
    # 代理用户不许访问服务器本机和内网（防止被拿来扫内网、碰本机管理面板）
    echo "],\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}],"
    echo "\"route\":{\"rules\":[{\"inbound\":[$tags],\"action\":\"resolve\",\"strategy\":\"prefer_ipv4\"},{\"inbound\":[$tags],\"ip_is_private\":true,\"action\":\"reject\"},{\"inbound\":[$tags],\"ip_cidr\":[$cidrs],\"action\":\"reject\"}]}}"
  } > $CONF.tmp
  $BIN format -c $CONF.tmp -w >/dev/null 2>&1 || die "配置格式化失败"
  if ! $BIN check -c $CONF.tmp; then
    die "生成的配置没通过 sing-box 检查（上面是错误信息），请把这段截图发到 https://github.com/bufanche/deploy/issues"
  fi
  chmod 600 $CONF.tmp && mv $CONF.tmp $CONF || die "配置写入失败"
}

# ---------- 服务 ----------
svc_install() {
  case $INIT in
    systemd)
      cat > /etc/systemd/system/bfc.service <<EOF
[Unit]
Description=bfc (sing-box)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$BIN run -c $CONF
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload; systemctl enable bfc >/dev/null 2>&1 ;;
    openrc)
      cat > /etc/init.d/bfc <<EOF
#!/sbin/openrc-run
description="bfc (sing-box)"
command="$BIN"
command_args="run -c $CONF"
command_background=true
pidfile="/run/bfc.pid"
output_log="$LOG"
error_log="$LOG"
depend() { need net; after firewall; }
EOF
      chmod +x /etc/init.d/bfc; rc-update add bfc default >/dev/null 2>&1 ;;
    none)
      # 没有 systemd / OpenRC（部分容器）：用 crontab 开机启动
      if command -v crontab >/dev/null; then
        { cron_without_bfc; echo "@reboot $CMD start # bfc-managed"; } | crontab -
      else
        warn "这个系统没有 systemd、OpenRC 和 crontab，重启服务器后需要手动输入 bfc start"
      fi ;;
  esac
}
cron_without_bfc() {
  { crontab -l 2>/dev/null || true; } | awk -v cmd="$CMD" '
    $1 == "@reboot" && $2 == cmd && $3 == "start" {next}
    /# bfc-managed$/ {next}
    {print}'
}
svc_active() {
  case $INIT in
    systemd) systemctl is-active --quiet bfc ;;
    openrc) rc-service bfc status >/dev/null 2>&1 ;;
    none)
      [ -r /run/bfc.pid ] || return 1
      local pid executable
      pid=$(cat /run/bfc.pid)
      [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null || return 1
      executable=$(readlink "/proc/$pid/exe") || return 1
      [[ $executable = "$BIN" || $executable = "$BIN (deleted)" ]] ;;
  esac
}
svc_start() {
  case $INIT in
    systemd) systemctl restart bfc ;;
    openrc) rc-service bfc restart >/dev/null 2>&1 ;;
    none) svc_stop; nohup $BIN run -c $CONF >>$LOG 2>&1 & echo $! > /run/bfc.pid ;;
  esac
  sleep 2
  if ! svc_active; then svc_log 20; die "sing-box 没能启动（上面是日志）"; fi
}
svc_stop() {
  if ! svc_active; then
    [ "$INIT" != none ] || rm -f /run/bfc.pid
    return 0
  fi
  case $INIT in
    systemd) systemctl stop bfc 2>/dev/null ;;
    openrc) rc-service bfc stop >/dev/null 2>&1 ;;
    none)
      if [ -r /run/bfc.pid ]; then
        local pid i; pid=$(cat /run/bfc.pid)
        kill "$pid" 2>/dev/null || true
        for i in $(seq 1 50); do
          kill -0 "$pid" 2>/dev/null || break
          [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" = Z ] && break
          sleep 0.1
        done
      fi
      rm -f /run/bfc.pid ;;
  esac
  return 0
}
svc_log() {
  local n=${1:-80}
  if [ $INIT = systemd ]; then journalctl -u bfc -n "$n" --no-pager; else tail -n "$n" $LOG 2>/dev/null; fi
}
svc_remove() {
  svc_stop
  case $INIT in
    systemd) systemctl disable bfc >/dev/null 2>&1; rm -f /etc/systemd/system/bfc.service; systemctl daemon-reload ;;
    openrc) rc-update del bfc default >/dev/null 2>&1; rm -f /etc/init.d/bfc ;;
    none) if command -v crontab >/dev/null; then cron_without_bfc | crontab -; fi ;;
  esac
}

# ---------- 防火墙 ----------
# owned 标记仅用于新版实际新增的规则；旧状态无法证明所有权，保守保留。
fw_ports() {
  local p port net n
  for p in $(enabled_protos); do
    net=${P_NET[$p]}; port=$(port_of "$p")
    for n in tcp udp; do
      [ "$net" = both ] || [ "$net" = "$n" ] || continue
      echo "$port/$n"
    done
  done
  needs_cert && echo 80/tcp
  return 0
}
fw_has() {
  local tool=$1 pp=$2 port=${2%/*} n=${2#*/}
  case $tool in
    ufw4|ufw6) ufw status | awk -v pp="$pp" -v port="$port" -v family="$tool" '
      {v6=($0 ~ /\(v6\)/); gsub(/\(v6\)/, "")}
      ($1==pp || $1==port) && $2=="ALLOW" && $3=="Anywhere" && ((family=="ufw6")==v6) {found=1}
      END {exit !found}' ;;
    firewalld-runtime) firewall-cmd -q --query-port="$pp" ;;
    firewalld-permanent) firewall-cmd -q --permanent --query-port="$pp" ;;
    iptables|ip6tables) "$tool" -C INPUT -p "$n" --dport "$port" -m comment --comment bfc -j ACCEPT 2>/dev/null ;;
  esac
}
fw_change() {
  local op=$1 tool=$2 pp=$3 port=${3%/*} n=${3#*/}
  case $tool in
    ufw4|ufw6)
      local any=0.0.0.0/0; [ "$tool" = ufw6 ] && any=::/0
      if [ "$op" = add ]; then ufw allow proto "$n" from "$any" to "$any" port "$port" comment bfc >/dev/null
      else ufw --force delete allow proto "$n" from "$any" to "$any" port "$port" >/dev/null; fi ;;
    firewalld-runtime) firewall-cmd -q --"$op"-port="$pp" ;;
    firewalld-permanent) firewall-cmd -q --permanent --"$op"-port="$pp" ;;
    iptables|ip6tables)
      local flag=-I; [ "$op" = remove ] && flag=-D
      "$tool" "$flag" INPUT -p "$n" --dport "$port" -m comment --comment bfc -j ACCEPT ;;
    *) return 1 ;;
  esac
}
fw_persist() {
  if command -v netfilter-persistent >/dev/null; then netfilter-persistent save >/dev/null; fi
}
fw_open_all() {
  local tools= tool pp rule
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    tools=ufw4
    if grep -qi '^IPV6=yes$' /etc/default/ufw; then tools+=" ufw6"; fi
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then tools="firewalld-runtime firewalld-permanent"
  else
    for tool in iptables ip6tables; do
      if command -v "$tool" >/dev/null && "$tool" -S INPUT 2>/dev/null | grep -qE '^-P INPUT DROP|-j (REJECT|DROP)'; then tools+=" $tool"; fi
    done
  fi
  for tool in $tools; do
    for pp in $(fw_ports | sort -u); do
      rule="$tool-owned:$pp"
      [[ " $FW_RULES " == *" $rule "* ]] && fw_has "$tool" "$pp" && continue
      fw_has "$tool" "$pp" && continue
      fw_change add "$tool" "$pp" || die "防火墙放行失败：$tool $pp"
      FW_RULES+="${FW_RULES:+ }$rule"
      TXN_ADDED_FW+=" $rule"
    done
  done
  fw_persist
  return 0
}
fw_remove_rules() {
  local r tool pp
  for r in $1; do
    tool=${r%%:*}; pp=${r#*:}
    if [[ $tool != *-owned ]]; then
      warn "保留旧版未标记的防火墙规则 $r：无法确认是否由 bfc 创建，请手动核对"
      continue
    fi
    tool=${tool%-owned}
    fw_has "$tool" "$pp" || continue
    fw_change remove "$tool" "$pp" || return 1
    TXN_REMOVED_FW+=" $r"
  done
  fw_persist
}
fw_prune() {
  local r keep= stale= desired
  desired=" $(fw_ports | sort -u | tr '\n' ' ') "
  for r in $FW_RULES; do
    if [[ $r != *-owned:* ]] || [[ $desired == *" ${r#*:} "* ]]; then keep+=" $r"
    else stale+=" $r"; fi
  done
  fw_remove_rules "$stale" || die "旧防火墙规则撤回失败"
  FW_RULES=$keep
}
fw_close_all() {
  fw_remove_rules "$FW_RULES" || die "防火墙规则撤回失败，保留状态供重试"
  FW_RULES=
}

# ---------- 系统优化 ----------
apply_sysctl() {
  local lines=
  if [ "$BBR" = 1 ]; then
    modprobe tcp_bbr 2>/dev/null
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      lines+=$'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n'
    else
      warn "内核不支持 BBR（$(uname -r)），跳过"
    fi
  fi
  if [ -n "$TUNE" ]; then
    # 缓冲区上限按带宽时延积的 2 倍算，限制在 4MB 到 64MB 之间
    local bw=${TUNE%,*} rtt=${TUNE#*,} max
    max=$(( bw * rtt * 125 * 2 ))
    [ $max -lt 4194304 ] && max=4194304
    [ $max -gt 67108864 ] && max=67108864
    lines+="net.core.rmem_max = $max
net.core.wmem_max = $max
net.ipv4.tcp_rmem = 4096 131072 $max
net.ipv4.tcp_wmem = 4096 65536 $max
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
"
  fi
  if [ -z "$lines" ]; then rm -f $SYSCTL_FILE; return; fi
  if [ $VIRT != kvm ]; then warn "这台是容器类 VPS（$VIRT），改不了内核参数，跳过 BBR 和 TCP 调优"; return; fi
  mkdir -p /etc/sysctl.d
  printf '# 由 bfc 写入，bfc uninstall 会删除\n%s' "$lines" > $SYSCTL_FILE
  if sysctl -p $SYSCTL_FILE >/dev/null 2>&1; then
    info "已开启：$( [ "$BBR" = 1 ] && echo 'BBR + fq ')$( [ -n "$TUNE" ] && echo "TCP 缓冲区上限 $((max/1048576))MB")"
  else
    warn "部分内核参数没生效，可能是 VPS 不允许修改"
  fi
}

make_swap() {
  [ -z "$SWAP" ] && return
  [ -n "$SWAP_MADE" ] && return
  if [ $VIRT != kvm ]; then warn "容器类 VPS 不能加 swap，跳过"; return; fi
  if [ "$(awk 'NR>1' /proc/swaps | wc -l)" -gt 0 ]; then info "已有 swap，不再创建"; return; fi
  info "创建 ${SWAP}MB swap"
  { fallocate -l ${SWAP}M $SWAP_FILE 2>/dev/null || dd if=/dev/zero of=$SWAP_FILE bs=1M count=$SWAP status=none; } &&
    chmod 600 $SWAP_FILE && mkswap $SWAP_FILE >/dev/null && swapon $SWAP_FILE &&
    { grep -q "^$SWAP_FILE " /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab; } &&
    SWAP_MADE=1 || { warn "swap 创建失败"; rm -f $SWAP_FILE; }
}

check_time() {
  # VMess、TUIC 等协议对时间敏感，误差太大会连不上
  local d now t
  d=$(curl -sI --max-time 5 https://www.cloudflare.com 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
  [ -z "$d" ] && return
  t=$(date -u -d "$d" +%s 2>/dev/null || date -u -D '%a, %d %b %Y %H:%M:%S GMT' -d "$d" +%s 2>/dev/null) || return
  now=$(date -u +%s)
  local diff=$(( now > t ? now - t : t - now ))
  [ $diff -gt 30 ] && warn "服务器时间和标准时间差了 ${diff} 秒，可能导致连不上。Debian/Ubuntu 可运行：apt install -y systemd-timesyncd"
  return 0
}

# ---------- 节点信息 ----------
public_ip() {
  local v=$1 ip
  if [ $v = 4 ]; then
    ip=$(curl -4 -s --max-time 5 https://1.1.1.1/cdn-cgi/trace | awk -F= '$1=="ip"{print $2}') || ip=
    if [ -z "$ip" ]; then ip=$(curl -4 -s --max-time 5 https://api.ipify.org) || ip=; fi
  else
    ip=$(curl -6 -s --max-time 5 'https://[2606:4700:4700::1111]/cdn-cgi/trace' | awk -F= '$1=="ip"{print $2}') || ip=
    if [ -z "$ip" ]; then ip=$(curl -6 -s --max-time 5 https://api6.ipify.org) || ip=; fi
  fi
  if [ "$v" = 4 ]; then
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 0
    local part; for part in ${ip//./ }; do (( 10#$part <= 255 )) || return 0; done
  else
    [[ $ip == *:* && $ip =~ ^[0-9a-fA-F:]+$ ]] || return 0
  fi
  echo "$ip"
}
discover_addresses() {
  IP4=$(public_ip 4); IP6=$(public_ip 6)
  [ -n "$IP4$IP6" ] || die "没查到本机公网 IP，已停止；请检查服务器到 Cloudflare / ipify 的连接"
  [ "$IPV6" != 1 ] || [ -n "$IP6" ] || die "指定了 --ipv6，但没有检测到可用公网 IPv6"
}
b64() { base64 | tr -d '\n'; }
host_addr() { if [ "$IPV6" = 1 ] || [ -z "$IP4" ]; then echo "[$IP6]"; else echo "$IP4"; fi; }

# 输出：名字|链接（没有通用链接格式的协议链接为空）
node_link() {
  local p=$1 port h n sni ins
  port=$(port_of $p); h=$(host_addr); n="$NAME-${P_NAME[$p]}"
  if [ -n "$DOMAIN" ]; then sni=$DOMAIN ins=0; else sni=$CERT_SNI ins=1; fi
  local th=$h; [ -n "$DOMAIN" ] && th=$DOMAIN   # 用证书的协议，有域名就连域名
  case $p in
    reality) echo "vless://$UUID@$h:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$R_PUB&sid=$R_SID&type=tcp#$n" ;;
    hy2) local o=; [ -n "$HY2_OBFS" ] && o="&obfs=$HY2_OBFS&obfs-password=$HY2_OBFS_PASS"
         echo "hysteria2://$PASS@$th:$port?sni=$sni&insecure=$ins&alpn=h3$o#$n" ;;
    tuic) echo "tuic://$UUID:$PASS@$th:$port?congestion_control=bbr&alpn=h3&sni=$sni&allow_insecure=$ins&udp_relay_mode=native#$n" ;;
    anytls) echo "anytls://$PASS@$th:$port?sni=$sni&insecure=$ins#$n" ;;
    ss) echo "ss://$(printf '%s' "2022-blake3-aes-128-gcm:$SS_KEY" | b64)@$h:$port#$n" ;;
    trojan) echo "trojan://$PASS@$th:$port?security=tls&sni=$sni&allowInsecure=$ins&type=tcp#$n" ;;
    vmess) local tls= vh=$h; [ -n "$DOMAIN" ] && { tls=tls; vh=$DOMAIN; }
           echo "vmess://$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"%s","tls":"%s","sni":"%s"}' \
             "$n" "${vh//[\[\]]/}" "$port" "$UUID" "$DOMAIN" "$WS_PATH" "$tls" "$DOMAIN" | b64)" ;;
    naive) echo "naive+https://$NAME:$PASS@$DOMAIN:$port#$n" ;;
    hysteria) echo "hysteria://$th:$port?protocol=udp&auth=$PASS&peer=$sni&insecure=$ins&upmbps=50&downmbps=200&alpn=h3#$n" ;;
    socks) echo "socks5://$NAME:$PASS@$h:$port#$n" ;;
    argo) echo "vless://$UUID@$ARGO_DOMAIN:443?encryption=none&security=tls&sni=$ARGO_DOMAIN&type=ws&host=$ARGO_DOMAIN&path=$(printf %s "$WS_PATH" | sed 's#/#%2F#g')#$n" ;;
    *) echo "" ;;
  esac
}

# sing-box 客户端出站配置（所有协议都有，包括没有通用链接的 ShadowTLS、Snell）
# Snell：sing-box 客户端没有 v5（v5 和 v4 协议一样），客户端写 version 4
client_outbound() {
  local p=$1 port h n sni ins th
  port=$(port_of $p); h=$(host_addr); h=${h//[\[\]]/}; n="$NAME-${P_NAME[$p]}"
  if [ -n "$DOMAIN" ]; then sni=$DOMAIN ins=false th=$DOMAIN; else sni=$CERT_SNI ins=true th=$h; fi
  local S="\"tag\":\"$n\",\"server\":\"$h\",\"server_port\":$port"
  local ST="\"tag\":\"$n\",\"server\":\"$th\",\"server_port\":$port"
  local T="\"tls\":{\"enabled\":true,\"server_name\":\"$sni\",\"insecure\":$ins"
  case $p in
    reality) echo "{\"type\":\"vless\",$S,\"uuid\":\"$UUID\",\"flow\":\"xtls-rprx-vision\",\"tls\":{\"enabled\":true,\"server_name\":\"$SNI\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"},\"reality\":{\"enabled\":true,\"public_key\":\"$R_PUB\",\"short_id\":\"$R_SID\"}}}" ;;
    hy2) local o=; [ -n "$HY2_OBFS" ] && o=",\"obfs\":{\"type\":\"$HY2_OBFS\",\"password\":\"$HY2_OBFS_PASS\"}"
         echo "{\"type\":\"hysteria2\",$ST,\"password\":\"$PASS\"$o,$T,\"alpn\":[\"h3\"]}}" ;;
    tuic) echo "{\"type\":\"tuic\",$ST,\"uuid\":\"$UUID\",\"password\":\"$PASS\",\"congestion_control\":\"bbr\",$T,\"alpn\":[\"h3\"]}}" ;;
    anytls) echo "{\"type\":\"anytls\",$ST,\"password\":\"$PASS\",$T}}" ;;
    ss) echo "{\"type\":\"shadowsocks\",$S,\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"$SS_KEY\",\"multiplex\":{\"enabled\":true}}" ;;
    shadowtls) echo "{\"type\":\"shadowsocks\",\"tag\":\"$n\",\"method\":\"2022-blake3-aes-128-gcm\",\"password\":\"$SS_KEY\",\"detour\":\"$n-tls\"},{\"type\":\"shadowtls\",\"tag\":\"$n-tls\",\"server\":\"$h\",\"server_port\":$port,\"version\":3,\"password\":\"$PASS\",\"tls\":{\"enabled\":true,\"server_name\":\"$SNI\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}}}" ;;
    trojan) echo "{\"type\":\"trojan\",$ST,\"password\":\"$PASS\",$T,\"alpn\":[\"h2\",\"http/1.1\"]}}" ;;
    vmess) local tls= hdr=; [ -n "$DOMAIN" ] && { tls=",$T}"; hdr=",\"headers\":{\"Host\":\"$DOMAIN\"}"; }
           echo "{\"type\":\"vmess\",$ST,\"uuid\":\"$UUID\",\"security\":\"auto\",\"transport\":{\"type\":\"ws\",\"path\":\"$WS_PATH\"$hdr}$tls}" ;;
    naive) echo "{\"type\":\"naive\",\"tag\":\"$n\",\"server\":\"$DOMAIN\",\"server_port\":$port,\"username\":\"$NAME\",\"password\":\"$PASS\",\"tls\":{\"enabled\":true,\"server_name\":\"$DOMAIN\"}}" ;;
    hysteria) echo "{\"type\":\"hysteria\",$ST,\"auth_str\":\"$PASS\",\"up_mbps\":50,\"down_mbps\":200,$T,\"alpn\":[\"h3\"]}}" ;;
    snell) echo "{\"type\":\"snell\",$S,\"version\":4,\"psk\":\"$SNELL_PSK\"}" ;;
    socks) echo "{\"type\":\"socks\",$S,\"username\":\"$NAME\",\"password\":\"$PASS\"}" ;;
    argo) echo "{\"type\":\"vless\",\"tag\":\"$n\",\"server\":\"$ARGO_DOMAIN\",\"server_port\":443,\"uuid\":\"$UUID\",\"tls\":{\"enabled\":true,\"server_name\":\"$ARGO_DOMAIN\"},\"transport\":{\"type\":\"ws\",\"path\":\"$WS_PATH\",\"headers\":{\"Host\":\"$ARGO_DOMAIN\"}}}" ;;
  esac
}

write_outputs() {
  local p l first=1
  : > $DIR/links.txt
  for p in $(enabled_protos); do l=$(node_link $p); [ -n "$l" ] && echo "$l" >> $DIR/links.txt; done
  { echo '{"outbounds":['
    for p in $(enabled_protos); do [ $first = 1 ] || echo ","; first=0; client_outbound $p; done
    echo ']}'; } > $DIR/client.json
  $BIN format -c $DIR/client.json -w >/dev/null 2>&1 || die "客户端配置格式化失败"
  [ -n "$(port_of snell)" ] && echo "$NAME-Snell = snell, $(host_addr | tr -d '[]'), $(port_of snell), psk=$SNELL_PSK, version=5, reuse=true" > $DIR/surge.txt || rm -f $DIR/surge.txt
  chmod 600 $DIR/links.txt $DIR/client.json
}

show_info() {
  load_state
  [ -r $DIR/links.txt ] || die "还没有安装，先运行部署命令"
  local p port net
  step "节点列表"
  for p in $(enabled_protos); do
    port=$(port_of $p); net=${P_NET[$p]}
    if [ "$net" = local ]; then echo "  ${B}${P_NAME[$p]}${N}  经 Cloudflare 隧道 $ARGO_DOMAIN:443（隧道公共主机名的服务地址填 http://localhost:$ARGO_PORT）"
    else echo "  ${B}${P_NAME[$p]}${N}  端口 $port/${net/both/tcp+udp}"; fi
  done
  step "节点链接（整段复制，导入客户端）"
  sed 's/^/  /' $DIR/links.txt
  [ -r $DIR/surge.txt ] && { step "Snell（复制到 Surge 的 [Proxy] 段）"; sed 's/^/  /' $DIR/surge.txt; }
  [ -n "$(port_of shadowtls)" ] && echo "  ${D}ShadowTLS 没有通用链接，sing-box 客户端配置在 $DIR/client.json${N}"
  [ -z "$DOMAIN" ] && grep -qE '^(hysteria2|tuic|anytls|trojan|hysteria)://' $DIR/links.txt && \
    echo "  ${D}Hysteria2、TUIC、AnyTLS、Trojan 用的是自签证书，链接里已经带上“跳过证书验证”${N}"
  if needs_cert; then echo "  ${D}证书由 sing-box 自动申请；云安全组需持续放行 TCP 80，用于签发和续期${N}"; fi
  step "下一步"
  echo "  1. 云服务商后台的安全组/防火墙放行上面的端口（甲骨文、AWS、谷歌云、阿里云、腾讯云都要手动放行）"
  echo "  2. 客户端怎么导入：https://bufanche.com/tools/deploy/#import"
  echo "  3. 连上以后测一下：IP 纯净度 https://bufanche.com/tools/ip-quality/   回程线路 https://bufanche.com/tools/route/"
  echo "  4. 要分流配置：把链接贴进 https://bufanche.com/tools/rules/"
  echo
  echo "  ${D}二维码：bfc qr    管理菜单：bfc    文件位置：$DIR${N}"
}

show_qr() {
  [ -r $DIR/links.txt ] || die "还没有安装"
  command -v qrencode >/dev/null || { detect_os; pkg_install qrencode libqrencode-tools 2>/dev/null; }
  command -v qrencode >/dev/null || die "没装上 qrencode，用 bfc info 复制链接吧"
  local l
  while read -r l; do echo; echo "${B}${l##*#}${N}"; qrencode -t ANSIUTF8 -m 1 "$l"; done < $DIR/links.txt
}

# ---------- 主流程 ----------
print_plan() {
  local p port net
  step "将要执行（${OS_NAME}，$ARCH，$INIT${VIRT:+，$VIRT}）"
  echo "  · 安装 sing-box $SB_VERSION 到 $BIN（校验 sha256），服务名 bfc"
  for p in $(enabled_protos); do
    port=$(port_of $p); net=${P_NET[$p]}
    if [ "$net" = local ]; then echo "  · ${P_NAME[$p]}：Cloudflare 隧道，域名 $ARGO_DOMAIN"
    else echo "  · ${P_NAME[$p]}：端口 $port/${net/both/tcp+udp}"; fi
  done
  if needs_cert; then echo "  · 为 $DOMAIN 自动申请证书；持续放行 TCP 80 供签发和续期，云安全组也需要放行"; fi
  [ "$BBR" = 1 ] && echo "  · 开启 BBR + fq（写入 $SYSCTL_FILE）"
  [ -n "$TUNE" ] && echo "  · 按 ${TUNE%,*}Mbps / ${TUNE#*,}ms 调整 TCP 缓冲区"
  [ -n "$SWAP" ] && echo "  · 没有 swap 时创建 ${SWAP}MB swap（$SWAP_FILE）"
  echo "  · 系统防火墙开着的话放行上述端口；配置和密钥存在 $DIR"
  echo "  · 不上传任何数据，不改 SSH 设置"
}

# 配置、程序、服务定义一起保留；失败时恢复原状态，原来运行的服务会重新启动。
TXN_ADDED_FW= TXN_REMOVED_FW=
transaction_end() {
  local status=$1 rollback_ok=1 i r tool pp removed=$TXN_REMOVED_FW
  trap - EXIT INT TERM
  set +e
  if [ "$status" != 0 ] && [ "$TXN_READY" = 1 ]; then
    warn "变更失败，正在恢复原配置和服务"
    svc_stop || rollback_ok=0
    fw_remove_rules "$TXN_ADDED_FW" || rollback_ok=0
    for r in $removed; do
      tool=${r%%:*}; tool=${tool%-owned}; pp=${r#*:}
      fw_has "$tool" "$pp" || fw_change add "$tool" "$pp" || rollback_ok=0
    done
    fw_persist || rollback_ok=0
    if [ ! -e "$TXN_DIR/path0" ]; then svc_remove || rollback_ok=0; fi
    for i in "${!TXN_PATHS[@]}"; do
      rm -rf "${TXN_PATHS[$i]}" || rollback_ok=0
      if [ -e "$TXN_DIR/path$i" ] || [ -L "$TXN_DIR/path$i" ]; then
        mkdir -p "$(dirname "${TXN_PATHS[$i]}")"
        cp -a "$TXN_DIR/path$i" "${TXN_PATHS[$i]}" || rollback_ok=0
      fi
    done
    if command -v crontab >/dev/null; then
      if [ "$TXN_CRON_PRESENT" = 1 ]; then crontab "$TXN_DIR/cron" || rollback_ok=0
      else crontab -r 2>/dev/null || true; fi
    fi
    [ "$INIT" != systemd ] || systemctl daemon-reload || rollback_ok=0
    if [ "$TXN_ACTIVE" = 1 ]; then (svc_start) || rollback_ok=0; fi
    if [ "$rollback_ok" = 1 ]; then warn "原配置和服务状态已恢复"
    else warn "自动恢复未完成，备份保留在 $TXN_DIR，请检查 bfc log"; fi
  fi
  if [ "$rollback_ok" = 1 ]; then rm -rf "$TXN_DIR"; fi
  exit "$status"
}
with_change_lock() (
  need_root
  mkdir /run/bfc-change.lock 2>/dev/null || die "另一个 bfc 变更正在进行；若上次被强制终止，请先核对服务和 /run/bfc-change.lock"
  trap 'rmdir /run/bfc-change.lock' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  CHANGE_LOCK_HELD=1
  "$@"
)
transaction() {
  if [ "${CHANGE_LOCK_HELD:-0}" = 1 ]; then run_transaction "$@"
  else with_change_lock run_transaction "$@"; fi
}
run_transaction() (
  set -e
  umask 077
  TXN_READY=0; TXN_ACTIVE=0; TXN_CRON_PRESENT=0
  TXN_ADDED_FW=; TXN_REMOVED_FW=
  TXN_DIR=$(mktemp -d) || die "创建恢复备份目录失败"
  trap 'transaction_end $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  TXN_PATHS=("$DIR" "$BIN" "$CMD" /etc/systemd/system/bfc.service /etc/init.d/bfc
    /etc/systemd/system/multi-user.target.wants/bfc.service /etc/runlevels/default/bfc)
  for i in "${!TXN_PATHS[@]}"; do
    if [ -e "${TXN_PATHS[$i]}" ] || [ -L "${TXN_PATHS[$i]}" ]; then cp -a "${TXN_PATHS[$i]}" "$TXN_DIR/path$i"; fi
  done
  if command -v crontab >/dev/null && crontab -l > "$TXN_DIR/cron" 2>/dev/null; then TXN_CRON_PRESENT=1; fi
  svc_active 2>/dev/null && TXN_ACTIVE=1
  TXN_READY=1
  "$@"
)
apply_change() {
  local mode=$1 script=${2:-}
  install_deps
  discover_addresses
  # 只在真实变更中停服，预览始终只读。
  svc_stop
  plan_ports
  if needs_cert && port_used 80 tcp; then die "TCP 80 已被占用，无法完成证书验证；请先释放该端口"; fi
  if [ "$mode" != modify ]; then install_singbox; fi
  gen_secrets
  write_config
  write_outputs
  svc_install
  fw_open_all
  svc_start
  fw_prune
  save_state
  if [ -n "$script" ]; then install -m 755 "$script" "$CMD"; fi
}

do_install() {
  banner
  need_root; detect_os
  [ "$PM" = none ] && warn "没识别出包管理器（$OS_NAME），继续尝试"
  load_state
  remember_listeners
  parse_flags "$@"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    plan_ports; print_plan
    echo; info "这是预览，没有改动系统"; return
  fi
  step "开始安装"
  local script= status
  if [ -f "$0" ] && [ "$(readlink -f "$0")" != "$CMD" ]; then script=$0
  elif [ ! -x "$CMD" ]; then # 用 bash <(curl ...) 这类方式运行时 $0 不是文件，另下一份装成 bfc
    script=$(mktemp)
    curl -fsSL --max-time 30 -o "$script" "$SCRIPT_URL" && grep -q '^SCRIPT_VERSION=' "$script" || { warn "bfc 管理命令没装上"; script=; }
  fi
  transaction install_change "$script"
  status=$?; [ "$status" = 0 ] || return "$status"
  load_state
  apply_sysctl
  make_swap
  save_state || die "系统优化状态保存失败"
  check_time
  echo; info "${G}${B}安装完成${N}"
  show_info
}
install_change() {
  mkdir -p "$DIR"; chmod 700 "$DIR"
  apply_change install "$1"
}

do_uninstall() {
  need_root; detect_os; load_state
  if [ "${YES:-0}" != 1 ] && [ -t 0 ]; then
    read -r -p "确定卸载？节点会全部失效（y/N）：" a; [[ $a =~ ^[yY]$ ]] || { echo "已取消"; return; }
  fi
  svc_remove
  fw_close_all
  rm -f $SYSCTL_FILE
  if [ -n "$SWAP_MADE" ]; then swapoff $SWAP_FILE 2>/dev/null; rm -f $SWAP_FILE; sed -i "\#^$SWAP_FILE #d" /etc/fstab; fi
  rm -rf $DIR $BIN $LOG
  info "已卸载。BBR 等内核参数会在下次重启后恢复默认"
  rm -f $CMD
}

do_update() {
  need_root
  local tmp status
  tmp=$(mktemp /usr/local/bin/.bfc.XXXXXX)
  info "下载最新脚本"
  if ! { curl -fsSL --max-time 30 -o "$tmp" "$SCRIPT_URL" || curl -fsSL --max-time 30 -o "$tmp" "$SCRIPT_URL_BACKUP"; }; then rm -f "$tmp"; die "下载失败"; fi
  if ! grep -q '^SCRIPT_VERSION=' "$tmp" || ! bash -n "$tmp"; then rm -f "$tmp"; die "下载到的脚本无效，保留原版本"; fi
  # 新脚本验证、服务重启和输出全部成功后，才替换管理命令。
  bash "$tmp" reload "$tmp"
  status=$?; rm -f "$tmp"
  return "$status"
}

do_reload() {
  need_root; detect_os; load_state
  [ -r "$STATE" ] || die "还没有安装"
  transaction apply_change reload "${1:-}"
  local status=$?; [ "$status" = 0 ] || return "$status"
  info "已重新应用，sing-box $SB_VERSION"
}

do_modify() {
  need_root; detect_os; load_state
  [ -r "$STATE" ] || die "还没有安装，先运行部署命令"
  local mode=$1 status; shift
  remember_listeners
  if [ "$mode" = add ]; then
    ADD_MODE=1 parse_flags "$@"
  else
    [ $# -gt 0 ] || die "写要删除的协议，例如：bfc del tuic"
    local p; for p in "$@"; do
      p=${p#--}; [ -n "${P_NAME[$p]:-}" ] || die "没有这个协议：$p"
      set_port "$p" ""
    done
    [ -n "$(enabled_protos)" ] || die "至少要留一个协议。要全部删除请用 bfc uninstall"
  fi
  if [ "${DRY_RUN:-0}" = 1 ]; then plan_ports; print_plan; return; fi
  transaction apply_change modify
  status=$?; [ "$status" = 0 ] || return "$status"
  show_info
}

menu() {
  load_state
  [ -r $STATE ] || { usage; return; }
  detect_os
  local st; svc_active && st="${G}运行中${N}" || st="${R}已停止${N}"
  banner
  echo "sing-box $SB_VERSION  状态：$st"
  echo "协议：$(for p in $(enabled_protos); do echo -n "${P_NAME[$p]} "; done)"
  cat <<EOF

  1. 查看节点链接        2. 显示二维码
  3. 增加协议            4. 删除协议
  5. 重启                6. 查看日志
  7. 更新脚本和 sing-box 8. 卸载
  0. 退出
EOF
  read -r -p "输入数字：" c
  case $c in
    1) show_info ;; 2) show_qr ;;
    3) echo "可选：${PROTOS[*]}"; read -r -p "要增加的协议（可写多个，空格隔开，例如 tuic anytls）：" x
       local args=(); for p in $x; do args+=("--${p#--}"); done; main add "${args[@]}" ;;
    4) read -r -p "要删除的协议：" x; main del $x ;;
    5) main restart ;;
    6) svc_log ;;
    7) main update ;;
    8) main uninstall ;;
    *) ;;
  esac
}

dispatch() {
  case "${1:-}" in
    info) show_info ;;
    qr) show_qr ;;
    add|del) do_modify "$@" ;;
    start|restart) need_root; detect_os; svc_start; info "已启动" ;;
    stop) need_root; detect_os; svc_stop; info "已停止" ;;
    log|logs) detect_os; svc_log "${2:-80}" ;;
    update) do_update ;;
    reload) do_reload "${2:-}" ;;
    uninstall) shift; for a in "$@"; do [ "$a" = -y ] && YES=1; done; do_uninstall ;;
    version|-v) echo "bfc $SCRIPT_VERSION / sing-box $SB_VERSION" ;;
    help|-h|--help) usage ;;
    "") if [ "$(basename "$0")" = bfc ]; then menu; else do_install; fi ;;
    *) do_install "$@" ;;
  esac
}

main() {
  local arg
  case "${1:-}" in
    info|qr|log|logs|version|-v|help|-h|--help|update) dispatch "$@" ;;
    "") if [ "$(basename "$0")" = bfc ]; then menu; else with_change_lock dispatch "$@"; fi ;;
    add|-*)
      for arg in "$@"; do
        if [ "$arg" = --dry-run ]; then dispatch "$@"; return; fi
      done
      with_change_lock dispatch "$@" ;;
    *) with_change_lock dispatch "$@" ;;
  esac
}

main "$@"
