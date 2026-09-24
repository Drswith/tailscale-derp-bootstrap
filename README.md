# Tailscale DERP 纯公网 IP 部署

使用纯公网 IPv4、Let's Encrypt IP 证书和官方 `derper` 搭建 Tailscale DERP。提供裸机 systemd 和 Docker Compose 两种独立部署方式；均无需域名、DNS 解析、反向代理或 Headscale。Docker 方式将 Tailscale、`derper` 和 Certbot 运行在同一个容器内，宿主机只需 Docker Engine 与 Compose。

> 部署会安装系统软件、注册当前服务器到指定 tailnet，并开放本机监听端口。裸机方式创建 systemd 单元；Docker 方式在支持的系统上按下表补装 Docker Engine 与 Compose。两种方式都不会修改本机防火墙、云安全组或 tailnet 策略。

## 适用范围和必要条件

- Ubuntu 22.04/24.04、Debian 12/13、Fedora 43/44、RHEL/Rocky Linux/AlmaLinux 9/10；x86_64 或 aarch64，systemd，root 权限，至少 2 GiB 可用磁盘空间。脚本依据 `/etc/os-release` 的发行版和版本选择软件源；未列出的系统会明确拒绝。
- **固定、可从公网访问的 IPv4**。公网 TCP 80 用于首次签发及后续 HTTP-01 续期；TCP 443（或配置的 DERP 端口）用于 DERP；UDP 3478（或配置的 STUN 端口）用于 STUN。保留当前 SSH 端口，并按云厂商和系统规则允许必要的 ICMP 流量。TCP 80 必须在签发/续期时空闲。`derper` 的 HTTP 监听在本方案中关闭，因此不提供该节点的 80 端口 captive portal 检测服务。
- 可访问 Tailscale 软件源、Go 下载站和模块源、PyPI、Let's Encrypt ACME，以及 Tailscale 控制平面。国内网络如果需要代理，只给公网下载客户端配置当时可用的 `HTTPS_PROXY`，并用 `NO_PROXY` 排除内网、LAN 和服务发现地址；Go 模块可通过 `GOPROXY` 选择可达的镜像源，保持 `GOSUMDB` 校验开启。Go 压缩包也可用 `GO_ARCHIVE_URL` 指向可达镜像，安装时仍按 [versions.lock](versions.lock) 的官方 SHA-256 校验。`sudo` 可能不保留这些环境变量，运行前需检查 apt、curl、Go 各自实际使用的路径。不要把代理密码写入仓库或配置文件。预检会单独尝试直连公网 IP 查询。公网入站是否畅通最终由 ACME 验证与外部客户端测试确认。
- 管理员能把服务器加入目标 tailnet，并在网页控制台批准设备（如果启用了设备审批）。可首次交互登录，或通过权限为 `0600` 的文件提供一次性 Auth key。另一种无交互方式是为专用 tag 创建仅有 `auth_keys` 权限的 OAuth 客户端，把客户端 secret 放入同一凭据文件，并设置 `TS_ADVERTISE_TAGS`。带 tag 节点的密钥到期策略仍应在控制台核对。

当前固定版本见 [versions.lock](versions.lock)。`derper` 由服务器从 `tailscale.com/cmd/derper@v<版本>` 构建，**不是 Tailscale 官方提供的 `derper` 二进制包**。Tailscale 系统包与 `derper` 使用相同发布版本；APT 路径会 hold Tailscale 包，DNF 路径将 Tailscale 软件源设为默认禁用，避免系统单独升级 `tailscaled` 造成版本偏离。

| 宿主系统 | 裸机 Tailscale 包 | 缺少 Docker 时的自动安装 |
| --- | --- | --- |
| Ubuntu 22.04/24.04 | Tailscale 官方 APT 源 | Ubuntu 的 `docker.io`、`docker-compose-v2` |
| Debian 12/13 | Tailscale 官方 APT 源 | Docker 官方 Debian CE 源 |
| Fedora 43/44 | Tailscale 官方 Fedora RPM 源 | Docker 官方 Fedora CE 源 |
| RHEL 9/10 | Tailscale 官方 RHEL RPM 源 | Docker 官方 RHEL CE 源 |
| Rocky Linux、AlmaLinux 9/10 | Tailscale 官方 RHEL RPM 源 | 请预先安装可用的 Docker Engine、Compose v2；脚本不自动添加其他发行版的 Docker CE 源 |

