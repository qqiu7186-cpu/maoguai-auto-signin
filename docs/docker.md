# Docker 部署

容器设计为“一次执行后退出”，定时任务交给宿主机、Docker Compose 外部调度器或平台完成。

## Docker 单次运行

准备变量文件：

```bash
cp .env.example .env
chmod 600 .env
```

构建镜像：

```bash
docker build -t maoguai-sign:local .
```

执行一次：

```bash
docker run --rm --env-file .env maoguai-sign:local
```

## Docker Compose

```bash
cp .env.example .env
chmod 600 .env
docker compose build
docker compose run --rm maoguai-sign
```

也可以使用仓库提供的包装脚本：

```bash
sh scripts/run-docker.sh
```

Compose 不会在容器内常驻，也不会自行重复签到。建议使用宿主机 Crontab 调用：

```cron
5 8 * * * cd /你的路径/2550 && /usr/bin/docker compose run --rm maoguai-sign >> /tmp/maoguai-sign.log 2>&1
```

上面的 Cron 假设宿主机时区为 `Asia/Shanghai`；其他时区请自行换算。

## 镜像发布

如果你把镜像发布到自己的 Registry，运行时只需要替换镜像名称：

```bash
docker pull ghcr.io/你的用户名/maoguai-sign:latest
docker run --rm --env-file .env ghcr.io/你的用户名/maoguai-sign:latest
```

不要把账号密码写进 Dockerfile、镜像层或 Compose 文件。
