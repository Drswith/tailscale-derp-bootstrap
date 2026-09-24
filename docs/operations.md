# 运维与故障排查

[返回项目首页](../README.md) · [裸机部署](deployment/bare-metal.md) · [Docker 部署](deployment/docker.md)

## 日常检查

| 方式 | 健康检查 | 日志与服务 |
| --- | --- | --- |
| 裸机 | `sudo bash install.sh check config.env` | `systemctl status derper derp-cert-renew.timer derp-healthcheck.timer`；`journalctl -u derper -u derp-cert-renew.service -u derp-healthcheck.service --since today` |
| Docker | `sudo bash docker/deploy.sh check docker/config.env` | `sudo bash docker/deploy.sh logs docker/config.env`；容器状态以部署脚本检查结果为准 |

裸机的 `derp-cert-renew.timer` 每天检查三次短期 IP 证书；deploy hook 在续期成功后重启 `derper`，renew 服务再检查服务与实际提供的证书。`derp-healthcheck.timer` 每小时检查 tailnet 身份、节点密钥到期、证书及本机 TLS；失败写入 journal 并使对应 unit 进入 failed 状态。脚本没有内置通知通道，需按运维环境接入告警。重启 `derper` 可能短暂中断经过该区域的连接。

Docker 容器每 8 小时检查续期，更新后重启容器内 `derper` 并验证提供的证书；每小时运行完整健康检查，Docker 自身每分钟执行探测。`restart: unless-stopped` 用于宿主机重启恢复。可以手工触发同一路径：

```bash
sudo bash docker/deploy.sh renew docker/config.env
```

裸机可用 `sudo systemctl start derp-cert-renew.service` 手工复测续期服务，再检查状态与 journal；不要频繁强制生产签发，以免触发 CA 速率限制。正式证书未来到期时的生产续期与升级失败回滚尚未做破坏性实测。

## 升级与状态

`versions.lock` 固定 Tailscale、Go、Certbot 版本以及 Go 归档校验值。`derper` 由 `tailscale.com/cmd/derper@v<版本>` 官方源码构建，并非上游提供的预编译 `derper` 包。升级 Tailscale 时要同步构建对应版本的 `derper`；修改 Go 版本时同步更新官方 SHA-256。

裸机重复运行 `install.sh install` 会复用已在线的 Tailscale 身份和有效证书。锁定的 Tailscale 版本改变后，脚本先构建新 `derper`，配套升级两个组件并健康检查；失败时尝试恢复旧包与旧二进制并报告结果。升级前确认旧版本系统包仍可下载。Certbot 升级会更新独立虚拟环境。APT 路径 hold Tailscale 包，DNF 路径默认禁用 Tailscale 软件源，避免系统单独升级 `tailscaled`。

Docker 的 `docker/state` 必须随容器升级保留。交互登录 URL 与 `docker/secrets/auth.key` 仅用于空白节点状态的首次注册；无交互入网成功后凭据文件会被删除。容器重建不应擦除身份、证书和 `derper` 身份密钥。更换公网 IP 涉及重新签证与修改 DERP 策略；裸机脚本拒绝直接覆盖已有托管 IP 配置，应单独规划迁移。

## 更改既有 DERP 端口

默认端口改为 TCP 52625 仅影响新复制的示例配置和未显式设置 `DERP_PORT` 的配置。已有 `config.env`、`/etc/derp-bootstrap/config.env` 或 `docker/config.env` 若明确写了 443，不会自动迁移。

1. 在维护窗口确认 TCP 52625 未被占用，并在云安全组及宿主机防火墙放行它；保留证书验证所需的 TCP 80、STUN UDP 3478 与 SSH。
2. 将当前部署所用配置的 `DERP_PORT` 改为 `52625`。裸机重新运行 `sudo bash install.sh install config.env`；Docker 重新运行 `sudo bash docker/deploy.sh install docker/config.env`。
3. 用对应的 `check`、`derpmap` 验证，合并更新后的区域配置，并从真实客户端确认经新端口中继。确认生效后再关闭旧的 TCP 443 入站规则；切换期间该区域可能短暂不可用。

## 网络和证书问题

- **下载失败**：先检查本机代理状态、实际端口、hosts 与直连路径，再分别测试 Tailscale 软件源、Docker Hub、Go 下载/模块源、PyPI 和 ACME。只在所需公网请求上配置代理；`NO_PROXY` 排除内网、LAN 与服务发现地址。不要把临时代理端口、密码或令牌写进仓库。Go 模块可用可达的 `GOPROXY`，但保持 `GOSUMDB`；`GO_ARCHIVE_URL` 必须仍通过 `versions.lock` 的 SHA-256 校验。`sudo` 可能清除代理环境变量。
- **证书申请失败**：TCP 80 必须在首次申请与续期时从公网到达并保持空闲。Certbot 的本地监听端口改成其他数字不能替代 HTTP-01 的公网 80；DERP 改到 52625 也不能替代证书验证。裸机 Certbot 只在验证时监听 80；Docker Compose 为自动续期持续发布宿主机 80 端口映射，但容器内仅在验证时监听。先核对云安全组、宿主机防火墙和 NAT 映射，再看 staging/生产 ACME 错误。
- **本机健康但客户端不可用**：`check` 不验证云安全组、STUN 回包、控制台策略是否已生效或真实中继路径。从外部检查 TLS/IP SAN 与 UDP STUN，再从真实已认证客户端确认 DERP map 和实际 `tailscale ping` 路径。`--verify-clients` 还要求服务器上的 Tailscale 节点能按策略看到客户端。
- **误判日志**：官方 `derper` 的 IP `manual` 模式可能打印“Using self-signed certificate”，即使加载了公共 CA 证书；以证书链、IP SAN 和外部 TLS 验证为准。禁用 IPv6 时 `tailscale debug derp` 对 `none` 的连接错误，以及本方案关闭 80 端口 captive portal 检测的提示，不等于 IPv4 DERP 故障。
- **普通 Auth key 注册失败**：最近复测返回 `invalid key: unable to validate API key`，原因仍未确定；不要把它归因于中国 VPS 网络。可对照[四机复测记录](validation/live-validation-mainstream.md)的证据与已验证的专用 tag OAuth 路径。
