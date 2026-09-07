# 本地部署

相关文档：[项目主页](../README.zh-CN.md) · [Docker 部署](docker.md) · [排错指南](troubleshooting.md)

## 直接运行

项目只依赖 Python 标准库，不需要安装第三方包：

```bash
export MAOGUAI_ACCOUNT="你的账号或 UID"
export MAOGUAI_PASSWORD="你的密码"
python3 main.py
```

也可以复制环境变量清单：

```bash
cp .env.example .env
```

然后将 `.env` 中的变量导入当前 shell。脚本本身不会自动读取 `.env` 文件：

```bash
set -a
. ./.env
set +a
python3 main.py
```

脚本默认将登录 Cookie 持久化到 `data/session.cookies`（该目录已被 Git 忽略），后续运行会优先复用有效会话；会话失效时才使用账号密码重新登录。可通过 `MAOGUAI_SESSION_FILE` 指定其他路径，并确保文件仅当前执行用户可读。

## Crontab 定时

编辑当前用户的定时任务：

```bash
crontab -e
```

先创建本地变量文件并限制其访问权限：

```bash
cp .env.example .env
chmod 600 .env
```

若服务器时区为 `Asia/Shanghai`，每天北京时间 08:05 执行：

```cron
5 8 * * * /bin/sh /你的路径/2550/scripts/run-cron.sh >> /tmp/maoguai-sign.log 2>&1
```

其他时区的服务器需要按实际时区换算 Cron 时间。

`scripts/run-cron.sh` 只会读取项目根目录 `.env` 中的变量。不要把 `.env` 提交到仓库；对多人共用的服务器，建议改用系统的凭据管理能力或受限的服务账号。

## 手动验证

```bash
python3 -m unittest discover -v
```

遇到登录、接口或网络异常时，可继续查看 [排错指南](troubleshooting.md)。
