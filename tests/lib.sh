# 测试共用：用本机 sing-box 当客户端，经指定出站打开网页
# test_client '<出站 JSON，ShadowTLS 是两个对象用逗号连起来>'
test_client() {
  local ob=$1 tag cfg pid ok=1
  tag=$(echo "[$ob]" | jq -r '.[0].tag')
  cfg=$(mktemp)
  echo "[$ob]" | jq --arg t "$tag" '{log:{level:"error"},inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:17890}],outbounds:[.[] | if .server then .server="127.0.0.1" else . end],route:{final:$t}}' > "$cfg"
  sing-box run -c "$cfg" >/tmp/bfc-client.log 2>&1 & pid=$!
  sleep 1.5
  curl -s --max-time 12 -x socks5h://127.0.0.1:17890 https://www.cloudflare.com/cdn-cgi/trace | grep -q '^ip=' && ok=0
  kill $pid 2>/dev/null; wait $pid 2>/dev/null; rm -f "$cfg"
  return $ok
}

# 把 client.json 里每个节点都测一遍；$1 = client.json 路径
test_all_clients() {
  local f=$1 i ob tag fail=0
  for i in $(jq '.outbounds | length - 1' "$f" | xargs seq 0); do
    ob=$(jq -c ".outbounds[$i]" "$f"); tag=$(echo "$ob" | jq -r .tag)
    [[ $tag == *-tls ]] && continue   # ShadowTLS 外层，和前一个一起测
    [[ $tag == *ShadowTLS* ]] && ob="$ob,$(jq -c ".outbounds[$((i+1))]" "$f")"
    if test_client "$ob"; then echo "  ✓ $tag"; else echo "  ✗ $tag"; tail -3 /tmp/bfc-client.log; fail=1; fi
  done
  return $fail
}
