# Windows 部署

核心脚本支持 Windows 10/11，并且只需要 Python 3.8 或更高版本。安装 Python 时建议勾选“Add Python to PATH”。

## 直接运行

PowerShell：

```powershell
$env:MAOGUAI_ACCOUNT = "你的账号或 UID"
$env:MAOGUAI_PASSWORD = "你的密码"
py .\main.py
```

命令提示符（CMD）：

```bat
set MAOGUAI_ACCOUNT=你的账号或UID
set MAOGUAI_PASSWORD=你的密码
py main.py
```

这两种方式设置的变量只对当前终端窗口有效。

## 任务计划程序

1. 将 `MAOGUAI_ACCOUNT`、`MAOGUAI_PASSWORD` 配置为执行任务的 Windows 用户环境变量或系统环境变量。
2. 创建基本任务，触发器选择“每天”，时间设为 `08:05`。
3. 操作选择“启动程序”，按下表填写。
4. 先在任务计划程序中手动运行一次，并检查“历史记录”。

| 字段 | 值 |
| --- | --- |
| 程序或脚本 | Python 安装目录中的 `python.exe`，例如 `C:\Users\你的用户名\AppData\Local\Programs\Python\Python311\python.exe` |
| 添加参数 | `C:\你的路径\2550\main.py` |
| 起始于 | `C:\你的路径\2550` |

环境变量修改后，重新启动 Windows 或至少重新登录执行任务的账户，确保任务计划程序能读取最新值。

## 注意事项

- `scripts/run.sh`、`scripts/run-cron.sh` 是 Unix shell 脚本，不能在 Windows 中直接运行。
- 可以使用 Docker Desktop 按 [Docker 部署文档](docker.md) 运行容器。
- 不要把真实账号或密码写入 `.env.example`，也不要提交 `.env` 到仓库。
