# Tailscale DERP 纯公网 IP 部署

用固定公网 IPv4 和 Let's Encrypt IP 证书部署官方 `derper`，无需域名或 DNS。项目提供两种独立入口：裸机 systemd 和 Docker Compose。两者都使用 [versions.lock](versions.lock) 固定的 Tailscale 版本，并从同版本官方源码构建 `derper`。

> 安装会改动服务器的软件包、服务和 Tailscale 节点状态。脚本不会修改云安全组、本机防火墙或 tailnet 策略；这些入口与策略需要管理员单独配置、验收。

## 选择部署方式

| 方式 | 入口 | 宿主机要求 | 示例 DERP 端口 |
| --- | --- | --- | --- |
| 裸机 | [install.sh](install.sh) | systemd；脚本安装 Tailscale、Go、Certbot 和 `derper` | 示例配置默认 TCP 443 |
| Docker | [docker/deploy.sh](docker/deploy.sh) | systemd；Docker Engine 与 Compose v2，支持的系统缺失时可自动补装 | 示例配置默认 TCP 52625 |

支持 Ubuntu 22.04/24.04、Debian 12/13、RHEL 9、Rocky Linux 9 的 x86_64 或 aarch64 主机；需要 root 权限、至少 2 GiB 可用磁盘空间，以及可从公网访问的固定 IPv4。Rocky Linux 9 的 Docker 模式需预先安装 Engine 与 Compose v2。完整软件源及验证范围见[兼容性与验收](docs/verification.md)。

两种方式都需要公网 TCP **80** 签发和续期证书、配置的 TCP DERP 端口、配置的 UDP STUN 端口（示例为 3478），并保留 SSH。若不使用 443，请在裸机配置中明确设置 `DERP_PORT="52625"`。TCP 80 不能改成其他公网端口；本方案关闭 `derper` 自带的 80 端口 HTTP 服务。

管理员还需要准备目标 tailnet 的登录方式，并把脚本打印的 `derpMap` 区域**合并**到现有策略，保留已有区域、grants/ACL、SSH 和 tags。`EXPECTED_TAILNET` 是 tailnet 名称，`REGION_ID` 必须在 900–999 中选一个未占用值。

## 快速开始

在目标 VPS 上克隆本仓库，选择**一种**方式部署；不要让两种方式占用同一组端口。先编辑示例配置中的公网 IP、邮箱、tailnet、节点名称、区域和端口。

### 裸机

```bash
cp config.example.env config.env
chmod 600 config.env
sudo bash install.sh preflight config.env
sudo bash install.sh install config.env
sudo bash install.sh check config.env
sudo bash install.sh derpmap config.env
```

交互登录时设 `TS_AUTH_KEY_FILE=""`。无人值守入网需要预置权限为 `0600` 的凭据文件；专用 tag 的 OAuth 客户端已在实机复测中验证。认证、网络镜像和完整验收步骤见[裸机部署](docs/deployment/bare-metal.md)。

### Docker Compose

```bash
cp docker/config.example.env docker/config.env
chmod 600 docker/config.env
sudo bash docker/deploy.sh preflight docker/config.env
sudo bash docker/deploy.sh install docker/config.env
sudo bash docker/deploy.sh check docker/config.env
sudo bash docker/deploy.sh derpmap docker/config.env
```

示例默认为交互登录；安装后用 `sudo bash docker/deploy.sh logs docker/config.env` 获取登录 URL。无人值守模式设 `AUTH_MODE="authkey"` 并准备凭据文件。缺少 Docker、国内网络无法拉取镜像、离线导入镜像等操作见[Docker 部署](docs/deployment/docker.md)。

## 验收与文档

`install.sh check` / `docker/deploy.sh check` 只验证本机或容器状态。完成策略合并后，还需从外部网络验证公网 TLS、UDP STUN，并用真实 tailnet 客户端确认经新增 DERP 区域中继。`bash tests/local.sh` 是本地保护测试；GitHub Actions 的六项发行版矩阵只检查 amd64 包命令与构建，不能代替整机部署。[四台 Ubuntu 24.04 VPS 的复测](docs/validation/live-validation-mainstream.md)逐项记录了新装、状态复用、真实中继及普通 Auth key 的未解决故障。

- [裸机部署](docs/deployment/bare-metal.md) · [Docker 部署](docs/deployment/docker.md)：准备、安装、登录和首次验收
- [运维与故障排查](docs/operations.md)：续期、重启、升级和网络诊断
- [兼容性与验收](docs/verification.md)：支持矩阵、自动化测试范围及历史实机记录
- [AGENTS.md](AGENTS.md)：仓库协作规则；[项目 Skill](.agents/skills/tailscale-derp-bootstrap/SKILL.md)：供兼容 Agent Skills 的工具按需加载

可用 [skills.sh CLI](https://www.skills.sh/docs/cli) 发现本地 Skill：`npx skills add . --list`。仓库包含该 Skill 的公开版本后，可用 `npx skills add Drswith/tailscale-derp-bootstrap --skill tailscale-derp-bootstrap -a codex -g` 安装到 Codex；之后用 `npx skills update tailscale-derp-bootstrap -g` 更新，或用 `npx skills remove --global tailscale-derp-bootstrap` 移除。

## 上游资料

[Tailscale 自建 DERP](https://tailscale.com/docs/reference/derp-servers/custom-derp-servers) · [官方 `derper`](https://github.com/tailscale/tailscale/blob/v1.102.4/cmd/derper/README.md) · [Let's Encrypt IP 证书](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability) · [Tailscale 软件源](https://pkgs.tailscale.com/stable/) · [Docker Engine 安装](https://docs.docker.com/engine/install/)
