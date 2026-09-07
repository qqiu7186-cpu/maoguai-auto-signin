"""2550505.com HTTP 客户端和请求签名。"""

import hashlib
import http.cookiejar
import json
import math
import os
import random
import ssl
import tempfile
import time
import uuid
import urllib.error
import urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Any, Optional
from urllib.parse import urlparse

from .config import Settings
from .errors import RequestError, ResponseFormatError, SessionError


MAX_RETRY_DELAY_SECONDS = 60.0
MAX_RESPONSE_BYTES = 1024 * 1024


class ApiClient:
    """负责 HTTP、Cookie 和前端兼容的 SHA-256 请求签名。"""

    def __init__(self, settings: Settings, opener=None):
        self.settings = settings
        self.cookies = http.cookiejar.MozillaCookieJar()
        self._token = ""
        self.opener = opener or self._build_opener()

    @property
    def session_file(self):
        """返回展开后的会话文件路径。"""
        return os.path.abspath(os.path.expanduser(self.settings.session_file))

    def load_session(self):
        """从本地加载 Cookie；文件不存在或损坏时安全地从空会话开始。"""
        filename = self.session_file
        self._token = ""
        self.cookies.clear()
        try:
            _restrict_session_file_permissions(filename)
            self.cookies.load(filename, ignore_discard=True, ignore_expires=False)
        except FileNotFoundError:
            self.cookies.clear()
            return False
        except (http.cookiejar.LoadError, ValueError):
            self.cookies.clear()
            return False
        except OSError as exc:
            self.cookies.clear()
            raise SessionError("无法安全读取会话文件") from exc
        return bool(self.token())

    def save_session(self):
        """以受限权限原子保存 Cookie，避免半写文件或泄露凭据。"""
        filename = self.session_file
        parent = os.path.dirname(filename) or "."
        temporary_name = None
        try:
            try:
                os.makedirs(parent, mode=0o700, exist_ok=False)
            except FileExistsError:
                pass
            fd, temporary_name = tempfile.mkstemp(
                prefix="." + os.path.basename(filename) + ".",
                dir=parent,
                text=True,
            )
            os.close(fd)
            self.cookies.save(
                temporary_name, ignore_discard=True, ignore_expires=True
            )
            os.chmod(temporary_name, 0o600)
            os.replace(temporary_name, filename)
            temporary_name = None
            os.chmod(filename, 0o600)
        except OSError as exc:
            raise SessionError("无法安全保存会话文件") from exc
        finally:
            if temporary_name:
                try:
                    os.unlink(temporary_name)
                except OSError:
                    pass

    def clear_session(self):
        """清空当前会话并覆盖本地会话文件。"""
        self.cookies.clear()
        self._token = ""
        self.save_session()

    def _build_opener(self):
        ca_file = next(
            (
                path
                for path in (
                    os.getenv("SSL_CERT_FILE", ""),
                    "/etc/ssl/cert.pem",
                    "/etc/ssl/certs/ca-certificates.crt",
                )
                if path and os.path.isfile(path)
            ),
            None,
        )
        ssl_context = (
            ssl.create_default_context(cafile=ca_file)
            if ca_file
            else ssl.create_default_context()
        )
        return urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookies),
            urllib.request.HTTPSHandler(context=ssl_context),
        )

    def token(self):
        """返回 CookieJar 或登录响应中保存的 token。"""
        for cookie in self.cookies:
            if cookie.name == "token":
                return cookie.value
        return self._token

    def set_token(self, token: str):
        """保存 JSON 响应中的 token，使后续请求与 Cookie 登录一致。"""
        self._token = str(token).strip()
        if not self._token:
            return
        parsed = urlparse(self.settings.base_url)
        host = parsed.hostname or "2550505.com"
        cookie = http.cookiejar.Cookie(
            version=0,
            name="token",
            value=self._token,
            port=None,
            port_specified=False,
            domain=host,
            domain_specified=False,
            domain_initial_dot=False,
            path="/",
            path_specified=True,
            secure=parsed.scheme == "https",
            expires=None,
            discard=True,
            comment=None,
            comment_url=None,
            rest={},
            rfc2109=False,
        )
        self.cookies.set_cookie(cookie)

    def _build_request(self, path: str, method: str, data: Optional[Any]):
        normalized_path = path if path.startswith("/") else "/" + path
        json_data = None if data is None else json.dumps(
            data, ensure_ascii=False, separators=(",", ":")
        )
        js_data = "undefined" if json_data is None else json_data
        token = self.token() or "undefined"
        signature_source = normalized_path + js_data + token
        headers = {
            "Accept": "application/json, text/plain, */*",
            "User-Agent": "Mozilla/5.0 (QingLong; 2550505-sign)",
            "Authorization": str(uuid.uuid4()),
            "X-Client-Version": self.settings.client_version,
            "hash": hashlib.sha256(signature_source.encode("utf-8")).hexdigest(),
        }
        body = None
        if json_data is not None:
            body = json_data.encode("utf-8")
            headers["Content-Type"] = "application/json"
        return urllib.request.Request(
            self.settings.base_url.rstrip("/") + normalized_path,
            data=body,
            headers=headers,
            method=method,
        )

    def request(self, path, method="GET", data=None):
        """发送请求并解析 JSON；仅对幂等请求进行有限重试。"""
        retryable_method = method.upper() in {"GET", "HEAD", "OPTIONS"}
        for attempt in range(self.settings.retries + 1):
            request = self._build_request(path, method, data)
            try:
                with self.opener.open(request, timeout=self.settings.timeout) as response:
                    raw = _read_response(response).decode("utf-8", errors="replace")
                try:
                    payload = json.loads(raw)
                except json.JSONDecodeError as exc:
                    raise ResponseFormatError("接口返回了非 JSON 内容") from exc
                if not isinstance(payload, dict):
                    raise ResponseFormatError("接口返回不是 JSON 对象")
                return payload
            except urllib.error.HTTPError as exc:
                detail = _read_error_detail(exc)
                if (
                    not retryable_method
                    or not _retryable_status(exc.code)
                    or attempt >= self.settings.retries
                ):
                    raise RequestError(
                        f"HTTP 请求失败（状态码 {exc.code}）",
                        status_code=exc.code,
                        detail=detail,
                    ) from exc
                time.sleep(_retry_delay(exc, attempt))
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                if not retryable_method or attempt >= self.settings.retries:
                    raise RequestError("网络请求失败", detail=str(exc)) from exc
                time.sleep(_retry_delay(None, attempt))

        raise RequestError("网络请求失败")