这些系统的选择逻辑已用 `/etc/os-release` 样例检查；本次实机安装覆盖 Ubuntu 24.04。其他发行版的包安装、证书和服务运行仍需在对应系统上验收。RHEL 9 系使用 Python 3.11 来运行当前锁定的 Certbot。

## 裸机部署

1. 在服务器克隆本仓库，并创建配置：

   ```bash
   cp config.example.env config.env
   chmod 600 config.env
   # 编辑 PUBLIC_IPV4、ACME_EMAIL、EXPECTED_TAILNET 等字段
   ```

   `PUBLIC_IPV4` 填实际公网 IPv4，示例地址会被拒绝。`EXPECTED_TAILNET` 是 Tailscale tailnet 名，不是 DERP 域名；可在另一台已入网设备上运行 `tailscale status --json | jq -r '.CurrentTailnet.Name'` 查询。`TS_HOSTNAME` 仅为服务器在 tailnet 中的设备名称。`REGION_ID` 取 900–999 内未占用的值。

2. 准备首次登录。使用 Auth key 时，将密钥以 `0600` 权限放在配置指定的 `/run/derp-bootstrap/auth.key`；成功入网后安装脚本会删除**该默认路径**的文件。若使用 OAuth 客户端 secret，先在 tailnet 策略中定义由管理员拥有的专用 tag，再创建仅有 `auth_keys` 权限且限于该 tag 的客户端；在配置中设置 `TS_ADVERTISE_TAGS="tag:你的标签"`。凭据文件可保存 `tskey-client-…?ephemeral=false&preauthorized=true`，使服务器保留持久身份并跳过设备手动批准。不要把凭据值放入配置、命令参数、Git 或长期日志。若选择浏览器交互登录，设 `TS_AUTH_KEY_FILE=""`。

3. 先检查，再安装：

   ```bash
   sudo bash install.sh preflight config.env
   sudo bash install.sh install config.env
   ```

   中国大陆 Linux amd64 主机如果无法稳定直连 Go 模块站或 Go 下载站，可单次传入可达镜像地址，例如当前锁定版本：

   ```bash
   sudo env GOPROXY=https://goproxy.cn \
     GO_ARCHIVE_URL=https://mirrors.aliyun.com/golang/go1.26.8.linux-amd64.tar.gz \
     bash install.sh install config.env
   ```

   `GO_ARCHIVE_URL` 下载内容仍需通过官方 SHA-256 校验，`GOSUMDB` 保持默认开启。镜像、代理端口和可达性应在实际部署时重新检查。

   极简系统若还没有 Python、curl 或 OpenSSL，`preflight` 会提示缺少命令；`install` 会先通过 APT 或 DNF 安装基础工具再执行同样的检查。第一次证书申请会先使用 Let's Encrypt staging 做 `--dry-run`，通过后才申请生产证书。验证失败会停在证书阶段，不会启动自签名 DERP。

4. 安装会打印 `derpMap` JSON 片段。**只将其中的 `derpMap` 合并到现有 tailnet 策略**，保留原有 `grants`/ACL、SSH、tags 等规则，并确认 RegionID 未被使用。不要给节点加 `CertName: "sha256-raw:..."` 或 `InsecureForTests: true`：这里由公共 CA 的 IP SAN 完成正常 TLS 验证。默认保留 Tailscale 官方 DERP 区域。脚本不在公网中继服务器上保存策略修改凭证。

5. 从真实客户端验证：

   ```bash
   sudo bash install.sh check config.env
   systemctl status derper derp-cert-renew.timer derp-healthcheck.timer
   journalctl -u derper -u derp-cert-renew.service -u derp-healthcheck.service --since today
   ```

   在**另一网络**上，用 `openssl s_client -connect <公网IP>:<DERP端口> -verify_ip <公网IP> -verify_return_error` 检查公网 TLS；从 tailnet 客户端运行 `tailscale netcheck` 和 `tailscale ping <另一台设备>`，确认新区域可发现，并在需要中继的连接上实际看到该区域。`--verify-clients` 还要求 DERP 服务器上的 `tailscaled` 能在策略决定的可见范围内看到目标客户端；在服务器用 `tailscale status --json` 检查，必要时按现有策略补最小可见性规则。仅本机 TLS 健康检查通过不代表云安全组和实际中继路径已验收。

