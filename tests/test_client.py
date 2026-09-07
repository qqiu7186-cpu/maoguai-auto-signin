import hashlib
import io
import json
import os
import tempfile
import unittest
import urllib.error
import urllib.request

from maoguai.client import ApiClient
from maoguai.config import Settings
from maoguai.errors import RequestError


class FakeResponse:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        return False

    def read(self):
        return self.body


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
        self.assertEqual(client.request("/sign/signed"), {"code": 0})
        self.assertEqual(opener.attempts, 2)

        opener = FlakyOpener()
        client = ApiClient(self.client.settings, opener=opener)
        with self.assertRaises(RequestError):
            client.request("/sign", method="POST")
        self.assertEqual(opener.attempts, 1)

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


if __name__ == "__main__":
    unittest.main()
