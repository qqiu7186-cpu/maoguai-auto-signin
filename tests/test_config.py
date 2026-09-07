import unittest

from maoguai.config import DEFAULT_BASE_URL, Settings
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


if __name__ == "__main__":
    unittest.main()
