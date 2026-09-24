# 第二台测试 VPS 无人值守复测

> 本记录已脱敏：省略公网与内网地址、设备名称、区域代号及可关联证书的具体日期；保留验证方法和结果。文中的占位符不是实际测试值。

这是较早一轮一次性 Auth key 成功的验收。服务器后来重装；[2026-09-24 复测](live-validation-mainstream.md)在空白状态下复现普通 Auth key 注册失败，并改用专用 tag 的 OAuth 客户端完成无人值守初始化。两个记录对应不同测试轮次。

## 无人值守初始化

- 全新 Ubuntu 24.04.4 LTS、x86_64、systemd VPS。部署前没有安装 Tailscale，TCP 80/52625 与 UDP 3478 均空闲，UFW 未启用。
- 在 Tailscale 管理控制台预先生成一次性、非临时 Auth key，设置 1 天有效期；仅将密钥以 `0600` 权限放入 VPS 的 `/run/derp-bootstrap/auth.key`，配置文件内只有该路径。密钥没有进入仓库或安装命令参数。整个 `install.sh install` 无人工输入并以 0 退出，测试设备自动加入目标 tailnet、在线，脚本随后删除 VPS 上的密钥文件；本机暂存副本也已删除。
- 预置 Auth key 是无人值守安装的外部输入。此次仍由管理员将脚本生成的第二个测试区域合并到 tailnet 策略；安装器没有在公网 VPS 上保存策略管理凭据。因此验收结论是**服务器初始化全程 headless**，不包含 Auth key 生成与 tailnet 策略变更的自动化。
- 锁定的 Tailscale 与官方源码构建的 `derper` 均为 `v1.102.4`。Go 模块源 `proxy.golang.org` 直连超时，`goproxy.cn` 可达；本次使用 `GOPROXY=https://goproxy.cn` 且保持 `GOSUMDB` 开启。Go 1.26.8 压缩包从阿里云镜像下载并通过 `versions.lock` 的 SHA-256 校验。Tailscale apt、PyPI 与 Let's Encrypt ACME 在该 VPS 可达，未配置持久代理。
- 密钥已删除后再次运行同一安装命令，成功复用在线 Tailscale 身份和现有 `derper`，未重新注册设备或重复签发正式证书；再次完成 staging 续期模拟和健康检查。

## 证书、服务与重启

- 公网 TCP 80、52625 的临时 HTTP 探针均返回 200。Let's Encrypt staging HTTP-01、正式 IP 证书签发和安装阶段续期 dry-run 成功。正式证书 IP SAN 与部署配置中的公网 IPv4 一致。
- 公网 DERP HTTPS（TCP 52625）返回 200，TLS 校验结果为 0；服务仅监听 TCP 52625 和 UDP 3478，没有监听 TCP 443。公网 UDP 3478 收到 `derper` 对 Tailscale 格式 STUN 请求的成功响应。普通裸 STUN 请求会被忽略，因为服务要求 `tailnode` SOFTWARE 属性和正确的 FINGERPRINT；此前裸请求超时不代表云入站不通。
- `derp-cert-renew.service` 的未到期路径通过。单独执行 staging `renew --dry-run --run-deploy-hooks` 成功，部署钩子输出 `derper loaded the renewed public CA certificate`，并检查服务实际提供的证书。
- VPS 重启前后 boot ID 不同；重启后 `tailscaled`、`derper`、证书续期定时器和健康检查定时器均为 enabled/active。`install.sh check`、公网 TLS 与公网 STUN 再次通过，`/run/derp-bootstrap/auth.key` 仍不存在。

## 策略与真实中继

- 管理控制台仅增加第二个测试区域，原有区域及 grants、SSH 策略保留。保存后重新读取策略与提交内容完全一致；客户端和 VPS 的 `tailscale debug derp-map` 均收到该区域。
- 客户端的 `tailscale netcheck` 测得新区域约 23–74 ms（两次测量网络状态不同）。`tailscale debug derp <区域ID>` 验证公网 DERP/TLS 与 IPv4 STUN；它使用随机节点密钥，服务端日志明确以 `not found in local tailscaled` 拒绝该密钥，证明 `--verify-clients` 准入检查生效。该命令自身显示连接成功并不等于随机密钥通过授权。
- 首台测试 VPS 作为真实已认证客户端连接到了第二个测试区域。临时仅阻断两台 VPS 之间的公网及内网 UDP 直连时，第二台向第一台连续 8 次 `tailscale ping` 均明确显示经第二个 DERP 区域中继，约 6 ms；同样阻断下，TSMP 探测成功，系统 ICMP 3/3 成功，平均约 6.8 ms。临时规则已清理，随后两台 VPS 的 Tailscale 路径恢复到内网 UDP 直连。
- 第一台 VPS 在策略变更后再次通过 `install.sh check`。测试结束时已清除各客户端的临时 DERP 区域偏好；测试客户端恢复为其正常最近区域。
- 管理控制台显示第二台测试设备在线，节点密钥将在约 6 个月后到期。此次测试密钥没有附加 tag；长期运行时需单独安排节点密钥到期策略。

## 未覆盖

- 尚未验证正式证书到期时的生产续期、长期业务流量的吞吐与丢包、以及锁定版本升级失败后的回滚。
- 管理控制台生成 Auth key 与合并 `derpMap` 仍是外部管理步骤；此轮只证明给定配置和预置一次性凭据后，空白 VPS 可无人值守初始化。
