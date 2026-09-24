# Docker Compose 部署

[返回项目首页](../../README.md) · [裸机部署](bare-metal.md) · [运维](../operations.md)

`docker/deploy.sh` 在容器中运行 Tailscale、官方源码构建的 `derper` 和 Certbot。Tailscale 使用 userspace 模式，宿主机无需安装 Tailscale、提供 `/dev/net/tun` 或授予 privileged 权限。宿主机需要 systemd 来启动 Docker Engine；配置文件会作为 shell 脚本加载，只使用自己编辑且可信的文件。

先在目标 VPS 上克隆完整仓库；下文命令均在仓库根目录执行：

```bash
git clone --depth 1 https://github.com/Drswith/tailscale-derp-bootstrap.git
cd tailscale-derp-bootstrap
```

## 宿主机和网络

宿主机须在[支持范围](../verification.md)，并有固定公网 IPv4。Docker Engine、Compose v2 缺失时，脚本在 Ubuntu 使用系统 `docker.io`/`docker-compose-v2`，在 Debian 与 CentOS Stream 9/10 使用 Docker 官方软件源自动安装。仅当需要在本机构建镜像且缺 Buildx 时，脚本才补装 Buildx。现有 Docker daemon 不可用时，脚本会尝试通过 systemd 恢复服务和 socket。

默认 DERP 使用 TCP 52625、STUN 使用 UDP 3478，保留 SSH；DERP 不监听 TCP 80、443、8080。证书的 HTTP-01 验证仍需公网 TCP 80 可达，Compose 会持续发布宿主机 80 端口映射，但容器内 Certbot 仅在签发与续期时监听 80。两种部署方式不能同时绑定相同端口。Docker 镜像构建需要 Docker Hub、Debian 软件源、PyPI 和 Go 模块源可达；VPS 在中国大陆时先分别测试直连与代理路径。

## 配置与登录

```bash
cp docker/config.example.env docker/config.env
chmod 600 docker/config.env
```

编辑 `PUBLIC_IPV4`、`ACME_EMAIL`、`EXPECTED_TAILNET`、`TS_HOSTNAME`、`REGION_ID`/`REGION_CODE`/`REGION_NAME`，以及 DERP/STUN 端口。`EXPECTED_TAILNET` 是 tailnet 名称，`REGION_ID` 在 900–999 内选一个未使用的值。

- **交互登录**：保留 `AUTH_MODE="interactive"`。`install` 启动容器后，用 `sudo bash docker/deploy.sh logs docker/config.env` 获取网页登录 URL，完成登录及需要的设备批准，再运行 `check`。
- **无人值守登录**：设 `AUTH_MODE="authkey"`，将一次性、非临时 Auth key 或 OAuth 客户端 secret 放入 `docker/secrets/auth.key`，权限为 `0600`。OAuth 方式需先在策略中定义专用 tag、创建仅有 `auth_keys` 权限且限于该 tag 的客户端，并设置 `TS_ADVERTISE_TAGS`。需要持久且预授权身份时，客户端 secret 可带 `?ephemeral=false&preauthorized=true` 后缀。成功入网后容器删除凭据文件；后续重启复用 `docker/state/tailscale` 中的身份。

普通 Auth key 在最近一次四机复测中发生尚未定位的注册失败；专用 tag 的 OAuth 客户端方式已完成无人值守初始化。详见[复测记录](../validation/live-validation-mainstream.md)。密钥只放文件，勿写入配置值、命令参数、Git 或长期日志。

## 安装与验收

```bash
sudo bash docker/deploy.sh preflight docker/config.env
sudo bash docker/deploy.sh install docker/config.env
sudo bash docker/deploy.sh check docker/config.env
sudo bash docker/deploy.sh derpmap docker/config.env
```

`preflight` 检查配置、Docker 状态和端口占用提示，不证明云侧入站通畅；极简镜像若缺 Python，`install` 会先补装。无交互模式的 `install` 等待健康检查；交互模式需先完成网页登录。首次证书签发先跑 Let's Encrypt staging HTTP-01 dry-run，再取得正式公网 IP 证书。

`derpmap` 输出的区域只合并进现有 tailnet 策略，不覆盖官方区域、grants/ACL、SSH 或 tags。`check` 覆盖容器健康、tailnet 身份、证书链、IP SAN 和实际提供的 TLS 证书；还需从外部网络验证 TCP/UDP 入站及真实客户端的 DERP 中继，方法见[兼容性与验收](../verification.md)。

## Docker Hub 不可达时

在可访问镜像源的同架构构建机上构建并导出镜像，安全传到 VPS 后用 `IMAGE_ARCHIVE` 安装。下例针对 linux/amd64；其他架构须调整 `--platform`，并在目标架构上验证。

```bash
source versions.lock
docker buildx build --platform linux/amd64 -f docker/Dockerfile \
  --build-arg GO_VERSION="$GO_VERSION" \
  --build-arg TAILSCALE_VERSION="$TAILSCALE_VERSION" \
  --build-arg CERTBOT_VERSION="$CERTBOT_VERSION" \
  -t "derp-bootstrap:$TAILSCALE_VERSION" --load .
docker save "derp-bootstrap:$TAILSCALE_VERSION" | gzip > /tmp/derp-bootstrap-image.tar.gz
# 传输镜像归档与部署文件，并在 VPS 上核对 SHA-256 后运行：
sudo env IMAGE_ARCHIVE=/path/to/derp-bootstrap-image.tar.gz \
  bash docker/deploy.sh install docker/config.env
```

`docker/state` 保存 Tailscale、Let's Encrypt 和 `derper` 的身份与证书。不要在更新、重启或重建容器时删除它；丢失状态可能导致重新入网或重新签证。续期与重启流程见[运维说明](../operations.md)。
