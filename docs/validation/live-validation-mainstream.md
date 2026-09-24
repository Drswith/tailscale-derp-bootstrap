# 发行版适配与四台 Ubuntu VPS 复测

> 2026-09-24。本文只记录系统版本、部署方式、端口和验收结论；不写入公网地址、账户、Auth key、证书或设备标识。四台机器在下文称为 01–04。

## 发行版适配的验证边界

- 当前只接受 Ubuntu 22.04/24.04、Debian 12/13、RHEL 9 和 Rocky Linux 9。`/etc/os-release` 样例覆盖这六项；Ubuntu 20.04、Fedora、RHEL 10、Rocky Linux 10、AlmaLinux、Linux Mint 和未知系统均被拒绝。此前曾探索这些额外系统的包仓库，不构成当前支持承诺。
- GitHub Actions 在六种系统的 amd64 容器中调用安装脚本的实际函数，执行基础包安装、Tailscale 软件源配置与锁定包安装、官方 Go 归档下载和 SHA-256 校验、匹配版本 `derper` 构建、锁定版本 Certbot 安装，以及 `tests/local.sh`。Ubuntu、Debian 和 RHEL UBI 9 还安装 Docker CLI、Compose 与 Buildx 并解析 Compose 配置；Rocky Linux 9 检查脚本要求预装 Docker 的明确提示。另一个任务构建 Docker 部署镜像并检查其中的二进制版本。
- RHEL 9 使用公开的 UBI 9 容器作包命令验证；完整 RHEL 宿主机没有实测。Rocky Linux 9 使用 Tailscale 官方 RHEL 9 RPM 源及 Python 3.11；Docker CE 源不自动添加。容器没有 systemd、Docker daemon、ACME 或 tailnet 凭据，所以该矩阵不运行全链路部署。
- 四台 Ubuntu 24.04 VPS 的服务、证书、公网入口、tailnet 和真实 DERP 中继实机结果见下文。其他发行版的整机运行仍需在对应宿主机验收。

## 四台实机

| 机器 | 部署方式 | 初始化状态 | 当前结论 |
| --- | --- | --- | --- |
| 01 | 裸机，交互登录 | 全新重装 Ubuntu 24.04，未装 Tailscale | 设备授权后完成安装；锁定版本 `derper`、Let's Encrypt staging 与正式 IP 证书、续期 dry-run、本地健康检查均通过 |
| 02 | 裸机，OAuth 凭据无交互登录 | 全新重装 Ubuntu 24.04，未装 Tailscale | 从空白 Tailscale 状态执行完整安装；带 tag 的节点自动入网，官方 `derper` 构建、staging 与正式 IP 证书、续期 dry-run、健康检查均通过 |
| 03 | Docker，交互登录 | Ubuntu 24.04，保留先前 Docker 与证书状态 | 新 Tailscale 身份经浏览器授权入网；容器恢复 `healthy`，部署脚本健康检查通过；复用既有正式证书 |
| 04 | Docker，OAuth 凭据无交互登录 | Ubuntu 24.04，保留先前 Docker 与证书状态 | 删除旧容器后挂入空白 Tailscale 状态，新节点自动入网；容器 `healthy`，部署脚本健康检查通过，复用既有正式证书 |

01、02 的公网 TCP 80 和 52625 均从另一网络经临时 HTTP 监听探针返回 200，探针已停止。四台当前服务从外部在 TCP 52625 均返回 HTTPS 200，TLS 校验结果均为 0；客户端对四个区域建立 DERP 连接并收到 IPv4 STUN 响应。四台均按 TCP 52625、UDP 3478 和证书所需 TCP 80 配置；未将 DERP 部署在 TCP 443。`tailscale debug derp` 对不存在的 IPv6 地址 `none` 与关闭的 80 端口 captive portal 检测给出提示，不影响上述 IPv4/TLS 和真实中继结果。

