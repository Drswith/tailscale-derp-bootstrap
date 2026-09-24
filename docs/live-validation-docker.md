# Docker Compose 双 VPS 实机验收

> 本记录已脱敏：省略公网与内网地址、账户、设备名称、区域编号、证书序列号及密钥。两台测试机以下分别称为 A（交互登录）和 B（无人值守登录）。

## 环境与初始化

- A、B 均为新建 Ubuntu 24.04 x86_64 VPS，初始没有 Docker Engine、Compose 或 Tailscale。两台机器均需公网 TCP 80、52625 和 UDP 3478 入站；部署不监听 TCP 443。首次签证前，从外部对 TCP 80、52625 的临时监听探针均收到响应。
- Ubuntu 软件源可提供 `docker.io` 和 `docker-compose-v2`。VPS 直连 Docker Hub 认证端点超时，构建机可获取基础镜像，因此在构建机生成 `linux/amd64` 镜像归档，通过 SHA-256 核对后传入两台 VPS，再用 `IMAGE_ARCHIVE` 安装。VPS 对 PyPI、Let's Encrypt ACME 可直连；Go 官方模块代理直连超时，国内镜像可达。这些网络结论仅适用于本次测试环境。
- A 在容器日志中给出登录 URL，由管理员完成浏览器登录和设备批准。B 预置仅使用一次、权限为 `0600` 的 Auth key 后，服务器安装与入网无需交互；成功后容器删除密钥文件。Auth key 生成、设备批准和 tailnet 策略修改属于管理员在控制台完成的外部步骤。
- 容器内使用与 `derper` 相同的 Tailscale 锁定版本、userspace 模式，以及 `--verify-clients`；宿主机无需 Tailscale、TUN 设备或 privileged 权限。A、B 首次安装均先通过 Let's Encrypt staging HTTP-01 dry-run，再取得公共 CA 的公网 IP 证书。

## Docker 环境缺失与状态恢复

- B 额外执行了一次包级复测：保留 `/var/lib/docker` 与项目状态目录，仅卸载 `docker.io`、`docker-compose-v2`，确认 `docker` 命令不存在，再运行 `docker/deploy.sh install`。脚本自动从 Ubuntu 软件源装回两个包、启动 daemon、载入镜像归档并使容器达到 `healthy`。
- 首次包级复测发现：卸载后仍在运行的 `docker.socket` 在重装时失去 socket 文件描述符，`dockerd -H fd://` 无法启动。部署脚本现会在 daemon 不可用时重置失败状态并重启 `docker.socket`，随后启动 `docker.service`。修复后再次从缺失 Docker 的状态完整执行，安装命令以 0 退出。
- Ubuntu 的 `docker.io` 加 Compose 软件包未附带 Buildx。脚本在确需本地构建且 `docker buildx` 不可用时按需安装 `docker-buildx`；B 实际通过该函数安装 Buildx，并完成一次无公网依赖的最小镜像构建。完整 DERP 镜像仍使用构建机归档，因为 VPS 无法直连 Docker Hub。
- B 的 Auth key 已删除后重新安装、重建容器，均复用已保存的 Tailscale 状态，无需重新签发证书或再次输入密钥。A 重建容器后也沿用原有节点状态。

## 证书、公网与真实中继

- A、B 的 `docker/deploy.sh check` 均通过：Tailscale 节点在线，证书链可信且 IP SAN 对应各自公网地址，`derper` 实际提供的证书与状态目录中的证书一致。公网 HTTPS 在 TCP 52625 返回 HTTP 200，TLS 验证结果为 0；两台机器均未监听 TCP 443。
- 两台机器的 `certbot renew --dry-run` staging 模拟续期通过；`docker/deploy.sh renew` 触发容器内定时续期相同路径，并复核了实际提供的 TLS 证书。尚未模拟正式证书到期后的真实生产续期。
- 管理员将 A、B 的区域合并到已有 `derpMap`，保留其他区域及原有策略。客户端收到两个区域。`tailscale debug derp` 对 A、B 都能建立 DERP 连接并收到 IPv4 STUN 响应；调试命令使用随机节点密钥，被服务端 `--verify-clients` 拒绝，这与真实客户端成功中继是两项不同检查。
- 在两台已认证客户端之间临时阻断公网和内网 UDP 直连、指定新区域后，每个区域均完成连续 8 次经该 DERP 的 `tailscale ping`、TSMP 检查和系统 ICMP 3/3。测试规则与强制区域偏好均已清除，客户端恢复原有直连路径。
- `tailscale debug derp` 的 IPv6 `none` 报错来自测试命令探测禁用的 IPv6 地址；80 端口 captive portal 警告来自本方案关闭 `derper` 自带 HTTP 监听。IPv4 DERP、STUN 和真实客户端中继分别已通过。

## 重启与边界

- A、B 的整机重启后 boot ID 均改变，Docker daemon 与容器自动恢复。`docker/deploy.sh check` 再次通过；Tailscale 节点公钥、证书 SHA-256 指纹和 `derper` 身份密钥哈希与重启前逐项一致。外部直连 HTTPS 均返回 200 且 TLS 校验结果为 0；客户端再次对两个区域建立 DERP 连接并收到 IPv4 STUN 响应。B 仍无 Auth key 文件。
- 当前未验证长期吞吐、丢包、正式证书到期续期或升级失败回滚。中国网络下不能假设 VPS 可直接构建镜像；`IMAGE_ARCHIVE` 提供了经实测可用的离线镜像传输入口。
