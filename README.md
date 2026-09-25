# VPS Security Management Tool

一个面向 Debian 和 Alpine VPS 的 Bash 综合管理工具，提供：

- SSH 公钥管理与登录方式切换
- SSH 端口配置
- Fail2Ban 安装、配置和防护管理
- BBR、FQ、zRAM、时区和系统清理管理
- Docker 安装、更新和卸载
- SSH 配置语法检查、备份与失败回滚

## 使用方式

```bash
chmod 700 vps.sh
sudo ./vps.sh
```

脚本需要以 `root` 身份运行。首次使用前，建议先通过云厂商控制台或带外管理确认自己具备恢复 VPS 的方式。

## 支持系统

- Debian
- Alpine Linux

## 安全提示

- 修改 SSH 端口、密码登录或密钥登录配置时，不要关闭当前 SSH 会话；请先使用新终端验证。
- 私钥不会由脚本打印到终端。若在 VPS 上生成密钥，请通过受信任的 SFTP 方式下载并妥善保管。
- 系统清理、Docker 卸载等操作可能删除数据，执行前请确认备份完整。
- 建议在测试 VPS 上验证后再用于生产环境。

## 许可证

暂未指定许可证。如需公开分发，请根据实际使用场景补充许可证文件。
