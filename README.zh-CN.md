# 毛怪俱乐部自动签到

[English](README.md) | 简体中文

用于青龙面板、本地定时任务、Docker 或 GitHub Actions 的 `2550505.com` 自动登录签到脚本。

> 使用本项目需要自行承担账号风险。请勿提交账号、密码、Cookie 或 Token，也不要将本项目用于违反目标站点规则的用途。

## 功能

- 自动登录并使用会话 Cookie
- 持久化 Cookie 优先复用登录，会话失效时自动回退密码登录
- 查询当天签到状态，已签到时跳过重复操作
- 未签到时自动执行签到并输出经验、贡献
- 兼容登录接口通过 Cookie 或 JSON 返回 Token 的情况
- 对状态查询等幂等请求进行有限重试，避免重复执行签到
- 无第三方 Python 依赖

## 快速开始

需要 Python 3.8 或更高版本：

```bash
export MAOGUAI_ACCOUNT="你的账号或 UID"
export MAOGUAI_PASSWORD="你的密码"
python3 main.py
```

本地测试可以复制 `.env.example` 作为变量清单，但脚本不会自动读取 `.env` 文件。

## 部署方式

| 方式 | 适合场景 | 说明 |
| --- | --- | --- |
| [本地直接运行和 Crontab](docs/local.md) | 有 Linux、macOS 或服务器 | 依赖最少，适合长期运行 |
| [Windows](docs/windows.md) | Windows 10/11 | 可直接运行，定时任务使用任务计划程序 |
| [Docker](docs/docker.md) | 已使用容器 | 环境隔离，容器单次执行后退出 |
| [Docker Compose](docs/docker.md) | Docker 用户 | 统一管理镜像和环境变量 |
| [青龙面板](docs/qinglong.md) | 定时任务面板 | 适合已有青龙环境的用户 |
| [GitHub Actions](docs/github-actions.md) | 不想维护服务器 | 配置 Secrets 后按 UTC 定时运行 |

所有方式都使用同一个 `main.py` 入口和同一组环境变量。

## Windows

核心脚本支持 Windows 10/11。安装 Python 3.8 或更高版本时，请勾选“Add Python to PATH”。项目不依赖第三方 Python 包。

PowerShell 中直接运行：

```powershell
$env:MAOGUAI_ACCOUNT = "你的账号或 UID"
$env:MAOGUAI_PASSWORD = "你的密码"
py .\main.py
```

传统命令提示符（CMD）中直接运行：

```bat
set MAOGUAI_ACCOUNT=你的账号或UID
set MAOGUAI_PASSWORD=你的密码
py main.py
```

上面的变量仅在当前终端窗口有效。Windows 定时执行请使用“任务计划程序”；详细字段和安全配置见 [Windows 部署文档](docs/windows.md)。Unix 的 `scripts/run.sh`、`scripts/run-cron.sh` 不适用于 Windows。

## 青龙面板

1. 将仓库拉取到青龙脚本目录。
2. 添加环境变量 `MAOGUAI_ACCOUNT` 和 `MAOGUAI_PASSWORD`。
3. 新建任务，命令填写：

   ```bash
   python3 /你的路径/2550/main.py
   ```

4. 若青龙时区为 `Asia/Shanghai`，建议每天 `08:05` 执行，Cron 为 `5 8 * * *`。

详细说明见 [青龙部署文档](docs/qinglong.md)。

## Docker 快速开始

```bash
cp .env.example .env
chmod 600 .env
printf 'MAOGUAI_UID=%s\nMAOGUAI_GID=%s\n' "$(id -u)" "$(id -g)" >> .env
docker compose build
docker compose run --rm maoguai-sign
```

详细说明见 [Docker 部署文档](docs/docker.md)。

## GitHub Actions 快速开始

在仓库 Secrets 中添加 `MAOGUAI_ACCOUNT` 和 `MAOGUAI_PASSWORD`，工作流会每天北京时间 `08:05` 执行，也支持手动触发。

详细说明见 [GitHub Actions 部署文档](docs/github-actions.md)。

## 配置项

| 环境变量 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `MAOGUAI_ACCOUNT` | 是 | 无 | 账号或 UID |
| `MAOGUAI_PASSWORD` | 是 | 无 | 账号密码 |
| `MAOGUAI_BASE_URL` | 否 | `https://2550505.com` | HTTPS 接口根地址；默认只允许目标站点 |
| `MAOGUAI_ALLOW_CUSTOM_BASE_URL` | 否 | `false` | 仅在可信 HTTPS 测试环境中设为 `true` |
| `MAOGUAI_CLIENT_VERSION` | 否 | `0c1c05` | 客户端版本标识 |
| `MAOGUAI_SESSION_FILE` | 否 | `data/session.cookies` | 持久化登录 Cookie 文件路径 |
| `MAOGUAI_TIMEOUT` | 否 | `30` | 单次请求超时时间，单位秒 |
| `MAOGUAI_RETRIES` | 否 | `2` | 幂等请求重试次数，范围 `0` 到 `5`；会退避等待并遵循 `Retry-After` |

## 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 签到成功或今天已经签到 |
| `1` | 配置、登录、接口、网络或签到失败 |

## 项目结构

```text
main.py       # 青龙兼容入口
maoguai/
  config.py   # 环境变量读取和配置校验
  client.py   # HTTP、Cookie、请求签名、重试
  models.py   # API 响应模型和结构校验
  runner.py   # 登录、查询、签到流程
  errors.py   # 项目级异常
tests/        # 不访问真实服务的单元测试
docs/         # 部署和排错文档
```

模块依赖方向是：`main.py -> runner.py -> client.py/models.py`。业务流程不直接读取环境变量，网络客户端也不负责决定签到业务，后续新增任务时可以在 `maoguai/tasks/` 下继续拆分。

## 开发与测试

项目只使用 Python 标准库，执行：

```bash
python3 -m unittest discover -v
```

测试使用模拟客户端和本地构造的响应，不会登录、签到或访问真实服务。

## 常见问题

- **提示缺少环境变量**：确认变量名称完全是 `MAOGUAI_ACCOUNT`、`MAOGUAI_PASSWORD`，并检查任务运行环境是否能读取到它们。
- **登录成功但没有 Token**：脚本会拒绝继续签到，避免在未认证状态下误调用接口；请检查接口返回、Cookie 保存和网络环境。
- **接口返回格式错误**：通常表示目标站点接口发生变化，需要根据实际响应更新 `maoguai/models.py`。
- **频繁网络失败**：可适当增加 `MAOGUAI_TIMEOUT`，或将 `MAOGUAI_RETRIES` 设为不超过 `5` 的值；重试会退避等待并遵循服务端的 `Retry-After`。

## 许可证

本项目采用 [MIT License](LICENSE) 开源。使用本项目仍需自行承担账号风险，并遵守目标站点的相关规则。
