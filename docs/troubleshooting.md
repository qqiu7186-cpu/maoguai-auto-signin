# 排错指南

相关文档：[项目主页](../README.zh-CN.md) · [本地部署](local.md) · [Docker 部署](docker.md) · [GitHub Actions 部署](github-actions.md)

## 先确认运行环境

```bash
python3 --version
python3 -c "import sys; print(sys.executable)"
```

脚本不需要安装第三方 Python 包。

## 配置问题

确认当前任务进程能够读取环境变量：

```bash
python3 -c "import os; print(bool(os.getenv('MAOGUAI_ACCOUNT'))); print(bool(os.getenv('MAOGUAI_PASSWORD')))"
```

上面的命令只输出是否存在，不会打印敏感值。

## 接口问题

- 状态查询遇到 HTTP 429、5xx 或临时网络错误时，会按 `MAOGUAI_RETRIES` 重试（范围为 `0` 到 `5`），并退避等待或遵循 `Retry-After`；登录和签到请求不会自动重试。若签到请求未返回或响应格式无效，脚本会额外查询一次签到状态；确认已签到会报告成功，否则保留原始错误，签到状态可能仍不确定。
- 登录失败时不要反复提高重试次数，先确认账号密码是否正确。
- 如果出现“响应格式错误”，应记录接口字段变化后再修改模型，不要直接放宽校验绕过认证判断。
