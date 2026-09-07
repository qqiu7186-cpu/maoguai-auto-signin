import hashlib
import http.client
import io
import json
import os
import tempfile
import unittest
import urllib.error
import urllib.request
from unittest import mock

from maoguai.client import ApiClient
from maoguai.config import Settings
from maoguai.errors import RequestError, ResponseFormatError, SessionError


class FakeResponse:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self, size=-1):
        return self.body if size < 0 else self.body[:size]


class FlakyOpener:
    def __init__(self):
        self.attempts = 0

    def open(self, request, timeout):
        self.attempts += 1
        if self.attempts == 1:
            raise urllib.error.HTTPError(
                request.full_url,
                503,
                "temporary",
                {},
                io.BytesIO(b"server detail"),
            )
        return FakeResponse(b'{"code":0}')


class ThrottledOpener:
    def __init__(self, retry_after="4"):
        self.attempts = 0
        self.retry_after = retry_after

    def open(self, request, timeout):
        self.attempts += 1
        if self.attempts == 1:
            raise urllib.error.HTTPError(
                request.full_url,
                429,
                "throttled",
                {"Retry-After": self.retry_after},
                io.BytesIO(b"too many requests"),
            )
        return FakeResponse(b'{"code":0}')


class StaticOpener:
    def __init__(self, body):
        self.body = body

    def open(self, request, timeout):
        return FakeResponse(self.body)


class UnreadableErrorStream:
    def read(self, size=-1):
        raise OSError("connection closed")

    def close(self):
        pass


class UnreadableErrorOpener:
    def open(self, request, timeout):
        raise urllib.error.HTTPError(
            request.full_url,
            400,
            "bad request",
            {},
            UnreadableErrorStream(),
        )


class IncompleteResponse(FakeResponse):
    def read(self, size=-1):
        raise http.client.IncompleteRead(b"", 20)


class IncompleteReadOpener:
    def __init__(self):
        self.attempts = 0

    def open(self, request, timeout):
        self.attempts += 1
        return IncompleteResponse(b"")