## Docker Compose 部署

Docker 入口见 [docker/deploy.sh](docker/deploy.sh)。缺少 Docker 时按上表安装；Rocky Linux 和 AlmaLinux 需要先提供 Docker Engine 与 Compose v2。镜像从锁定版本的官方 Tailscale 镜像复制 `tailscale`/`tailscaled`，并从同版本的 `tailscale.com/cmd/derper` 构建官方 `derper`。容器使用 Tailscale userspace 模式，不需要主机安装 Tailscale、`/dev/net/tun` 或 privileged 模式。Docker 路径和裸机路径不要同时绑定同一组公网端口。

1. 将仓库放到 VPS，复制并编辑 `docker/config.example.env` 为 `docker/config.env`。配置公网 IP、证书邮箱、目标 tailnet、设备名和未占用的 RegionID。示例使用 TCP 52625、UDP 3478；公网 TCP 80 用于 HTTP-01 签发和续期。云安全组和宿主机防火墙需允许这三个入站端口并保留 SSH。该方案不监听 TCP 443，也不提供 DERP 节点的 80 端口 captive portal 检测服务。
2. 交互登录设 `AUTH_MODE="interactive"`；运行 `sudo bash docker/deploy.sh install docker/config.env` 后，用 `sudo bash docker/deploy.sh logs docker/config.env` 查看登录 URL 并批准设备。全自动登录设 `AUTH_MODE="authkey"`，把一次性、非临时 Auth key 或上述 OAuth 客户端 secret 放到 `docker/secrets/auth.key`，权限为 `0600`；OAuth 方式还需在配置中设置 `TS_ADVERTISE_TAGS`。安装脚本只检查文件，不把凭据放到环境变量或 Docker 元数据；容器成功入网后删除该文件。已入网的节点重启时会从 `docker/state/tailscale` 恢复身份，不再需要凭据。
3. 先运行 `sudo bash docker/deploy.sh preflight docker/config.env`。然后运行 `sudo bash docker/deploy.sh install docker/config.env`；它会在支持的系统缺少 Docker 时安装对应软件包，确保 daemon 和 Compose 可用，随后启动容器。如果本机没有对应镜像，会按需检查并安装 Docker Buildx 再构建；构建需要 Docker Hub、PyPI、Go 模块源和 Debian 软件源可达。可用 `GOPROXY=https://goproxy.cn` 指定 Go 模块镜像，保持 Go checksum database 校验开启。
4. 如果 VPS 无法访问 Docker Hub，在能访问镜像源的 amd64 构建机上构建并导出镜像，再把归档传到 VPS。以下命令仅为 amd64 VPS 示例；其他架构将 `--platform` 改为对应值：

   ```bash
   source versions.lock
   docker buildx build --platform linux/amd64 -f docker/Dockerfile \
     --build-arg GO_VERSION="$GO_VERSION" \
     --build-arg TAILSCALE_VERSION="$TAILSCALE_VERSION" \
     --build-arg CERTBOT_VERSION="$CERTBOT_VERSION" \
     -t "derp-bootstrap:$TAILSCALE_VERSION" --load .
   docker save "derp-bootstrap:$TAILSCALE_VERSION" | gzip > /tmp/derp-bootstrap-image.tar.gz
   # 将镜像归档和仓库部署文件安全传至 VPS，然后在 VPS 上运行：
   sudo env IMAGE_ARCHIVE=/path/to/derp-bootstrap-image.tar.gz \
     bash docker/deploy.sh install docker/config.env
   ```

5. 入网和首次签证完成后，运行 `sudo bash docker/deploy.sh check docker/config.env` 和 `sudo bash docker/deploy.sh derpmap docker/config.env`。只把新的区域合并进现有 `derpMap`，保留原有策略，再从公网和真实 tailnet 客户端验收。`docker compose` 的健康状态涵盖 Tailscale 身份、证书链/IP SAN、证书链接及实际提供的 TLS 证书；它不代替公网 UDP STUN 和真实中继测试。

