import unittest

from maoguai.config import Settings
from maoguai.errors import RequestError
from maoguai.runner import RunStatus, SignInRunner


class FakeClient:
    def __init__(self, responses, token=""):
        self.responses = iter(responses)
        self.calls = []
        self._token = token
        self.loaded = 0
        self.saved = 0
        self.cleared = 0

    def request(self, path, method="GET", data=None):
        self.calls.append((path, method, data))
        response = next(self.responses)
        if isinstance(response, Exception):
            raise response
        return response

    def token(self):
        return self._token

    def set_token(self, token):
        self._token = token

    def load_session(self):
        self.loaded += 1

    def save_session(self):
        self.saved += 1

    def clear_session(self):
        self.cleared += 1
        self._token = ""


class FailingClient:
    def request(self, path, method="GET", data=None):
        raise RequestError("HTTP 请求失败（状态码 500）", detail='{"token":"secret"}')


class SessionFailingClient:
    def load_session(self):
        raise OSError("permission denied")


class RunnerTest(unittest.TestCase):
    def setUp(self):
        self.settings = Settings(account="user", password="secret")

    def test_signs_when_not_signed(self):
        client = FakeClient(
            [
                {"code": 0, "token": "token"},
                {"code": 0, "signed": False},
                {"code": 0, "msg": "完成", "exp": 10, "contrbution": 2},
            ]
        )
        result = SignInRunner(self.settings, client).run()
        self.assertEqual(result.status, RunStatus.SUCCESS)
        self.assertEqual(result.exit_code, 0)
        self.assertEqual(client._token, "token")
        self.assertEqual(
            [call[0] for call in client.calls],
            ["/auth/login", "/sign/signed", "/sign"],
        )

    def test_skips_when_already_signed(self):
        client = FakeClient(
            [{"code": 0, "token": "token"}, {"code": 0, "signed": True}]
        )
        result = SignInRunner(self.settings, client).run()
        self.assertEqual(result.status, RunStatus.ALREADY_SIGNED)
        self.assertEqual(len(client.calls), 2)

    def test_valid_persisted_session_skips_login(self):
        client = FakeClient([{"code": 0, "signed": True}], token="cached")
        result = SignInRunner(self.settings, client).run()
        self.assertEqual(result.status, RunStatus.ALREADY_SIGNED)
        self.assertEqual([call[0] for call in client.calls], ["/sign/signed"])
        self.assertEqual(client.loaded, 1)

    def test_expired_persisted_session_relogs_once(self):
        client = FakeClient(
            [
                {"code": 401, "msg": "未登录"},
                {"code": 0, "token": "refreshed"},
                {"code": 0, "signed": True},
            ],
            token="expired",
        )
        result = SignInRunner(self.settings, client).run()
        self.assertEqual(result.status, RunStatus.ALREADY_SIGNED)
        self.assertEqual(
            [call[0] for call in client.calls],
            ["/sign/signed", "/auth/login", "/sign/signed"],
        )
        self.assertEqual(client.cleared, 1)
        self.assertEqual(client._token, "refreshed")

    def test_rejects_successful_login_without_token(self):
        client = FakeClient([{"code": 0}, {"code": 0, "signed": False}])
        result = SignInRunner(self.settings, client).run()
        self.assertEqual(result.status, RunStatus.LOGIN_FAILED)
        self.assertEqual(len(client.calls), 1)

    def test_does_not_include_http_response_detail_in_result(self):
        result = SignInRunner(self.settings, FailingClient()).run()
        self.assertEqual(result.status, RunStatus.NETWORK_ERROR)
        self.assertNotIn("secret", result.message)

    def test_confirms_sign_in_after_ambiguous_request_error(self):
        client = FakeClient(
            [
                {"code": 0, "token": "token"},
                {"code": 0, "signed": False},
                RequestError("网络请求失败"),
                {"code": 0, "signed": True},
            ]
        )

        result = SignInRunner(self.settings, client).run()

        self.assertEqual(result.status, RunStatus.SUCCESS)
        self.assertEqual(result.exit_code, 0)
        self.assertIn("状态已确认", result.message)
        self.assertEqual(
            [call[0] for call in client.calls],
            ["/auth/login", "/sign/signed", "/sign", "/sign/signed"],
        )

    def test_confirms_sign_in_after_malformed_sign_response(self):
        client = FakeClient(
            [
                {"code": 0, "token": "token"},
                {"code": 0, "signed": False},
                {},
                {"code": 0, "signed": True},
            ]
        )

        result = SignInRunner(self.settings, client).run()

        self.assertEqual(result.status, RunStatus.SUCCESS)
        self.assertEqual(
            [call[0] for call in client.calls],
            ["/auth/login", "/sign/signed", "/sign", "/sign/signed"],
        )

    def test_returns_local_state_error_when_session_access_fails(self):
        try:
            result = SignInRunner(self.settings, SessionFailingClient()).run()
        except OSError:
            status = "unhandled"
            exit_code = None
        else:
            status = result.status.value
            exit_code = result.exit_code

        self.assertEqual(status, "local_state_error")
        self.assertEqual(exit_code, 1)


if __name__ == "__main__":
    unittest.main()
