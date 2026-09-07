"""签到业务流程编排。"""

from dataclasses import dataclass
from enum import Enum
from typing import Optional

from .client import ApiClient
from .config import Settings
from .errors import RequestError, ResponseFormatError
from .models import ApiResponse, SignResult, SignStatus, extract_token


class RunStatus(Enum):
    SUCCESS = "success"
    ALREADY_SIGNED = "already_signed"
    LOGIN_FAILED = "login_failed"
    STATUS_FAILED = "status_failed"
    SIGN_FAILED = "sign_failed"
    NETWORK_ERROR = "network_error"
    INVALID_RESPONSE = "invalid_response"


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

            status_response = ApiResponse.from_payload(
                self.client.request("/sign/signed")
            )
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

            sign_response = ApiResponse.from_payload(
                self.client.request("/sign", method="POST")
            )
            if not sign_response.success:
                return RunResult(
                    RunStatus.SIGN_FAILED,
                    f"⚠️ 签到未完成：{_message(sign_response.message)}",
                )
            result = SignResult.from_response(sign_response)
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


def _message(message):
    return message or "未知错误"
