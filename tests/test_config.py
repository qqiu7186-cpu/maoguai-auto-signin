import unittest

from maoguai.config import DEFAULT_BASE_URL, DEFAULT_SESSION_FILE, Settings
from maoguai.errors import ConfigurationError


class SettingsTest(unittest.TestCase):
    def test_loads_credentials_and_optional_values(self):
        settings = Settings.from_env(
            {
                "MAOGUAI_ACCOUNT": " user ",
                "MAOGUAI_PASSWORD": "secret",
                "MAOGUAI_TIMEOUT": "12.5",
                "MAOGUAI_RETRIES": "4",
            }
        )
        self.assertEqual(settings.account, "user")
        self.assertEqual(settings.password, "secret")
        self.assertEqual(settings.base_url, DEFAULT_BASE_URL)
        self.assertEqual(settings.timeout, 12.5)
        self.assertEqual(settings.retries, 4)
        self.assertEqual(settings.session_file, DEFAULT_SESSION_FILE)

    def test_loads_session_file(self):
        settings = Settings.from_env(
            {
                "MAOGUAI_ACCOUNT": "u",
                "MAOGUAI_PASSWORD": "p",
                "MAOGUAI_SESSION_FILE": " /tmp/session.cookies ",
            }
        )
        self.assertEqual(settings.session_file, "/tmp/session.cookies")

    def test_missing_credentials_are_rejected(self):
        with self.assertRaisesRegex(ConfigurationError, "MAOGUAI_ACCOUNT"):
            Settings.from_env({})

    def test_invalid_retry_value_is_rejected(self):
        with self.assertRaisesRegex(ConfigurationError, "MAOGUAI_RETRIES"):
            Settings.from_env(
                {
                    "MAOGUAI_ACCOUNT": "u",
                    "MAOGUAI_PASSWORD": "p",
                    "MAOGUAI_RETRIES": "x",
                }
            )

    def test_non_finite_timeout_is_rejected(self):
        for value in ("nan", "inf"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(ConfigurationError, "MAOGUAI_TIMEOUT"):
                    Settings.from_env(
                        {
                            "MAOGUAI_ACCOUNT": "u",
                            "MAOGUAI_PASSWORD": "p",
                            "MAOGUAI_TIMEOUT": value,
                        }
                    )

    def test_retry_count_has_a_safe_upper_bound(self):
        with self.assertRaisesRegex(ConfigurationError, "MAOGUAI_RETRIES"):
            Settings.from_env(
                {
                    "MAOGUAI_ACCOUNT": "u",
                    "MAOGUAI_PASSWORD": "p",
                    "MAOGUAI_RETRIES": "6",
                }
            )

    def test_custom_base_url_requires_explicit_opt_in(self):
        env = {
            "MAOGUAI_ACCOUNT": "u",
            "MAOGUAI_PASSWORD": "p",
            "MAOGUAI_BASE_URL": "https://example.test",
        }
        with self.assertRaisesRegex(ConfigurationError, "MAOGUAI_BASE_URL"):
            Settings.from_env(env)

        env["MAOGUAI_ALLOW_CUSTOM_BASE_URL"] = "true"
        self.assertEqual(Settings.from_env(env).base_url, "https://example.test")

    def test_insecure_base_url_is_rejected_even_with_opt_in(self):
        with self.assertRaisesRegex(ConfigurationError, "HTTPS"):
            Settings.from_env(
                {
                    "MAOGUAI_ACCOUNT": "u",
                    "MAOGUAI_PASSWORD": "p",
                    "MAOGUAI_BASE_URL": "http://example.test",
                    "MAOGUAI_ALLOW_CUSTOM_BASE_URL": "true",
                }
            )

    def test_malformed_base_url_is_reported_as_configuration_error(self):
        with self.assertRaisesRegex(ConfigurationError, "MAOGUAI_BASE_URL"):
            Settings.from_env(
                {
                    "MAOGUAI_ACCOUNT": "u",
                    "MAOGUAI_PASSWORD": "p",
                    "MAOGUAI_BASE_URL": "https://[",
                }
            )

    def test_null_device_is_rejected_as_session_file(self):
        with self.assertRaisesRegex(ConfigurationError, "空设备"):
            Settings.from_env(
                {
                    "MAOGUAI_ACCOUNT": "u",
                    "MAOGUAI_PASSWORD": "p",
                    "MAOGUAI_SESSION_FILE": "/dev/null",
                }
            )


if __name__ == "__main__":
    unittest.main()
