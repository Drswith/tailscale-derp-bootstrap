# Tailscale DERP 纯公网 IP 部署

用固定公网 IPv4 和 Let's Encrypt IP 证书部署官方 `derper`，无需域名或 DNS。项目提供两种独立入口：裸机 systemd 和 Docker Compose。两者都使用 [versions.lock](versions.lock) 固定的 Tailscale 版本，并从同版本官方源码构建 `derper`。

> 安装会改动服务器的软件包、服务和 Tailscale 节点状态。脚本不会修改云安全组、本机防火墙或 tailnet 策略；这些入口与策略需要管理员单独配置、验收。

## 在 VPS 上获取完整项目

本项目包含脚本、`lib/`、`docker/` 和版本锁定文件，不能只下载 `install.sh` 或 `docker/deploy.sh` 后运行。在 VPS 上复制：

```bash
git clone --depth 1 https://github.com/Drswith/tailscale-derp-bootstrap.git
cd tailscale-derp-bootstrap
```

若 VPS 尚无 Git，先运行 `sudo apt-get update && sudo apt-get install -y git`。下文命令都在**仓库根目录**执行。

## 选择部署方式

| 方式 | 安装命令 | 宿主机要求 | 默认 DERP TCP 端口 |
| --- | --- | --- | --- |
| 裸机 | `sudo bash install.sh install config.env` | systemd；脚本安装 Tailscale、Go、Certbot 和 `derper` | 默认 TCP 52625 |
| Docker | `sudo bash docker/deploy.sh install docker/config.env` | systemd；Docker Engine 与 Compose v2，支持的系统缺失时可自动补装 | 默认 TCP 52625 |

支持 Ubuntu 22.04/24.04、Debian 12/13 的 x86_64 或 aarch64 主机；需要 root 权限、至少 2 GiB 可用磁盘空间，以及可从公网访问的固定 IPv4。完整软件源及验证范围见[兼容性与验收](docs/verification.md)。

两种方式均默认让 DERP 使用 TCP **52625**、STUN 使用 UDP **3478**；DERP 默认不占用常见的 TCP 80、443、8080 端口，并保留 SSH。

