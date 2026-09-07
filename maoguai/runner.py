"""签到业务流程编排。"""

from dataclasses import dataclass
from enum import Enum
from typing import Optional

from .client import ApiClient
from .config import Settings
from .errors import RequestError, ResponseFormatError, SessionError
from .models import ApiResponse, SignResult, SignStatus, extract_token


class RunStatus(Enum):
    SUCCESS = "success"
    ALREADY_SIGNED = "already_signed"
    LOGIN_FAILED = "login_failed"
    STATUS_FAILED = "status_failed"
    SIGN_FAILED = "sign_failed"
    NETWORK_ERROR = "network_error"
    INVALID_RESPONSE = "invalid_response"
    LOCAL_STATE_ERROR = "local_state_error"


@dataclass(frozen=True)
class RunResult:
    status: RunStatus
    message: str

    @property
    def exit_code(self):
        return 0 if self.status in {RunStatus.SUCCESS, RunStatus.ALREADY_SIGNED} else 1


class SignInRunner:
    """执行登录、查询签到状态和签到三个步骤。"""

    def __init__(self, settings: Settings, client: Optional[ApiClient] = None):
        self.settings = settings
        self.client = client or ApiClient(settings)

    def run(self):
        try:
            self._load_session()
            status_response = None
            if self._has_token():
                try:
                    status_response = self._status_response()
                except RequestError as exc:
                    if not _is_auth_failure_error(exc):
                        return RunResult(RunStatus.NETWORK_ERROR, f"❌ {exc}")
                    self._clear_session()

                if status_response is not None:
                    if not status_response.success:
                        if not _is_auth_failure_response(status_response):
                            return RunResult(
                                RunStatus.STATUS_FAILED,
                                f"❌ 查询签到状态失败：{_message(status_response.message)}",
                            )
                        self._clear_session()
                        status_response = None
                    else:
                        self._save_session()

            if status_response is None:
                login_result = self._login()
                if login_result is not None:
                    return login_result
                status_response = self._status_response()
                self._save_session()

            if not status_response.success:
                return RunResult(
                    RunStatus.STATUS_FAILED,
                    f"❌ 查询签到状态失败：{_message(status_response.message)}",
                )
            status = SignStatus.from_response(status_response)
            if status.signed:
                return RunResult(
                    RunStatus.ALREADY_SIGNED,
                    "✅ 今天已经签到，无需重复操作",
                )

            try:
                sign_response = ApiResponse.from_payload(
                    self.client.request("/sign", method="POST")
                )
            except RequestError:
                if self._sign_in_was_confirmed():
                    self._save_session()
                    return RunResult(
                        RunStatus.SUCCESS,
                        "✅ 签到请求未返回，但签到状态已确认",
                    )
                raise
            if not sign_response.success:
                return RunResult(
                    RunStatus.SIGN_FAILED,
                    f"⚠️ 签到未完成：{_message(sign_response.message)}",
                )
            result = SignResult.from_response(sign_response)
            self._save_session()
            return RunResult(
                RunStatus.SUCCESS,
                f"✅ 签到成功：{result.message}；经验 +{result.experience}，"
                f"贡献 +{result.contribution}",
            )
        except RequestError as exc:
            # HTTP 响应体可能包含认证信息，日志只输出安全的错误摘要。
            return RunResult(RunStatus.NETWORK_ERROR, f"❌ {exc}")
        except ResponseFormatError as exc:
            return RunResult(RunStatus.INVALID_RESPONSE, f"❌ 响应格式错误：{exc}")
        except (SessionError, OSError):
            return RunResult(
                RunStatus.LOCAL_STATE_ERROR,
                "❌ 本地会话文件无法安全读写，请检查路径和文件权限",
            )

    def _login(self):
        login = ApiResponse.from_payload(
            self.client.request(
                "/auth/login",
                method="POST",
                data={
                    "account": self.settings.account,
                    "password": self.settings.password,
                },
            )
        )
        if not login.success:
            return RunResult(
                RunStatus.LOGIN_FAILED,
                f"❌ 登录失败：{_message(login.message)}",
            )

        token = extract_token(login.payload)
        if token:
            self.client.set_token(token)
        if not self.client.token():
            return RunResult(
                RunStatus.LOGIN_FAILED,
                "❌ 登录成功但未获取到 token，请检查接口返回或网络环境",
            )
        self._save_session()
        return None

    def _status_response(self):
        return ApiResponse.from_payload(self.client.request("/sign/signed"))

    def _sign_in_was_confirmed(self):
        """在签到请求异常后只读确认，避免重复签到或误报失败。"""
        try:
            status_response = self._status_response()
            return status_response.success and SignStatus.from_response(
                status_response
            ).signed
        except (RequestError, ResponseFormatError):
            return False

    def _load_session(self):
        method = getattr(self.client, "load_session", None)
        if method:
            method()

    def _save_session(self):
        method = getattr(self.client, "save_session", None)
        if method:
            method()

    def _clear_session(self):
        method = getattr(self.client, "clear_session", None)
        if method:
            method()
        else:
            self.client.set_token("")

    def _has_token(self):
        method = getattr(self.client, "token", None)
        return bool(method and method())


def _message(message):
    return message or "未知错误"


def _is_auth_failure_error(error):
    return error.status_code in {401, 403}


def _is_auth_failure_response(response):
    if response.code in {401, 403}:
        return True
    message = response.message.lower()
    markers = (
        "unauthorized",
        "not authenticated",
        "未登录",
        "请先登录",
        "认证失败",
        "凭证无效",
        "token expired",
        "token invalid",
        "登录已过期",
    )
    return any(marker in message for marker in markers)
