# 青龙部署

相关文档：[项目主页](../README.zh-CN.md) · [本地部署](local.md) · [排错指南](troubleshooting.md)

青龙是本项目推荐的面板化部署方式之一。脚本只执行一次签到，定时调度由青龙负责。

## 添加环境变量

在青龙的“环境变量”中添加：

```text
MAOGUAI_ACCOUNT=你的账号或UID
MAOGUAI_PASSWORD=你的密码
# 可选：持久化登录 Cookie 的路径（青龙容器内）
MAOGUAI_SESSION_FILE=/ql/data/maoguai-session.cookies
```

密码和 Token 不要写入脚本文件，也不要提交到 Git 仓库。

建议将 `MAOGUAI_SESSION_FILE` 放在青龙持久化目录；脚本会优先加载有效 Cookie，失效后才重新登录。

## 添加任务

如果仓库路径为 `/ql/scripts/2550`，任务命令可以写成：

```bash
python3 /ql/scripts/2550/main.py
```

建议 Cron：

```text
5 8 * * *
```

该表达式以青龙容器配置的时区为准；若不使用 `Asia/Shanghai`，请按实际时区调整。

## 日志判断

- `✅ 签到成功`：本次完成签到。
- `✅ 今天已经签到`：无需重复操作，任务仍然成功。
- `❌` 或 `⚠️`：任务返回非零退出码，应该检查日志和接口状态。

## 可选参数

网络不稳定时可增加：

```text
MAOGUAI_TIMEOUT=45
MAOGUAI_RETRIES=3
```

该参数只用于状态查询等幂等请求。参数应保持适度，避免造成不必要的请求。

如果日志持续报错，请按 [排错指南](troubleshooting.md) 先确认变量和接口响应。
