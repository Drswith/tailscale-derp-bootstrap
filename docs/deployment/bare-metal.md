# 裸机 systemd 部署

[返回项目首页](../../README.md) · [Docker 部署](docker.md) · [运维](../operations.md)

`install.sh` 在宿主机安装匹配版本的 Tailscale 与官方源码构建的 `derper`，用 Certbot 获取公网 IPv4 证书，并创建 `derper`、证书续期和健康检查的 systemd 单元。配置文件会作为 shell 脚本加载，只使用自己编辑且可信的文件。

## 准备

确认宿主机属于[支持范围](../verification.md)，有 systemd、root 权限、固定且可从公网访问的 IPv4，以及至少 2 GiB 可用磁盘。放行 TCP 80、配置的 DERP TCP 端口和 UDP STUN 端口，并保留 SSH。TCP 80 在签发与续期时必须空闲；云安全组和本机防火墙均需单独检查。

```bash
cp config.example.env config.env
chmod 600 config.env
```

编辑 `config.env`：

| 字段 | 填写方式 |
| --- | --- |
| `PUBLIC_IPV4`、`ACME_EMAIL` | 实际公网 IPv4、接收证书通知的邮箱；示例地址会被拒绝 |
| `EXPECTED_TAILNET`、`TS_HOSTNAME` | 目标 tailnet 名称、该 VPS 的设备名；tailnet 名称不是 DERP 域名 |
| `DERP_PORT`、`STUN_PORT` | 对外 DERP TCP 与 STUN UDP 端口；示例裸机配置为 443/3478，可将 DERP 改成 52625 |
| `REGION_ID`、`REGION_CODE`、`REGION_NAME` | 新区域标识；`REGION_ID` 在 900–999 中选未占用值 |
| `TS_AUTH_KEY_FILE`、`TS_ADVERTISE_TAGS` | 登录凭据的文件路径及可选的节点 tag，见下文 |

在另一台已入网设备上可用 `tailscale status --json | jq -r '.CurrentTailnet.Name'` 查询 tailnet 名称。不要把实际 IP、邮箱、密钥或证书提交到仓库。

### 登录方式

- **交互登录**：设置 `TS_AUTH_KEY_FILE=""`。运行安装后完成 `tailscale up` 给出的网页登录，并按 tailnet 设置批准设备。
- **无人值守登录**：将一次性、非临时 Auth key 或专用 tag 的 OAuth 客户端 secret 放在配置指定的文件，权限设为 `0600`；配置内只写路径。默认路径是 `/run/derp-bootstrap/auth.key`，成功入网后脚本会删除**这个默认路径**的文件。其他路径需自行清理。
- **OAuth 客户端**：先在策略中定义由管理员拥有的专用 tag，创建仅有 `auth_keys` 权限且限于该 tag 的客户端，并设置 `TS_ADVERTISE_TAGS="tag:你的标签"`。需要持久且预授权的身份时，凭据文件可保存带 `?ephemeral=false&preauthorized=true` 后缀的客户端 secret。长期节点的密钥到期设置仍须在控制台核对。

最近一次四机复测中，普通 Auth key 在两台空白 VPS 和一台 Actions runner 上均返回 `invalid key: unable to validate API key`，原因未确定；OAuth 客户端方式完成了无人值守初始化。详情见[复测记录](../validation/live-validation-mainstream.md)。不要把凭据放在命令参数、环境变量、Git 或长期日志中。

## 安装

```bash
sudo bash install.sh preflight config.env
sudo bash install.sh install config.env
```

`preflight` 检查系统、磁盘、端口和出站网络，不证明云侧入站已放行。极简镜像若缺 Python、curl、OpenSSL 或 `ss`，`preflight` 可能先报告缺失；`install` 会安装基础工具后重新检查。安装先以 Let's Encrypt staging 做 HTTP-01 dry-run，通过后才请求正式证书；失败时不会以自签名证书启动 DERP。

国内网络若无法稳定访问 Go 下载站或模块源，先分别确认直连和代理路径；仅在实际可达时，针对本次命令设置镜像。例如当前 [versions.lock](../../versions.lock) 的 Linux amd64 Go 版本：

```bash
sudo env GOPROXY=https://goproxy.cn \
  GO_ARCHIVE_URL=https://mirrors.aliyun.com/golang/go1.26.8.linux-amd64.tar.gz \
  bash install.sh install config.env
```

`GO_ARCHIVE_URL` 下载的归档仍按锁定的官方 SHA-256 校验，`GOSUMDB` 必须保持开启。更改锁定版本时同步调整归档 URL；代理端口、镜像可达性和 `sudo` 保留的环境变量都需当次核对。更多诊断见[运维说明](../operations.md)。

## 策略与验收

安装结束会输出 `derpMap` JSON 片段，也可再次运行：

```bash
sudo bash install.sh derpmap config.env
sudo bash install.sh check config.env
systemctl status derper derp-cert-renew.timer derp-healthcheck.timer
journalctl -u derper -u derp-cert-renew.service -u derp-healthcheck.service --since today
```

只把新区域合并到现有 tailnet 策略，保留官方区域和既有 grants/ACL、SSH、tags。不要添加 `CertName: "sha256-raw:..."` 或 `InsecureForTests: true`；本项目使用公共 CA 签发且包含公网 IP SAN 的证书。`--verify-clients` 要求服务器上的 Tailscale 节点能按策略看到目标客户端，必要时只补最小可见性规则。

从另一网络对 `<公网IP>:<DERP端口>` 运行 `openssl s_client -verify_ip <公网IP> -verify_return_error`。再从真实 tailnet 客户端检查 `tailscale debug derp-map`、`tailscale netcheck` 和实际经新区域的 `tailscale ping`。本机 `check`、控制台中出现区域或一次随机密钥的 `tailscale debug derp` 连接，都不能单独证明真实客户端获得中继。分层验收方法见[兼容性与验收](../verification.md)。
