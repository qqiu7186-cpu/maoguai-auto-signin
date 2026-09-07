"""接口响应模型和结构校验。"""

from dataclasses import dataclass
from typing import Any, Dict, Optional

from .errors import ResponseFormatError


@dataclass(frozen=True)
class ApiResponse:
    """接口通用响应。"""

    code: int
    message: str
    payload: Dict[str, Any]

    @classmethod
    def from_payload(cls, payload):
        if not isinstance(payload, dict):
            raise ResponseFormatError("接口返回不是 JSON 对象")
        if "code" not in payload:
            raise ResponseFormatError("接口返回缺少 code 字段")
        try:
            code = int(payload["code"])
        except (TypeError, ValueError) as exc:
            raise ResponseFormatError("接口返回的 code 字段无效") from exc
        message = payload.get("msg", payload.get("message", ""))
        return cls(code=code, message="" if message is None else str(message), payload=payload)

    @property
    def success(self):
        return self.code == 0


@dataclass(frozen=True)
class SignStatus:
    """今日签到状态。"""

    signed: bool

    @classmethod
    def from_response(cls, response: ApiResponse):
        value = response.payload.get("signed")
        if value is None and isinstance(response.payload.get("data"), dict):
            value = response.payload["data"].get("signed")
        if not isinstance(value, bool):
            raise ResponseFormatError("签到状态响应缺少有效的 signed 字段")
        return cls(signed=value)


@dataclass(frozen=True)
class SignResult:
    """签到结果。"""

    message: str
    experience: Any = 0
    contribution: Any = 0

    @classmethod
    def from_response(cls, response: ApiResponse):
        payload = response.payload
        contribution = payload.get("contrbution", payload.get("contribution", 0))
        return cls(response.message or "完成", payload.get("exp", 0), contribution)


def extract_token(payload: Dict[str, Any]) -> Optional[str]:
    """兼容顶层和常见 data 嵌套形式的 token 返回。"""
    containers = [payload]
    data = payload.get("data")
    if isinstance(data, dict):
        containers.append(data)
        nested = data.get("data")
        if isinstance(nested, dict):
            containers.append(nested)
    for container in containers:
        token = container.get("token")
        if token is not None and str(token):
            return str(token)
    return None