class ClientTest(unittest.TestCase):
    def setUp(self):
        settings = Settings(
            account="user",
            password="secret",
            base_url="https://example.test",
            client_version="test",
        )
        self.client = ApiClient(settings, opener=object())

    def test_signature_uses_compact_json_and_undefined_for_empty_body(self):
        request = self.client._build_request(
            "/auth/login", "POST", {"account": "用户", "password": "密码"}
        )
        body = request.data.decode("utf-8")
        expected = "/auth/login" + body + "undefined"
        self.assertEqual(
            request.headers["Hash"], hashlib.sha256(expected.encode()).hexdigest()
        )
        self.assertEqual(
            body,
            json.dumps(
                {"account": "用户", "password": "密码"},
                ensure_ascii=False,
                separators=(",", ":"),
            ),
        )

        empty_request = self.client._build_request("/sign", "POST", None)
        expected_empty = "/signundefinedundefined"
        self.assertEqual(
            empty_request.headers["Hash"],
            hashlib.sha256(expected_empty.encode()).hexdigest(),
        )

    def test_json_token_is_available_to_next_request(self):
        self.client.set_token("abc")
        request = self.client._build_request("/sign/signed", "GET", None)
        expected = "/sign/signedundefinedabc"
        self.assertEqual(
            request.headers["Hash"], hashlib.sha256(expected.encode()).hexdigest()
        )
        self.assertEqual(self.client.token(), "abc")

        cookie_request = urllib.request.Request("https://example.test/sign/signed")
        self.client.cookies.add_cookie_header(cookie_request)
        self.assertIn("token=abc", cookie_request.get_header("Cookie"))

    def test_retries_get_but_not_sign_post(self):
        opener = FlakyOpener()
        client = ApiClient(self.client.settings, opener=opener)
        with mock.patch("time.sleep"):
            self.assertEqual(client.request("/sign/signed"), {"code": 0})
        self.assertEqual(opener.attempts, 2)

        opener = FlakyOpener()
        client = ApiClient(self.client.settings, opener=opener)
        with self.assertRaises(RequestError):
            client.request("/sign", method="POST")
        self.assertEqual(opener.attempts, 1)

    def test_waits_before_retrying_an_idempotent_request(self):
        delays = []
        client = ApiClient(self.client.settings, opener=FlakyOpener())

        with mock.patch("time.sleep", delays.append), mock.patch(
            "random.uniform", return_value=0
        ):
            self.assertEqual(client.request("/sign/signed"), {"code": 0})
        self.assertEqual(delays, [1])

    def test_honors_retry_after_header_when_throttled(self):
        delays = []
        client = ApiClient(self.client.settings, opener=ThrottledOpener())

        with mock.patch("time.sleep", delays.append):
            self.assertEqual(client.request("/sign/signed"), {"code": 0})
        self.assertEqual(delays, [4])

    def test_does_not_shorten_the_server_retry_after_delay(self):
        delays = []
        client = ApiClient(
            self.client.settings, opener=ThrottledOpener(retry_after="300")
        )

        with mock.patch("time.sleep", delays.append):
            self.assertEqual(client.request("/sign/signed"), {"code": 0})
        self.assertEqual(delays, [300])

    def test_rejects_response_larger_than_the_safety_limit(self):
        client = ApiClient(
            self.client.settings,
            opener=StaticOpener(b"x" * (1024 * 1024 + 1)),
        )

        with self.assertRaisesRegex(ResponseFormatError, "响应体过大"):
            client.request("/sign/signed")

    def test_converts_unreadable_http_error_body_to_request_error(self):
        client = ApiClient(self.client.settings, opener=UnreadableErrorOpener())

        with self.assertRaises(RequestError):
            client.request("/sign", method="POST")

    def test_retries_an_incomplete_idempotent_response_as_a_request_error(self):
        opener = IncompleteReadOpener()
        client = ApiClient(self.client.settings, opener=opener)

        with mock.patch("time.sleep"):
            with self.assertRaises(RequestError):
                client.request("/sign/signed")
        self.assertEqual(opener.attempts, 3)

    def test_session_is_persisted_with_restricted_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "data", "session.cookies")
            settings = Settings(
                account="user",
                password="secret",
                base_url="https://example.test",
                client_version="test",
                session_file=path,
            )
            client = ApiClient(settings, opener=object())
            client.set_token("persisted")
            client.save_session()

            loaded = ApiClient(settings, opener=object())
            self.assertTrue(loaded.load_session())
            self.assertEqual(loaded.token(), "persisted")
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_corrupt_session_falls_back_to_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "session.cookies")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("not a cookie file")
            settings = Settings(account="user", password="secret", session_file=path)
            client = ApiClient(settings, opener=object())
            self.assertFalse(client.load_session())
            self.assertEqual(client.token(), "")

    def test_session_save_does_not_change_existing_directory_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            os.chmod(directory, 0o755)
            path = os.path.join(directory, "session.cookies")
            settings = Settings(account="user", password="secret", session_file=path)
            client = ApiClient(settings, opener=object())
            client.set_token("persisted")
            client.save_session()
            self.assertEqual(os.stat(directory).st_mode & 0o777, 0o755)

    def test_load_session_restricts_existing_file_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "session.cookies")
            settings = Settings(account="user", password="secret", session_file=path)
            client = ApiClient(settings, opener=object())
            client.set_token("persisted")
            client.save_session()
            os.chmod(path, 0o644)

            loaded = ApiClient(settings, opener=object())
            self.assertTrue(loaded.load_session())
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_load_session_refuses_symbolic_links(self):
        with tempfile.TemporaryDirectory() as directory:
            source = os.path.join(directory, "source.cookies")
            link = os.path.join(directory, "session.cookies")
            settings = Settings(account="user", password="secret", session_file=source)
            client = ApiClient(settings, opener=object())
            client.set_token("persisted")
            client.save_session()
            os.symlink(source, link)

            linked_settings = Settings(
                account="user", password="secret", session_file=link
            )
            with self.assertRaises(SessionError):
                ApiClient(linked_settings, opener=object()).load_session()


if __name__ == "__main__":
    unittest.main()
