#!/usr/bin/env bash
# 在隔离 Linux 容器运行：docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash /src/tests/regression-test.sh
set -uo pipefail
[ -f /.dockerenv ] || { echo '请在隔离 Docker 容器运行，避免修改宿主机'; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export ROOT
PASS=0 FAIL=0
run() {
  local name=$1 body=$2
  if bash -c '
    set -euo pipefail
    source <(sed '\''$d'\'' "$ROOT/deploy.sh")
    defaults
    scratch=$(mktemp -d)
    trap '\''rm -rf "$scratch"'\'' EXIT
    '"$body"; then
    echo "PASS $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; FAIL=$((FAIL+1))
  fi
}
run 'ports: decimal normalization and bounds' '
  parse_flags --reality=08 --hy2=00443
  [ "$(port_of reality)" = 8 ]; [ "$(port_of hy2)" = 443 ]
  for value in 0 00000 65536 999999999999999999999999 -1 0x50; do
    if valid_port "$value"; then exit 1; fi
  done
  valid_port 65535
'
run 'service: first install tolerates an absent systemd/OpenRC unit' '
  systemctl(){ return 5; }; rc-service(){ return 1; }
  INIT=systemd; svc_stop
  INIT=openrc; svc_stop
'
run 'bootstrap: dry-run cannot auto-install bash' '
  mkdir "$scratch/bin"
  printf "#!/bin/sh\necho changed > %s\n" "$scratch/changed" > "$scratch/bin/apk"
  chmod +x "$scratch/bin/apk"
  if PATH="$scratch/bin" /bin/sh "$ROOT/deploy.sh" --dry-run; then exit 1; fi
  [ ! -e "$scratch/changed" ]
'
run 'email: reject JSON-breaking input before changing services' '
  parse_flags --email=user+tag@example.com
  [ "$EMAIL" = user+tag@example.com ]
  if (parse_flags --email=a\"b@example.com); then exit 1; fi
  if (parse_flags --email=a\\b@example.com); then exit 1; fi
'
run 'service: stale PID cannot stop an unrelated process' '
  INIT=none; BIN=/not-the-sleep-binary
  sleep 30 & child=$!
  echo "$child" > /run/bfc.pid
  svc_stop
  kill -0 "$child"; [ ! -e /run/bfc.pid ]
  kill "$child"
'
run 'lock: install, modify, uninstall and stop exclude each other' '
  dispatch(){ touch "$scratch/entered"; sleep 1; }
  main --socks=24443 & holder=$!
  for i in $(seq 1 100); do [ ! -e "$scratch/entered" ] || break; sleep 0.01; done
  [ -d /run/bfc-change.lock ]
  if (main add --hy2); then exit 1; fi
  if (main uninstall -y); then exit 1; fi
  if (main stop); then exit 1; fi
  wait "$holder"
  [ ! -e /run/bfc-change.lock ]
'
run 'preview: own listeners ignored, foreign transport not ignored' '
  svc_active(){ return 0; }
  PORT_reality=443; remember_listeners
  DRY_RUN=1; port_used(){ return 0; }
  port_free 443 tcp
  if port_free 443 udp; then exit 1; fi
  port_used(){ [ "$1/$2" = 443/tcp ]; }
  need_root(){ :; }; detect_os(){ PM=apt; OS_NAME=mock; ARCH=amd64; INIT=none; VIRT=container; }
  svc_stop(){ echo stopped > "$scratch/stopped"; }
  DIR=$scratch/state; mkdir -p "$DIR"; STATE=$DIR/state; save_state
  do_install --dry-run --reality
  [ ! -e "$scratch/stopped" ]
  do_modify add --hy2=444 --dry-run
  [ ! -e "$scratch/stopped" ]
'
run 'IPv6: missing address fails, IPv4 and IPv6 controls succeed' '
  public_ip(){ [ "$1" != 4 ] || echo 203.0.113.1; return 0; }
  IPV6=1
  if (discover_addresses); then exit 1; fi
  IPV6=0; discover_addresses; [ "$IP4" = 203.0.113.1 ]
  public_ip(){ if [ "$1" = 4 ]; then echo 203.0.113.1; else echo 2001:db8::1; fi; }
  IPV6=1; discover_addresses; [ "$(host_addr)" = "[2001:db8::1]" ]
'
run 'POSIX bash: unavailable optional IPv6 cannot abort an IPv4 install' '
  set -o posix
  curl(){ if [ "$1" = -4 ]; then echo ip=203.0.113.1; else return 7; fi; }
  discover_addresses
  [ "$IP4" = 203.0.113.1 ]; [ -z "$IP6" ]
'
run 'cron: deduplicate legacy and tagged entries; preserve unrelated jobs' '
  INIT=none
  crontab(){ if [ "${1:-}" = -l ]; then cat "$scratch/cron" 2>/dev/null; else cat > "$scratch/next"; mv "$scratch/next" "$scratch/cron"; fi; }
  printf "0 1 * * * echo keep\n@reboot %s start\n@reboot %s start\n" "$CMD" "$CMD" > "$scratch/cron"
  svc_install; svc_install
  [ "$(grep -c "@reboot" "$scratch/cron")" = 1 ]
  grep -q "echo keep" "$scratch/cron"
  svc_stop(){ :; }; svc_remove
  ! grep -q "@reboot" "$scratch/cron"
  grep -q "echo keep" "$scratch/cron"
'
run 'firewall: ACME needs TCP80 only for TLS protocols' '
  DOMAIN=example.com; PORT_hy2=24443
  ports=$(fw_ports)
  grep -qx 80/tcp <<< "$ports"
  grep -qx 24443/udp <<< "$ports"
  PORT_hy2=; PORT_reality=443
  ports=$(fw_ports)
  ! grep -qx 80/tcp <<< "$ports"
'
run 'firewall: user rules survive; only newly added rules tracked' '
  PORT_reality=443; PORT_hy2=444
  echo ufw4:443/tcp > "$scratch/rules"
  mkdir -p /etc/default; echo IPV6=no > /etc/default/ufw
  ufw(){ echo "Status: active"; }
  fw_has(){ grep -qx "$1:$2" "$scratch/rules"; }
  fw_change(){
    if [ "$1" = add ]; then echo "$2:$3" >> "$scratch/rules"
    else sed -i "\\|^$2:$3\$|d" "$scratch/rules"; fi
  }
  fw_open_all
  [[ $FW_RULES != *ufw4-owned:443/tcp* ]]
  [[ $FW_RULES == *ufw4-owned:444/udp* ]]
  fw_close_all
  grep -qx ufw4:443/tcp "$scratch/rules"
  ! grep -q 444/udp "$scratch/rules"
  FW_RULES="ufw:443/tcp"; fw_close_all
  grep -qx ufw4:443/tcp "$scratch/rules"
'
run 'firewall: failed add cannot report success or record ownership' '
  PORT_reality=443
  mkdir -p /etc/default; echo IPV6=no > /etc/default/ufw
  ufw(){ echo "Status: active"; }
  fw_has(){ return 1; }; fw_change(){ return 1; }
  if (fw_open_all); then exit 1; fi
'
run 'transaction: restore config, binary, command and running service' '
  DIR=$scratch/bfc; STATE=$DIR/state; CONF=$DIR/config.json; BIN=$scratch/bin; CMD=$scratch/cmd; INIT=none
  mkdir "$DIR"; echo original > "$CONF"; echo old-bin > "$BIN"; echo old-cmd > "$CMD"; save_state
  echo running > "$scratch/service"
  svc_active(){ [ "$(cat "$scratch/service")" = running ]; }
  svc_stop(){ echo stopped > "$scratch/service"; }
  svc_start(){ echo running > "$scratch/service"; }
  inject(){ svc_stop; echo changed > "$CONF"; echo new > "$BIN"; echo new > "$CMD"; false; echo unexpected > "$scratch/continued"; }
  set +e; transaction inject; status=$?; set -e
  [ "$status" != 0 ]; [ "$(cat "$CONF")" = original ]; [ "$(cat "$BIN")" = old-bin ]; [ "$(cat "$CMD")" = old-cmd ]
  [ "$(cat "$scratch/service")" = running ]; [ ! -e "$scratch/continued" ]; [ ! -e /run/bfc-change.lock ]
'
run 'transaction: originally stopped service stays stopped' '
  DIR=$scratch/bfc; BIN=$scratch/bin; CMD=$scratch/cmd; INIT=none; mkdir "$DIR"
  svc_active(){ return 1; }; svc_stop(){ :; }; svc_start(){ touch "$scratch/started"; }
  inject(){ false; }
  set +e; transaction inject; status=$?; set -e
  [ "$status" != 0 ]; [ ! -e "$scratch/started" ]
'
run 'transaction: new firewall rules removed, old removed rules restored' '
  DIR=$scratch/bfc; BIN=$scratch/bin; CMD=$scratch/cmd; INIT=none; mkdir "$DIR"
  echo ufw4:443/tcp > "$scratch/rules"
  svc_active(){ return 1; }; svc_stop(){ :; }
  fw_has(){ grep -qx "$1:$2" "$scratch/rules"; }
  fw_change(){ if [ "$1" = add ]; then echo "$2:$3" >> "$scratch/rules"; else sed -i "\\|^$2:$3\$|d" "$scratch/rules"; fi; }
  inject(){
    fw_change add ufw4 444/tcp; TXN_ADDED_FW="ufw4-owned:444/tcp"
    fw_change remove ufw4 443/tcp; TXN_REMOVED_FW="ufw4-owned:443/tcp"
    false
  }
  set +e; transaction inject; status=$?; set -e
  [ "$status" != 0 ]; grep -qx ufw4:443/tcp "$scratch/rules"; ! grep -q 444/tcp "$scratch/rules"
'
run 'delete assertion: command failure must fail test' '
  source "$ROOT/tests/lib.sh"
  docker(){ return 19; }
  if assert_deleted mock socks; then exit 1; fi
'
run 'delete assertion: leftover URI must fail test' '
  source "$ROOT/tests/lib.sh"
  docker(){ [ "${3:-}" != sh ]; }
  if assert_deleted mock socks; then exit 1; fi
'
echo "RESULT $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
