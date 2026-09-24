# 兼容性与验收边界

[返回项目首页](../README.md) · [裸机部署](deployment/bare-metal.md) · [Docker 部署](deployment/docker.md)

## 当前接受的系统

| 宿主系统 | 裸机 Tailscale 包 | Docker 缺失时的处理 |
| --- | --- | --- |
| Ubuntu 22.04/24.04 | Tailscale 官方 APT 源 | 安装 Ubuntu 的 `docker.io`、`docker-compose-v2`；构建镜像时按需补 Buildx |
| Debian 12/13 | Tailscale 官方 APT 源 | 添加 Docker 官方 Debian CE 源并安装 Engine、Compose、Buildx |
| RHEL 9 | Tailscale 官方 RHEL 9 RPM 源 | 添加 Docker 官方 RHEL CE 源并安装 Engine、Compose、Buildx |
| Rocky Linux 9 | Tailscale 官方 RHEL 9 RPM 源 | 必须预先提供 Docker Engine 与 Compose v2；脚本不自动添加 Docker CE 源 |

只接受 `/etc/os-release` 映射中的上述版本、x86_64 或 aarch64、systemd 主机。Fedora、AlmaLinux、RHEL/Rocky 10、Ubuntu 20.04、Linux Mint 和未知系统会被拒绝。RHEL 9 系使用 Python 3.11 运行锁定的 Certbot。当前 amd64 兼容性检查不能推断 aarch64 上的完整部署结果。

## 自动化测试验证了什么

```bash
bash tests/local.sh
```

本地测试检查发行版识别、配置和 `derpMap` 生成、证书 IP SAN/私钥/有效期、证书链接，以及脚本语法；本机有 Docker Compose 时还解析配置。

[GitHub Actions 兼容性矩阵](../.github/workflows/test.yml)在 Ubuntu 22.04/24.04、Debian 12/13、RHEL UBI 9、Rocky Linux 9 的 **linux/amd64 容器**中调用安装器实际函数，安装基础包及锁定的 Tailscale、校验并安装 Go、构建匹配版本的 `derper`、安装锁定的 Certbot，并运行本地测试。Ubuntu、Debian 和 RHEL UBI 9 还安装 Docker CLI、Compose、Buildx 并解析 Compose 配置；Rocky 检查缺失 Docker 时的预装提示。另一个任务构建 Docker 部署镜像并核对其中的二进制版本。[六项矩阵与镜像构建通过的运行记录](https://github.com/Drswith/tailscale-derp-bootstrap/actions/runs/35964568794)可供复核。

RHEL 9 使用公开的 UBI 9 容器验证包命令，尚未在完整 RHEL 宿主机上安装。矩阵容器没有 systemd、Docker daemon、公网入口、ACME 身份或 tailnet 凭据，所以不能证明服务启动、正式签证或客户端中继。

## 整机和外部客户端验收

| 层次 | 最少证据 | 不足以代替它的检查 |
| --- | --- | --- |
| 宿主机或容器 | 安装命令退出、服务健康、Tailscale 身份、证书链/IP SAN、实际提供的 TLS 证书 | 构建成功、Compose 配置解析 |
| 公网入口 | 另一网络的 TCP DERP TLS 验证、TCP 80 证书挑战可达性、Tailscale 格式 STUN 响应 | 本机 `check`、云安全组规则存在 |
| Tailnet 策略 | 重新读取有效 `derpMap`，确认新增区域与原有区域及访问规则共存 | 只提交了策略文本 |
| 真实中继 | 两台已认证客户端之间的 `tailscale ping` 明确显示经新增区域，必要时在受控测试中临时阻断直连并恢复 | `tailscale debug derp` 的随机密钥连接或 `netcheck` 的延迟数字 |

公网 TLS 可在另一网络运行 `openssl s_client -connect <公网IP>:<DERP端口> -verify_ip <公网IP> -verify_return_error`。客户端可运行 `tailscale debug derp-map`、`tailscale netcheck`，并观察真实 `tailscale ping` 的路径。`tailscale debug derp` 会使用随机节点密钥，可能被 `--verify-clients` 拒绝；它能验证 DERP/TLS 与 STUN 可达，却不等于真实节点获得准入。

## 已脱敏的实机记录

- [2026-09-24 四台 Ubuntu 24.04 VPS 复测](validation/live-validation-mainstream.md)：裸机交互、裸机 OAuth 无交互、Docker 交互、Docker OAuth 无交互；公网与真实客户端中继均有记录。03/04 本轮保留先前的 Docker 与证书状态，04 另测 Docker 软件包缺失后的恢复。
- [首台裸机 VPS 验收](validation/live-validation-primary.md)：较早一轮的交互登录、证书、重启和中继证据。
- [第二台裸机 VPS 验收](validation/live-validation-secondary.md)：较早一轮的一次性 Auth key 无交互成功记录；该主机后来重装，不能代表 2026-09-24 对普通 Auth key 的新复测结论。
- [双 Docker VPS 验收](validation/live-validation-docker.md)：较早一轮全新机器缺少 Docker 时的自动安装、交互/无交互、证书、重启和中继证据。

最近的四机复测中，普通 Auth key 在 02/04 空白状态及一台 Actions runner 上均得到 `invalid key: unable to validate API key`；原因尚未定位，测试密钥已撤销。为完成无人值守测试，02/04 使用限定专用 tag 的 OAuth 客户端 secret 成功初始化。四机结果不证明普通 Auth key 当前可用，也不覆盖长期吞吐、正式证书到期时的生产续期或升级失败回滚。