当前无域名的公网 IP 证书使用 [Let's Encrypt HTTP-01](https://letsencrypt.org/docs/challenge-types/)，**签发和自动续期仍要求公网 TCP 80 可达**，不能将验证端口改为 52625。`derper` 自带的 80 端口 HTTP 服务已关闭，Certbot 只在验证时监听 80；Docker Compose 为支持自动续期仍会持续发布宿主机 80 端口映射。若云服务商不允许公网 80，本项目当前的自动签证方案无法工作，单改 `DERP_PORT` 不能解决。

已有部署的配置文件不会随默认值变化自动改端口；从 443 迁移的步骤见[运维说明](docs/operations.md#更改既有-derp-端口)。

管理员还需要准备目标 tailnet 的登录方式，并把脚本打印的 `derpMap` 区域**合并**到现有策略，保留已有区域、grants/ACL、SSH 和 tags。`EXPECTED_TAILNET` 是 tailnet 名称，`REGION_ID` 必须在 900–999 中选一个未占用值。

## 快速开始

先按上文克隆完整仓库，再选择**一种**方式部署；不要让两种方式占用同一组端口。以下命令假设当前目录是 `tailscale-derp-bootstrap`。

### 裸机

```bash
cp config.example.env config.env
chmod 600 config.env
vi config.env
```

把示例公网 IP、邮箱、tailnet、节点名称和区域改成实际值；`DERP_PORT` 已默认为 `52625`。交互登录时设 `TS_AUTH_KEY_FILE=""`；无人值守登录按[裸机部署指南](docs/deployment/bare-metal.md)准备权限为 `0600` 的凭据文件，配置中只填路径。保存后执行：

```bash
sudo bash install.sh preflight config.env
sudo bash install.sh install config.env
```

完成 Tailscale 登录和需要的设备批准后验收：

```bash
sudo bash install.sh check config.env
sudo bash install.sh derpmap config.env
```

专用 tag 的 OAuth 客户端已在实机复测中验证。认证、网络镜像和完整验收步骤见[裸机部署](docs/deployment/bare-metal.md)。

### Docker Compose

```bash
cp docker/config.example.env docker/config.env
chmod 600 docker/config.env
vi docker/config.env
```

把示例公网 IP、邮箱、tailnet、节点名称和区域改成实际值。示例使用 TCP 52625。交互登录保留 `AUTH_MODE="interactive"`；无人值守登录按[Docker 部署指南](docs/deployment/docker.md)配置 `AUTH_MODE="authkey"` 和权限为 `0600` 的凭据文件。保存后执行：

```bash
sudo bash docker/deploy.sh preflight docker/config.env
sudo bash docker/deploy.sh install docker/config.env
```

交互登录时另开终端运行 `sudo bash docker/deploy.sh logs docker/config.env` 获取登录 URL，完成登录和需要的设备批准后按 Ctrl+C 停止跟随日志。然后验收：

```bash
sudo bash docker/deploy.sh check docker/config.env
sudo bash docker/deploy.sh derpmap docker/config.env
```

缺少 Docker、国内网络无法拉取镜像、离线导入镜像等操作见[Docker 部署](docs/deployment/docker.md)。

## 复制给 Agent 的任务提示词

将下面整段复制给可以访问 VPS 的 Agent；它会先收集缺少的部署参数，再选择对应模式执行：

```text
请帮我部署并验证 https://github.com/Drswith/tailscale-derp-bootstrap 的 Tailscale DERP 服务。

先获取完整仓库，不要只下载单个脚本。阅读当前 README.md、AGENTS.md、对应的 docs/deployment/ 指南、配置示例及 versions.lock；若你的环境已安装本项目 Skill，也按需使用。

请一次性询问我尚未提供的 SSH 目标与登录方式、公网 IPv4、证书邮箱、tailnet 名称、设备名、未占用的 DERP Region ID、裸机或 Docker 模式、交互或无人值守入网方式。默认规划 DERP TCP 52625、STUN UDP 3478，并保留 SSH；DERP 不使用 TCP 80、443、8080。当前 Let's Encrypt IP 证书仍要求公网 TCP 80 用于 HTTP-01 签发与续期，不能把验证端口改为 52625；如云服务商禁止 TCP 80，先说明此方案的限制。密钥只放目标机权限为 0600 的凭据文件，不要让我在聊天、命令参数或 Git 中粘贴密钥。配置文件由 shell 加载，只写入可信数据。

在目标 VPS 上确认系统支持范围、架构、磁盘、端口和云安全组；从仓库根目录复制并编辑对应 config.example.env，然后运行相应入口的 preflight、install、check、derpmap。交互登录需要我在网页完成授权时，把登录 URL 告诉我并等待完成；Docker 模式从 logs 获取 URL。若国内网络下载失败，分别检查直连、当前代理及对应客户端的可达性，再按需配置代理或镜像，不要把临时代理地址写进仓库。

只将新的 DERP 区域合并进现有 tailnet 策略，保留已有官方区域、grants/ACL、SSH 和 tags；若你没有策略权限，给我可合并的片段和具体操作。最后从外部网络检查公网 TLS 证书的 IP SAN、TCP 和 UDP STUN，并用已认证的真实 tailnet 客户端确认有效 DERP map 和实际中继路径。分别报告安装、服务、证书、公网入口、策略与真实中继的已验证结果及未完成项。
```

## 验收与文档

`install.sh check` / `docker/deploy.sh check` 只验证本机或容器状态。完成策略合并后，还需从外部网络验证公网 TLS、UDP STUN，并用真实 tailnet 客户端确认经新增 DERP 区域中继。`bash tests/local.sh` 是本地保护测试；GitHub Actions 的四项发行版矩阵只检查 amd64 包命令与构建，不能代替整机部署。[四台 Ubuntu 24.04 VPS 的复测](docs/validation/live-validation-mainstream.md)逐项记录了新装、状态复用、真实中继及普通 Auth key 的未解决故障。

- [裸机部署](docs/deployment/bare-metal.md) · [Docker 部署](docs/deployment/docker.md)：准备、安装、登录和首次验收
- [运维与故障排查](docs/operations.md)：续期、重启、升级和网络诊断
- [兼容性与验收](docs/verification.md)：支持矩阵、自动化测试范围及历史实机记录
- [AGENTS.md](AGENTS.md)：仓库协作规则；[项目 Skill](.agents/skills/tailscale-derp-bootstrap/SKILL.md)：供兼容 Agent Skills 的工具按需加载

可用 [skills.sh CLI](https://www.skills.sh/docs/cli) 发现本地 Skill：`npx skills add . --list`；从 GitHub 安装到 Codex：`npx skills add Drswith/tailscale-derp-bootstrap --skill tailscale-derp-bootstrap -a codex -g`。之后用 `npx skills update tailscale-derp-bootstrap -g` 更新，或用 `npx skills remove --global tailscale-derp-bootstrap` 移除。

## 上游资料

[Tailscale 自建 DERP](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers) · [官方 `derper`](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/derper/README.md) · [Let's Encrypt IP 证书](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability) · [Tailscale 软件源](https://pkgs.tailscale.com/stable/) · [Docker Engine 安装](https://docs.docker.com/engine/install/)
