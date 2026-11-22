# 不翻车一键部署

在 VPS 上粘贴一条命令，装好自用的 sing-box 节点。网页上选协议、生成命令：<https://bufanche.com/tools/deploy/>

```bash
curl -fsSLo bfc.sh https://bufanche.com/deploy.sh && sh bfc.sh --reality --hy2
```

不带参数时默认装 VLESS + REALITY（TCP 443）和 Hysteria2（UDP 443），并开启 BBR。

## 支持什么

**协议**（sing-box 1.14 的全部代理入站）：VLESS + REALITY、Hysteria2、TUIC v5、AnyTLS、Shadowsocks 2022、ShadowTLS v3、Trojan、VMess + WebSocket、NaiveProxy、Hysteria v1、Snell v5、SOCKS5，以及 Cloudflare 隧道（sing-box 内置的 cloudflared 入站）。

**系统**：Debian 12、13，Ubuntu 20.04、22.04、24.04，Rocky Linux / AlmaLinux 8、9，CentOS Stream 9，Alpine 3.18 以上。systemd、OpenRC 都支持；没有 init 系统的容器用 crontab 开机启动。CPU 支持 x86_64、ARM64、ARMv7。

**优化**：BBR + fq；按带宽和延迟计算 TCP 缓冲区；小内存机器加 swap。

## 和别的一键脚本有什么不同

- **命令里看得到装了什么。** 选项全写在命令上，加 `--dry-run` 只列清单不改系统。
- **锁定版本。** sing-box 版本和每个架构的 sha256 写死在脚本里，对不上就停止安装。
- **密钥在服务器上生成。** 网页只拼命令，不发请求，也不收集任何数据。
- **不碰别的东西。** 不换内核、不改 SSH；端口被占就换一个；服务名是 `bfc`，和你自己装的 sing-box 不冲突。
- **能撤回。** 改过的防火墙规则、sysctl、swap 都记在状态文件里，`bfc uninstall` 逐项撤回。
- **重跑结果不变。** 同一条命令再跑一次，密钥和端口沿用上次的，节点链接不变。
- **代理用户碰不到本机。** 默认拒绝经代理访问服务器本机和内网地址。

## 管理

| 命令 | 作用 |
|---|---|
| `bfc` | 管理菜单 |
| `bfc info` / `bfc qr` | 节点链接 / 二维码 |
| `bfc add --tuic --anytls` | 增加协议 |
| `bfc del tuic` | 删除协议 |
| `bfc restart` / `bfc log` | 重启 / 日志 |
| `bfc update` | 更新脚本和 sing-box，链接不变 |
| `bfc uninstall` | 卸载 |

全部选项：`sh bfc.sh --help`

## 文件

| 位置 | 内容 |
|---|---|
| `/usr/local/bin/bfc-sing-box` | sing-box 官方 musl 静态版 |
| `/usr/local/bin/bfc` | 本脚本 |
| `/etc/bfc/` | 配置、密钥、证书、节点链接（仅 root 可读） |
| `/etc/sysctl.d/99-bfc.conf` | BBR、TCP 调优（选了才有） |

## 测试

`tests/docker-test.sh` 在各发行版容器里安装，再用本机 sing-box 当客户端逐个协议实际连通，最后测 `bfc del`、`bfc add`、重跑和卸载。

```bash
tests/docker-test.sh debian:12 ubuntu:24.04 alpine:3.22
```

## 许可

MIT。sing-box 本身是 GPL-3.0，本脚本只下载它的官方发布版，不包含其代码。
