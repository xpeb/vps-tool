# vps-tool

面向 Debian 和 Alpine Linux VPS 的 Bash 管理工具，提供 SSH 安全、Fail2Ban 和常用系统优化功能。

## 功能

- SSH 公钥导入、生成、查看、删除和清空
- 密码登录、密钥登录和 SSH 端口管理
- 自动检查 SSH 配置，失败时尝试回滚
- Fail2Ban 安装、配置、封禁/解封和白名单管理
- BBR + FQ、zRAM、时区和系统清理
- Docker、Compose 安装、更新和卸载
- 包管理操作使用统一动态进度条

## 支持环境

- Debian + `apt`
- Alpine Linux + `apk`
- systemd、OpenRC，以及有限的 SysVinit 兼容处理
- 需要 root、Bash 和 curl；Alpine 精简镜像通常需要先安装 Bash 和 curl

```bash
# Debian
apt-get update && apt-get install -y bash curl

# Alpine
apk add --no-cache bash curl
```

## 使用

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tool/main/vps.sh)
```

修改 SSH 配置前，请保持当前会话，并确保具备云控制台、VNC 或其他带外恢复方式。

建议操作顺序：

1. 添加公钥并使用新终端测试登录
2. 修改 SSH 端口并确认安全组/防火墙规则
3. 确认备用登录方式可用后，再禁用密码登录

## Docker 说明

- Debian 仅使用 Debian 官方仓库的 `docker.io`、`docker-compose-v2` 或 `docker-compose`
- Alpine 仅使用 Alpine 官方仓库的 `docker` 和 `docker-cli-compose`
- Docker Compose 同时兼容 `docker compose` 和 `docker-compose`
- 版本检查读取系统仓库 Candidate，不读取 GitHub 或 Docker 官方仓库版本
- 不添加 Docker 官方软件源，不执行 `get.docker.com` 等远程 root 安装脚本
- 卸载 Docker 软件包与删除数据分开确认，检测到共享 containerd 时默认保留相关软件包和数据

## 安全提示

- 远程公钥地址仅支持 HTTPS，并会先验证公钥格式
- 禁用密码登录或删除最后一个公钥前，脚本会进行风险提示并要求确认
- Docker 数据删除需要额外输入 `DELETE-DATA`
- 删除共享 containerd 数据需要额外输入 `DELETE-CONTAINERD-DATA`
- 系统清理会删除缓存、过期日志和未使用的 Docker 镜像；镜像清理可跳过
- 请先在测试 VPS 验证，再用于生产环境

## 免责声明

脚本会修改系统服务、SSH 配置、防火墙、日志和软件包。不同 VPS 镜像及发行版版本可能存在差异，请在执行前备份并确认具有恢复条件。
