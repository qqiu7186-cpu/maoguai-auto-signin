"""运行配置。"""

import math
import os
from dataclasses import dataclass, field
from typing import Mapping, Optional
from urllib.parse import urlparse

from .errors import ConfigurationError


DEFAULT_BASE_URL = "https://2550505.com"
DEFAULT_CLIENT_VERSION = "0c1c05"
DEFAULT_SESSION_FILE = "data/session.cookies"
DEFAULT_HOST = "2550505.com"
MAX_RETRIES = 5


@dataclass(frozen=True)
class Settings:
    """签到程序运行所需的配置。"""

    account: str = ""
    password: str = field(default="", repr=False)
    base_url: str = DEFAULT_BASE_URL
    client_version: str = DEFAULT_CLIENT_VERSION
    session_file: str = DEFAULT_SESSION_FILE
    timeout: float = 30.0
    retries: int = 2
    allow_custom_base_url: bool = False

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
            session_file=env.get(
                "MAOGUAI_SESSION_FILE", DEFAULT_SESSION_FILE
            ).strip(),
            timeout=_read_float(env, "MAOGUAI_TIMEOUT", 30.0),
            retries=_read_int(env, "MAOGUAI_RETRIES", 2),
            allow_custom_base_url=_read_bool(
                env, "MAOGUAI_ALLOW_CUSTOM_BASE_URL", False
            ),
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
        try:
            parsed.port
        except ValueError as exc:
            raise ConfigurationError("MAOGUAI_BASE_URL 端口无效") from exc
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username
            or parsed.password
            or parsed.path not in {"", "/"}
            or parsed.params
            or parsed.query
            or parsed.fragment
        ):
            raise ConfigurationError("MAOGUAI_BASE_URL 必须是有效的 HTTPS 根地址")
        if parsed.hostname != DEFAULT_HOST and not self.allow_custom_base_url:
            raise ConfigurationError(
                "MAOGUAI_BASE_URL 仅允许目标站点；测试环境请显式设置 "
                "MAOGUAI_ALLOW_CUSTOM_BASE_URL=true"
            )
        if not self.client_version:
            raise ConfigurationError("MAOGUAI_CLIENT_VERSION 不能为空")
        if not self.session_file:
            raise ConfigurationError("MAOGUAI_SESSION_FILE 不能为空")
        if os.path.abspath(os.path.expanduser(self.session_file)) == os.path.abspath(
            os.devnull
        ):
            raise ConfigurationError("MAOGUAI_SESSION_FILE 不能是系统空设备")
        if not math.isfinite(self.timeout) or self.timeout <= 0:
            raise ConfigurationError("MAOGUAI_TIMEOUT 必须是大于 0 的有限数字")
        if not 0 <= self.retries <= MAX_RETRIES:
            raise ConfigurationError(
                f"MAOGUAI_RETRIES 必须是 0 到 {MAX_RETRIES} 之间的整数"
            )


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


def _read_bool(environ, name, default):
    value = environ.get(name, "").strip().lower()
    if not value:
        return default
    if value in {"1", "true", "yes"}:
        return True
    if value in {"0", "false", "no"}:
        return False
    raise ConfigurationError(f"{name} 必须是 true 或 false")
