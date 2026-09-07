"""项目级异常定义。"""


class MaoguaiError(Exception):
    """所有可预期的业务异常基类。"""


class ConfigurationError(MaoguaiError):
    """运行配置缺失或格式不正确。"""


class RequestError(MaoguaiError):
    """网络请求失败。"""

    def __init__(self, message, status_code=None, detail=""):
        super().__init__(message)
        self.status_code = status_code
        self.detail = detail


class ResponseFormatError(MaoguaiError):
    """接口返回的数据不是预期结构。"""
