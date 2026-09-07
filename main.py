#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""毛怪俱乐部（2550505.com）自动登录签到入口。"""

import sys

from maoguai.config import Settings
from maoguai.errors import ConfigurationError
from maoguai.runner import SignInRunner


def main(environ=None):
    """执行一次签到并返回适合青龙任务的退出码。"""
    try:
        settings = Settings.from_env(environ)
    except ConfigurationError as exc:
        print(f"❌ {exc}")
        return 1

    try:
        result = SignInRunner(settings).run()
    except Exception:  # pragma: no cover - 仅作为入口兜底
        print("❌ 运行异常，请检查配置和网络环境")
        return 1
    print(result.message)
    return result.exit_code


if __name__ == "__main__":
    sys.exit(main())
