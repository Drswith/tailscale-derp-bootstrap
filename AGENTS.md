# 仓库协作说明

本仓库用公网 IPv4 和 Let's Encrypt IP 证书部署 Tailscale 官方 `derper`。优先从当前脚本与配置取证，再更新文档；历史实机记录只证明记录中的时间和环境。

## 代码与文档入口

- `bootstrap.sh`：一行引导入口，获取完整项目、生成配置并以本机 `check` 通过为安装完成标准；`install.sh`：裸机 systemd 的 `preflight|install|check|derpmap`；`docker/deploy.sh`：Docker 的 `preflight|install|check|renew|derpmap|logs`。
- `lib/common.sh` 管理配置、证书与身份校验；`lib/platform.sh` 是允许的系统版本及包源映射；`versions.lock` 同时锁定 Tailscale、Go/校验值和 Certbot。
- `config.example.env` 与 `docker/config.example.env` 是不同的配置入口，默认 DERP TCP 端口均为 52625。公网 TCP 80 仅用于当前 IP 证书方案的 HTTP-01 验证，不能用自定义 DERP 端口替代；配置由 shell `source`，只运行可信、由操作者编辑的文件。
- `README.md` 是项目入口；`docs/deployment/` 是操作步骤；`docs/operations.md` 是维护与排障；`docs/verification.md` 记录支持和验证边界；`docs/validation/` 保存按轮次区分的已脱敏实机证据。
- `.agents/skills/tailscale-derp-bootstrap/SKILL.md` 是可供 Agent Skills/skills.sh 发现的使用指南。Skill 可被安装到仓库外，不能假设它与项目源码总在同一目录。

## 修改原则

- 变更支持系统、默认端口、登录方式或安装命令时，同步检查两个配置示例、部署文档、README、测试和 CI。Tailscale 系统包与 `derper` 构建版本必须一致；更改 Go 版本需更新官方 SHA-256。
- 不把公网 IP、邮箱、tailnet/设备标识、Auth key、OAuth secret、证书或临时代理地址写入提交。不要在日志、命令参数或环境变量中输出认证凭据；凭据按脚本要求存入权限为 `0600` 的文件。
- 保留既有 tailnet 策略；`derpMap` 片段只应合并，不应覆盖原有区域、grants/ACL、SSH 或 tags。脚本不会修改云安全组或主机防火墙。
- 网络请求失败时先区分直连与代理，核对本机代理状态、实际端口和 hosts；分别验证 GitHub、Docker、Go 模块等客户端。公网请求需要代理时按需配置，`NO_PROXY` 排除内网、LAN 与服务发现地址，不持久化代理密码或临时端口。

## 验证与报告

- 对脚本及文档改动运行 `bash tests/local.sh`、`git diff --check`，并检查 Markdown 相对链接。改动 Skill 时运行 skill-creator 的 `quick_validate.py`，并用 `npx skills add . --list` 检查 skills.sh 发现结果。
- Actions 发行版矩阵只验证 Ubuntu 22.04/24.04、Debian 12/13、CentOS Stream 9/10 的 amd64 容器里的包安装与构建；不得据此声称 systemd、Docker daemon、ACME、公网入口或真实 DERP 中继通过。
- 实机结果分开报告安装、服务/证书、公网 TCP/UDP、有效 DERP map、真实认证客户端的 relay/direct 路径。`check` 成功或控制台保存策略，不等于真实中继已验收。
- 历史记录中的普通 Auth key 成功与 2026-09-24 空白状态复测的失败属于不同轮次；维护文档时保留这个时间边界。
