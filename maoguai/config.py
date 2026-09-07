"""运行配置。"""

import os
from dataclasses import dataclass, field
from typing import Mapping, Optional
from urllib.parse import urlparse

from .errors import ConfigurationError


DEFAULT_BASE_URL = "https://2550505.com"
DEFAULT_CLIENT_VERSION = "0c1c05"


@dataclass(frozen=True)
class Settings:
    """签到程序运行所需的配置。"""

    account: str = ""
    password: str = field(default="", repr=False)
    base_url: str = DEFAULT_BASE_URL
    client_version: str = DEFAULT_CLIENT_VERSION
    timeout: float = 30.0
    retries: int = 2

    @classmethod
    def from_env(cls, environ: Optional[Mapping[str, str]] = None):
        """从环境变量创建配置对象。"""
        env = os.environ if environ is None else environ
        settings = cls(
            account=env.get("MAOGUAI_ACCOUNT", "").strip(),
            password=env.get("MAOGUAI_PASSWORD", ""),
            base_url=env.get("MAOGUAI_BASE_URL", DEFAULT_BASE_URL).strip(),
            client_version=env.get(
                "MAOGUAI_CLIENT_VERSION", DEFAULT_CLIENT_VERSION
            ).strip(),
            timeout=_read_float(env, "MAOGUAI_TIMEOUT", 30.0),
            retries=_read_int(env, "MAOGUAI_RETRIES", 2),
        )
        settings.validate()
        return settings

    def validate(self):
        """校验配置并在发现问题时抛出可读异常。"""
        missing = []
        if not self.account:
            missing.append("MAOGUAI_ACCOUNT")
        if not self.password:
            missing.append("MAOGUAI_PASSWORD")
        if missing:
            raise ConfigurationError("请先在青龙添加 " + " 和 ".join(missing))

        parsed = urlparse(self.base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ConfigurationError("MAOGUAI_BASE_URL 不是有效的 HTTP(S) 地址")
        if not self.client_version:
            raise ConfigurationError("MAOGUAI_CLIENT_VERSION 不能为空")
        if self.timeout <= 0:
            raise ConfigurationError("MAOGUAI_TIMEOUT 必须大于 0")
        if self.retries < 0:
            raise ConfigurationError("MAOGUAI_RETRIES 不能小于 0")


def _read_float(environ, name, default):
    value = environ.get(name, "").strip()
    if not value:
        return default
    try:
        return float(value)
    except ValueError as exc:
        raise ConfigurationError(f"{name} 必须是数字") from exc


def _read_int(environ, name, default):
    value = environ.get(name, "").strip()
    if not value:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise ConfigurationError(f"{name} 必须是整数") from exc
