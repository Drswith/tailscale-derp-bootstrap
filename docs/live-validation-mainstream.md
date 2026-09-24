# 发行版适配与四台 Ubuntu VPS 复测

> 2026-09-24。本文只记录系统版本、部署方式、端口和验收结论；不写入公网地址、账户、Auth key、证书或设备标识。四台机器在下文称为 01–04。

## 发行版适配的验证边界

- `/etc/os-release` 样例覆盖 Ubuntu 22.04/24.04、Debian 12/13、Fedora 43/44、RHEL 9/10、Rocky Linux 9 与 AlmaLinux 10；Ubuntu 20.04、Linux Mint 和未知系统被拒绝。
- Debian 13 容器从 Tailscale 官方 APT 源查到锁定的 Tailscale 版本，从 Docker 官方 Debian 源查到 Engine、CLI、containerd、Buildx 与 Compose 包。Fedora 43 容器从 Tailscale 官方 RPM 源查到锁定版本，从 Docker 官方 Fedora 源查到上述五个 Docker 包。
- Rocky Linux 9 容器从 Tailscale 官方 RHEL 9 RPM 源查到锁定版本，并从系统仓库安装 `python3.11`，在 Python 3.11 虚拟环境内成功安装和运行锁定的 Certbot 5.8.0。另从 Docker 官方 RHEL 源查到五个 Docker 包；本项目仍要求 Rocky/AlmaLinux 宿主机预先装好 Docker，因为没有在这些衍生系统上验证 Docker CE 的完整安装和服务启动。
- GitHub Actions 的 Ubuntu 24.04 runner 已通过 `tests/local.sh`，并从匹配版本的官方 Go 模块构建 `derper`。首次 CI 运行暴露测试脚本给 Linux `openssl req` 传入不支持的 `-quiet`；移除该参数后，同一测试在 Ubuntu VPS 和 Actions 上均通过。
- 容器检查验证发行版识别与包仓库元数据，不能代替 systemd、Docker daemon、ACME、公网入口和 DERP 中继的实机验收；四台实机均为 Ubuntu 24.04。

## 四台实机

| 机器 | 部署方式 | 初始化状态 | 当前结论 |
| --- | --- | --- | --- |
| 01 | 裸机，交互登录 | 全新重装 Ubuntu 24.04，未装 Tailscale | 设备授权后完成安装；锁定版本 `derper`、Let's Encrypt staging 与正式 IP 证书、续期 dry-run、本地健康检查均通过 |
| 02 | 裸机，Auth key 无头登录 | 全新重装 Ubuntu 24.04，未装 Tailscale | 预检、入口探针与 Tailscale 1.102.4 安装通过；一次性及短期可复用 Auth key 均被控制平面拒绝，完整初始化未通过 |
| 03 | Docker，交互登录 | Ubuntu 24.04，保留先前 Docker 与证书状态 | 新 Tailscale 身份经浏览器授权入网；容器恢复 `healthy`，部署脚本健康检查通过；复用既有正式证书 |
| 04 | Docker，Auth key 无头登录 | Ubuntu 24.04，保留先前 Docker 与证书状态 | 新状态的一次性 Auth key 被控制平面拒绝；已恢复先前身份，容器 `healthy`、健康检查与公网 TLS 通过；新身份的 headless 初始化未通过 |

01、02 的公网 TCP 80 和 52625 均从另一网络经临时 HTTP 监听探针返回 200，探针已停止。01、03、04 的当前服务从外部在 TCP 52625 返回 HTTPS 200，TLS 校验结果均为 0；客户端对 01、03 收到 IPv4 STUN 响应。四台均按 TCP 52625、UDP 3478 和证书所需 TCP 80 配置；未将 DERP 部署在 TCP 443。控制平面从 02、04 直连可达；04 的初次注册日志曾出现短暂 HTTP 502，后续明确返回 Auth key 无效，因此没有将单次 502 当作网络不可用的结论。

04 还对本轮脚本执行了 Docker 环境恢复测试：保留 `/var/lib/docker` 与项目状态，卸载 Ubuntu 的 `docker.io` 和 `docker-compose-v2`（APT 同时卸载 Buildx），确认 `docker` 命令消失，再运行 `docker/deploy.sh install`。脚本装回 Docker Engine 与 Compose，恢复容器至 `healthy`；`docker/deploy.sh check` 和外部 HTTPS 200/TLS 校验均通过，原 Tailscale 身份复用且无需 Auth key 文件。由于镜像已在本机，安装流程无需 Buildx；另核对脚本会选择 Ubuntu 的 `docker-buildx` 包，并将该包装回、验证 `docker buildx version`。这验证了宿主机 Docker 软件包缺失后的恢复，不代替 04 新身份的 Auth key 入网复测。

02、04 的全新状态都复现了 `invalid key: unable to validate API key`。04 的第一次重试只移动了宿主机状态目录，旧容器的绑定挂载仍指向原目录；随后删除并重建容器、挂入真正空白的状态目录后仍复现相同错误。浏览器生成的一次性密钥与 04 的密钥文件逐字节 SHA-256 匹配，02 去掉文件末尾换行、直接传值以及清空 daemon 状态也未改变结果；短期可复用密钥同样失败。另在 GitHub Actions 的全新 Ubuntu 24.04 runner 安装相同的 Tailscale 1.102.4，使用新生成的一次性临时节点密钥仍得到相同错误。这说明问题并非仅发生在中国 VPS 的网络路径上，但尚不能确定控制平面或 tailnet 配置中的具体原因。测试密钥均已撤销，VPS 上的密钥文件与临时 GitHub Secret 均已删除。04 的原有身份已恢复，未把恢复后的健康状态计为全新 headless 初始化成功。

管理控制台已将 01 对应区域更新到重装后的公网地址，并删除指向旧地址、目前无服务的 02 区域；其他区域、grants 与 SSH 策略保持原样。重新读取策略和两台客户端收到的 DERP map 均确认变更。01 与 03 分别作为两个已授权 DERP 节点提供服务：临时阻断测试客户端之间的 UDP 直连后，03 区域完成连续 8 次 DERP ping、TSMP 与 ICMP；01 区域在最初两次连接建立超时后完成连续 6 次 DERP ping、TSMP 与 ICMP。测试后已删除 UDP 阻断规则和强制区域偏好。

01、03、04 的整机重启后 boot ID 均改变，裸机服务与 Docker 容器自动恢复，Tailscale 在线且部署脚本健康检查通过。03、04 的容器证书续期触发路径也成功，之后再次核对实际提供的 TLS。02 尚未完成 DERP 安装，因此没有服务重启结果。

设备授权与 Auth key 生成仍是管理员控制台中的外部步骤。02、04 的全新 headless 初始化和 02 的证书与 DERP 服务仍待完成；此前的双 VPS 验收记录不代替本轮结果。
