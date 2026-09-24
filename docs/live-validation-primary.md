# 首台测试 VPS 实机验收

> 本记录已脱敏：省略公网地址、设备名称、区域代号及可关联证书的具体日期；保留验证方法和结果。文中的占位符不是实际测试值。

## 环境与部署结果

- Ubuntu 24.04.4 LTS、x86_64、systemd；公网 IPv4 经云 NAT 映射到服务器。
- Tailscale 与官方 `derper` 均为 `v1.102.4`；服务器加入目标 tailnet 且在线，`derper` 启用 `--verify-clients`。
- DERP 使用公网 TCP `52625`，STUN 使用 UDP `3478`，Certbot HTTP-01 使用 TCP `80`。DERP 没有监听 TCP `443`。
- Let's Encrypt staging HTTP-01、正式 IP 证书签发和续期 dry-run 均成功。正式证书的 IP SAN 与部署配置中的公网 IPv4 一致。
- `derper`、证书续期定时器、健康检查定时器均开机启用。重启 VPS 后服务和定时器自动恢复，`install.sh check` 通过。

## 网络与客户端证据

- 外部客户端直连 TCP `80`、`52625` 的临时 HTTP 探针均返回 200；UDP `3478` 的临时探针收到回包。探针已退出。
- 外部客户端以部署公网 IPv4 对 TCP `52625` 执行 `openssl s_client -verify_ip <公网IPv4> -verify_return_error`，返回 `Verification: OK`；重启 VPS 后再次通过。
- 管理控制台保留原有 grants、SSH 配置和既有区域，只添加首台测试区域；客户端收到新区域。`tailscale netcheck` 显示该区域延迟约 23 ms；`tailscale debug derp <区域ID>` 能建立 DERP 连接并收到 IPv4 STUN 响应。
- 测试客户端曾将新区域设为当前中继，VPS 上能看到来自该客户端的已建立 TCP 连接。`tailscale debug derp` 使用临时随机节点密钥时，服务端日志明确以“not found in local tailscaled”拒绝该密钥，验证了客户端准入检查。
- VPS 向另一台真实 tailnet 客户端连续发送三次 `tailscale ping`，返回均明确标记经新增 DERP 区域中继，延迟约 27–38 ms。随后 TSMP ping 也成功。测试无需修改主机防火墙。
- `tailscale debug derp` 还报告 IPv6 `none` 连接错误和 80 端口 captive portal 检测警告。官方 `DERPNode` 定义将 `IPv6: "none"` 作为禁用 IPv6 的约定；本项目故意关闭 `derper` 自带的 80 端口 HTTP 服务。

## 国内网络处理与修复

- Tailscale apt 软件源、PyPI、Let's Encrypt ACME 和控制平面可直连；Go 官方压缩包地址间歇可直连，`proxy.golang.org`、`sum.golang.org` 直连超时。实测使用 `GOPROXY=https://goproxy.cn`，并保持 Go 校验开启；Go 压缩包由阿里云镜像下载，再按官方 SHA-256 校验。
- 实测修复了邮箱形式 tailnet 名误拒绝、预检误测 Go 下载页面、Go 解压目录与执行路径不一致、Certbot 非交互续期随机休眠，以及证书部署钩子重启后过早检测 TLS 的问题。
- 续期服务的“尚未到期”路径、staging 模拟续期和带 deploy hook 的模拟续期均已通过。Certbot 本身可能在 hook 失败时仍返回成功，因此部署钩子与服务提供的证书仍需分别检查。

## 尚未覆盖

- 仍未测量长期业务流量的吞吐、丢包与负载；三次经 DERP 的 Tailscale 探测包只证明该中继路径当时可用。
- 正式证书未来到期时的生产续期，以及版本升级失败后的回滚，尚未做破坏性模拟。