`docker/state` 持久保存 Tailscale 节点身份、Let's Encrypt 账户/证书和 `derper` 身份密钥。证书每 8 小时检查续期，更新后重启容器内的 `derper` 并验证提供的 TLS 证书；每小时执行完整健康检查，Docker 自身每分钟探测。`sudo bash docker/deploy.sh renew docker/config.env` 可立即运行同一续期检查路径而不强制向正式 CA 重签。`restart: unless-stopped` 用于主机重启恢复。不要删除这些状态目录，否则可能重新入网或重新签证。密钥目录、配置和状态目录均被 Git 忽略；不要把真实服务器 IP、邮箱、密钥或证书提交到仓库。

## 维护

- `derp-cert-renew.timer` 每天检查三次短期 IP 证书。续期成功时 deploy hook 重启 `derper`；renew 服务随后核对服务状态和实际提供的证书。钩子失败未必使 Certbot 本身返回失败，因此这个后置检查是必需的。重启可能短暂中断经过该 DERP 的连接。
- 当前官方 `derper` 的 IP `manual` 模式可能在日志里打印“Using self-signed certificate”，即使它加载的是 CA 签发的证书；以 `check` 和外部 TLS 验证结果为准。
- `derp-healthcheck.timer` 每小时检查 tailnet 身份、节点密钥到期、证书有效期、证书链接、服务和本机 TLS。失败会使对应 systemd unit 进入 failed 状态并写入 journal；请为这些 unit 接入自己的监控告警。脚本没有内置通知通道。
- 手工复测续期链路：`sudo systemctl start derp-cert-renew.service`，然后检查 `systemctl status` 与 journal。不要频繁强制生产续期，以免触发 CA 速率限制。
- 重复运行 `sudo bash install.sh install config.env` 不会重新注册已在线节点，也不会在证书仍有效时重复签发。修改 [versions.lock](versions.lock) 中的 Tailscale 版本后再运行安装命令，会预先构建相应 `derper`，配套升级两个组件并做健康检查。升级前必须确认旧发行版包仍可下载；失败时脚本尝试恢复旧包与旧二进制，并报告回滚结果。修改 Go 版本时同步更新官方 SHA-256。升级 `Certbot` 版本会更新独立虚拟环境。
- 更换公网 IP 会影响证书和策略，脚本拒绝直接覆盖已有的托管 IP 配置；请单独规划迁移。若 TCP 80 被其他服务占用，续期会失败，不能把 Certbot 的监听端口改成其他数字来规避公网 HTTP-01 的 80 端口要求。

## 本地验证

```bash
bash tests/local.sh
```

这个测试覆盖发行版识别、配置与 `derpMap` 生成、证书 IP SAN/私钥/有效期校验、证书链接防误指向、Docker 脚本语法和可用时的 Compose 配置解析。GitHub Actions 还会在 Linux 上构建锁定版本的官方 `derper`。每台目标服务器的软件包、Docker/systemd、ACME、公网连通性、tailnet 可见性和客户端中继仍需分别验收；升级失败回滚也需要单独验证。

首台测试 VPS 的部署、证书、续期模拟、重启和真实客户端中继结果见[已脱敏的实机验收记录](docs/live-validation-primary.md)。

第二台全新测试 VPS 使用一次性 Auth key 完成无交互安装、重复运行、重启和真实中继复测，见[已脱敏的二次验收记录](docs/live-validation-secondary.md)。

Docker Compose 在两台新 VPS 上完成交互与无人值守部署、缺失 Docker 环境恢复、证书和真实中继验证，见[已脱敏的 Docker 验收记录](docs/live-validation-docker.md)。

发行版扩展的包仓库检查及四台 Ubuntu 24.04 VPS 本轮复测见[已脱敏的复测记录](docs/live-validation-mainstream.md)。

## 依据

- [Tailscale 自建 DERP 指南](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers)、[官方 `derper` README](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/derper/README.md) 与 [证书加载源码](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/derper/cert.go)。
- [Let's Encrypt IP 地址证书公告](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)、[Certbot IP 证书说明](https://letsencrypt.org/2026/03/11/shorter-certs-certbot)、[Certbot 续期钩子文档](https://eff-certbot.readthedocs.io/en/stable/using.html#renewing-certificates)。
- [Tailscale 官方软件源](https://pkgs.tailscale.com/stable/)、[OAuth 客户端注册节点说明](https://tailscale.com/docs/features/oauth-clients)、[Docker 官方安装文档](https://docs.docker.com/engine/install/) 与 [Go 官方下载校验值](https://go.dev/dl/?mode=json)。