def _retryable_status(status_code):
    return status_code == 429 or status_code >= 500


def _restrict_session_file_permissions(filename):
    mode = os.stat(filename).st_mode & 0o777
    if mode & 0o077:
        os.chmod(filename, 0o600)


def _read_response(response):
    body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise ResponseFormatError("接口响应体过大")
    return body


def _retry_delay(error, attempt):
    retry_after = _retry_after_delay(error)
    if retry_after is not None:
        return min(retry_after, MAX_RETRY_DELAY_SECONDS)
    return min(2**attempt + random.uniform(0, 1), MAX_RETRY_DELAY_SECONDS)


def _retry_after_delay(error):
    if error is None:
        return None
    headers = getattr(error, "headers", None)
    value = headers.get("Retry-After") if headers else None
    if not value:
        return None
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        try:
            retry_at = parsedate_to_datetime(value)
        except (TypeError, ValueError, IndexError):
            return None
        if retry_at.tzinfo is None:
            retry_at = retry_at.replace(tzinfo=timezone.utc)
        seconds = (retry_at - datetime.now(timezone.utc)).total_seconds()
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return seconds


def _read_error_detail(error):
    try:
        return error.read(201).decode("utf-8", errors="replace")[:200]
    except (AttributeError, UnicodeError):
        return ""
