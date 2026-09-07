# Maoguai Club Automatic Check-in

English | [简体中文](README.zh-CN.md)

An automatic login and daily check-in script for `2550505.com`, suitable for QingLong, local scheduled tasks, Docker, and GitHub Actions.

> You are responsible for the risk to your account when using this project. Do not commit your account, password, cookies, or tokens, and do not use this project in violation of the target site's rules.

## Features

- Automatically logs in and uses session cookies
- Reuses persisted cookies first, then falls back to password login when the session expires
- Checks today's status and skips duplicate check-ins
- Performs the check-in when needed and reports experience and contribution earned
- Supports login APIs that return a token through either a cookie or JSON
- Retries idempotent requests such as status checks a limited number of times, without repeating a check-in
- Uses no third-party Python dependencies

## Quick Start

Python 3.8 or later is required:

```bash
export MAOGUAI_ACCOUNT="your account or UID"
export MAOGUAI_PASSWORD="your password"
python3 main.py
```

For local testing, you can copy `.env.example` as an environment-variable checklist. The script does not load `.env` files automatically.

## Deployment Options

| Method | Best for | Notes |
| --- | --- | --- |
| [Run locally and with Crontab](docs/local.md) | Linux, macOS, or a server | Minimal dependencies and suitable for long-term use |
| [Windows](docs/windows.md) | Windows 10/11 | Runs directly; use Task Scheduler for scheduled execution |
| [Docker](docs/docker.md) | Existing container users | Isolated environment; the container exits after one run |
| [Docker Compose](docs/docker.md) | Docker users | Manage the image and environment variables together |
| [QingLong](docs/qinglong.md) | Scheduled-task panel users | Suitable for an existing QingLong installation |
| [GitHub Actions](docs/github-actions.md) | Users who do not want to maintain a server | Runs on a UTC schedule after configuring Secrets |

All options use the same `main.py` entry point and environment variables. The linked deployment guides are currently in Simplified Chinese.

## Documentation Index

- [README (简体中文)](README.zh-CN.md)
- [Local and Crontab Deployment](docs/local.md)
- [Windows Deployment](docs/windows.md)
- [Docker and Docker Compose Deployment](docs/docker.md)
- [QingLong Deployment](docs/qinglong.md)
- [GitHub Actions Deployment](docs/github-actions.md)
- [Troubleshooting Guide](docs/troubleshooting.md)

## Windows

The core script supports Windows 10/11. When installing Python 3.8 or later, select "Add Python to PATH." The project has no third-party Python dependencies.

Run directly in PowerShell:

```powershell
$env:MAOGUAI_ACCOUNT = "your account or UID"
$env:MAOGUAI_PASSWORD = "your password"
py .\main.py
```

Run directly in Command Prompt (CMD):

```bat
set MAOGUAI_ACCOUNT=your-account-or-UID
set MAOGUAI_PASSWORD=your-password
py main.py
```

These variables are available only in the current terminal session. Use Task Scheduler for scheduled execution on Windows; see the [Windows deployment guide](docs/windows.md) for fields and security settings. The Unix scripts `scripts/run.sh` and `scripts/run-cron.sh` do not work on Windows.

## QingLong

1. Clone the repository into the QingLong scripts directory.
2. Add the `MAOGUAI_ACCOUNT` and `MAOGUAI_PASSWORD` environment variables.
3. Create a task with this command:

   ```bash
   python3 /your/path/2550/main.py
   ```

4. When QingLong uses the `Asia/Shanghai` time zone, run it daily at `08:05` with the cron expression `5 8 * * *`.

See the [QingLong deployment guide](docs/qinglong.md) for details.

## Docker Quick Start

```bash
cp .env.example .env
chmod 600 .env
mkdir -p data
chmod 700 data
printf 'MAOGUAI_UID=%s\nMAOGUAI_GID=%s\n' "$(id -u)" "$(id -g)" >> .env
docker compose build
docker compose run --rm maoguai-sign
```

See the [Docker deployment guide](docs/docker.md) for details.

## GitHub Actions Quick Start

Add `MAOGUAI_ACCOUNT` and `MAOGUAI_PASSWORD` to the repository Secrets. The workflow runs daily at `08:05` China Standard Time and can also be triggered manually.

See the [GitHub Actions deployment guide](docs/github-actions.md) for details.

## Configuration

| Environment variable | Required | Default | Description |
| --- | --- | --- | --- |
| `MAOGUAI_ACCOUNT` | Yes | None | Account or UID |
| `MAOGUAI_PASSWORD` | Yes | None | Account password |
| `MAOGUAI_BASE_URL` | No | `https://2550505.com` | HTTPS API root; the target host is required by default |
| `MAOGUAI_ALLOW_CUSTOM_BASE_URL` | No | `false` | Set to `true` only for a trusted HTTPS test endpoint |
| `MAOGUAI_CLIENT_VERSION` | No | `0c1c05` | Client-version identifier |
| `MAOGUAI_SESSION_FILE` | No | `data/session.cookies` | Path to the persisted login-cookie file |
| `MAOGUAI_TIMEOUT` | No | `30` | Timeout for each request, in seconds |
| `MAOGUAI_RETRIES` | No | `2` | Idempotent-request retries, from `0` to `5`; waits with backoff and honors `Retry-After` |

## Exit Codes

| Exit code | Meaning |
| --- | --- |
| `0` | The check-in succeeded or was already completed today |
| `1` | Configuration, login, API, network, or check-in failure |

## Project Structure

```text
main.py       # QingLong-compatible entry point
maoguai/
  config.py   # Environment-variable loading and validation
  client.py   # HTTP, cookies, request signing, and retries
  models.py   # API response models and structural validation
  runner.py   # Login, status-check, and check-in flow
  errors.py   # Project-level exceptions
tests/        # Unit tests that do not access the live service
docs/         # Deployment and troubleshooting guides
```

Dependencies flow as `main.py -> runner.py -> client.py/models.py`. Business flows do not read environment variables directly, and the network client does not decide check-in behavior. Future tasks can be split into `maoguai/tasks/`.

## Development and Testing

The project uses only the Python standard library. Run:

```bash
python3 -m unittest discover -v
```

Tests use mock clients and locally constructed responses. They do not log in, check in, or access the live service.

## Troubleshooting

- **Missing environment variables**: Ensure the names are exactly `MAOGUAI_ACCOUNT` and `MAOGUAI_PASSWORD`, and verify that the task environment can read them.
- **Login succeeds but no token is available**: The script refuses to continue, preventing calls in an unauthenticated state. Check the API response, saved cookies, and network environment.
- **Invalid API response format**: The target site's API may have changed. Update `maoguai/models.py` for the actual response.
- **Frequent network failures**: You can increase `MAOGUAI_TIMEOUT` or set `MAOGUAI_RETRIES` up to `5`. Retries wait with backoff and honor the server's `Retry-After` response.

## License

This project is licensed under the [MIT License](LICENSE). You remain responsible for account risk and complying with the target site's rules.