04 还对本轮脚本执行了 Docker 环境恢复测试：保留 `/var/lib/docker` 与项目状态，卸载 Ubuntu 的 `docker.io` 和 `docker-compose-v2`（APT 同时卸载 Buildx），确认 `docker` 命令消失，再运行 `docker/deploy.sh install`。脚本装回 Docker Engine 与 Compose，恢复容器至 `healthy`；`docker/deploy.sh check` 和外部 HTTPS 200/TLS 校验均通过。当时镜像已在本机，安装流程无需 Buildx；另核对脚本会选择 Ubuntu 的 `docker-buildx` 包，并将该包装回、验证 `docker buildx version`。这验证了宿主机 Docker 软件包缺失后的恢复。04 的新版镜像在 VPS 上重建时，Docker Hub 直连超时；本机检查直连和代理均可访问镜像站，于是利用缓存构建 `linux/amd64` 镜像、传到 VPS 加载，再从空白 Tailscale 状态完成容器初始化。VPS 上的源码构建未在本轮重新跑通。

普通 Auth key 路径仍有一项独立故障：02、04 的全新状态都复现了 `invalid key: unable to validate API key`。04 删除并重建容器、挂入真正空白的状态目录后仍复现；浏览器生成的密钥与 04 的密钥文件逐字节 SHA-256 匹配，02 去掉末尾换行、直接传值、清空 daemon 状态及改用短期可复用密钥也没有改变结果。GitHub Actions 全新 Ubuntu 24.04 runner 使用另一枚密钥同样失败，因此不能归因于中国 VPS 的单一路径；具体原因仍未确定。控制台配置日志确认了密钥创建/撤销，设备手动审批与 Tailnet Lock 均未启用，但没有提供注册失败原因。测试密钥均已撤销，VPS 密钥文件与临时 GitHub Secret 均已删除。

为继续完成 headless 验收，在控制台定义管理员拥有的专用 tag，并创建只带 `auth_keys` 权限、限定该 tag 的临时 OAuth 客户端。02、04 的凭据文件分别保存 OAuth client secret，并附加 `ephemeral=false&preauthorized=true`；脚本通过 `TS_ADVERTISE_TAGS` 把 tag 传给 `tailscale up`。02 先用命令行验证此方式可注册，再清空 daemon 状态从头执行安装脚本。04 删除旧容器、挂入空白状态目录，运行容器安装脚本完成新身份注册。成功后两台的凭据文件都被删除；临时 OAuth 客户端已撤销，节点仍在线。OAuth 凭据的创建及 tag/DERP 策略维护是管理员操作，服务器初始化本身无需浏览器交互。02 首次 staging 证书请求收到带 `Retry-After` 的暂时限流，稍后重跑完整脚本后 staging、正式签发和续期 dry-run 均成功。

管理控制台已将 01 对应区域更新到重装后的公网地址，重新加入 02 区域，保留 03、04 区域；其他区域、grants 与 SSH 策略保持原样。重新读取策略和客户端 DERP map 均确认四个区域可见。临时阻断测试客户端之间的 UDP 直连后，03 区域完成 8/8 次 DERP ping，01 区域在最初两次连接建立超时后完成 6/8 次，02 与 04 区域各完成 10/10 次；四个区域均有 TSMP 与 ICMP 成功结果。测试后已删除 UDP 阻断规则和强制区域偏好。

四台整机重启后 boot ID 均改变；裸机服务与 Docker 容器自动恢复，Tailscale 在线且各自部署脚本健康检查通过。02、04 的新身份在重启后仍带专用 tag，凭据文件缺席；从外部再次访问两台的 TCP 52625 均返回 HTTPS 200/TLS 校验 0，两个 DERP 区域仍能建立连接并回复 IPv4 STUN。03、04 的容器证书续期触发路径也成功。此前双 VPS 验收记录对应不同时间的节点状态，不能代替本轮四台 Ubuntu 24.04 的结果。
