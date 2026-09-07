# GitHub Actions 部署

仓库已经提供定时工作流 `.github/workflows/sign.yml`，默认每天 UTC `00:05` 执行，对应中国标准时间 `08:05`。

## 配置 Secrets

在仓库的 `Settings -> Secrets and variables -> Actions` 中添加：

```text
MAOGUAI_ACCOUNT
MAOGUAI_PASSWORD
```

两个值都应保存为 Repository secrets，不要写在 workflow 文件中。

## 手动执行

打开仓库的 `Actions -> 毛怪俱乐部签到 -> Run workflow`，可以手动触发一次。工作流不会输出凭据值。

## 注意事项

- 定时任务只在默认分支的最新提交上运行。
- GitHub Actions 可能因仓库长期无活动而延迟或停用定时任务，重要任务建议使用青龙或自己的服务器。
- 使用 GitHub-hosted runner 会从 GitHub 网络访问目标站点，请根据目标站点规则和账号风险自行决定。
