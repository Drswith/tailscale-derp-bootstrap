# tailscale-derp-bootstrap

**无需域名，用固定公网 IPv4 部署 Tailscale DERP。** 支持裸机 systemd 和 Docker Compose，两种方式都从与 [versions.lock](versions.lock) 锁定的 Tailscale 版本一致的官方源码构建 `derper`。

[![发行版构建测试](https://github.com/Drswith/tailscale-derp-bootstrap/actions/workflows/test.yml/badge.svg)](https://github.com/Drswith/tailscale-derp-bootstrap/actions/workflows/test.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## 快速开始：自己安装

准备一台支持的 VPS：Ubuntu 22.04/24.04、Debian 12/13 或 CentOS Stream 9/10，固定公网 IPv4、systemd、root 权限及至少 2 GiB 可用磁盘空间。证书签发和续期要求公网 **TCP 80** 可达；安装时还需要 `curl`、`sudo` 和可交互终端。完整系统与架构范围见[兼容性说明](docs/verification.md)。

在 VPS 上复制执行这一整行：

```bash
derp_bootstrap_script=$(mktemp) && curl -fsSL https://raw.githubusercontent.com/Drswith/tailscale-derp-bootstrap/main/bootstrap.sh -o "$derp_bootstrap_script" && sudo bash "$derp_bootstrap_script"
```

脚本会询问公网 IP、证书邮箱、tailnet、区域、部署方式和登录方式，下载完整项目，并完成安装与本机健康检查。交互登录需要按提示打开 Tailscale 授权链接；无人值守登录的凭据在终端隐藏输入。成功后，`derpMap` 片段保存在 `/opt/derp-bootstrap/source/derp-map.json`。

## 快速开始：交给 Agent

将以下提示词复制给能够访问 VPS 的 Agent：

```text
请在我的 VPS 上部署 https://github.com/Drswith/tailscale-derp-bootstrap，目标是“服务器安装完成并通过本机健康检查”。
先阅读仓库的 README.md、AGENTS.md 和对应部署指南。只向我询问尚缺的 SSH 目标、固定公网 IPv4、证书邮箱、tailnet、未占用的 DERP Region ID、裸机或 Docker 模式，以及交互或无人值守登录方式。凭据只放目标机权限为 0600 的文件，不要让我在聊天中粘贴密钥。
确认系统在支持范围内，公网 TCP 80 可用于证书签发和续期，并保留 SSH。默认使用 DERP TCP 52625、STUN UDP 3478。优先使用 README 的一行引导命令；交互登录时将授权链接交给我。网络失败时分别检查直连和代理。
完成后报告安装和本机 check 的证据、derp-map.json 的路径；将公网入口、tailnet 策略合并和真实客户端中继列为后续事项，未经验证不要写成已通过。
```

## 项目能力

- 使用 [Let's Encrypt 公网 IP 证书](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)，无需域名或 DNS；DERP 默认监听 TCP **52625**，STUN 默认监听 UDP **3478**。
- 裸机模式创建 systemd 服务与证书续期任务；Docker 模式支持在缺少 Docker Engine 和 Compose 的受支持系统上自动安装。
- 支持 Tailscale 网页授权及凭据文件无人值守入网；生成可合并到现有 tailnet 策略的 `derpMap` 片段。

## 安装后还需完成

脚本显示安装成功，表示**服务器安装和本机检查通过**。让新增 DERP 真正供客户端使用，还需由管理员或 Agent：

1. 在云安全组和主机防火墙放行 DERP TCP 52625、STUN UDP 3478，并保持证书续期所需的 TCP 80 可达。
2. 将生成的区域合并进现有 tailnet 策略，保留原有区域、grants/ACL、SSH 和 tags。
3. 从外部网络检查 TLS 与 STUN，再用已认证的真实客户端验证中继路径。

具体命令和不同验证层次见[兼容性与验收](docs/verification.md)。

## 更多文档

- [裸机部署](docs/deployment/bare-metal.md) · [Docker 部署](docs/deployment/docker.md)：手动安装、配置和登录方式。
- [运维与故障排查](docs/operations.md)：续期、升级、端口迁移和网络问题。
- [兼容性与验收](docs/verification.md)：支持范围、自动化测试边界及[实机记录](docs/validation/live-validation-mainstream.md)。
- [项目 Skill](.agents/skills/tailscale-derp-bootstrap/SKILL.md)：供兼容 Agent Skills 的工具使用；可运行 `npx skills add Drswith/tailscale-derp-bootstrap --skill tailscale-derp-bootstrap -g -a codex` 安装。

欢迎通过 [Issues](https://github.com/Drswith/tailscale-derp-bootstrap/issues) 反馈问题，或提交 [Pull Request](https://github.com/Drswith/tailscale-derp-bootstrap/pulls) 改进项目。

## 许可证

[MIT](LICENSE)
