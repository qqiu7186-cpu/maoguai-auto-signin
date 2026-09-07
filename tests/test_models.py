import unittest

from maoguai.errors import ResponseFormatError
from maoguai.models import ApiResponse, SignStatus, extract_token


class ModelsTest(unittest.TestCase):
    def test_extracts_top_level_and_nested_tokens(self):
        self.assertEqual(extract_token({"token": "top"}), "top")
        self.assertEqual(extract_token({"data": {"token": "nested"}}), "nested")
        self.assertIsNone(extract_token({"data": {}}))

    def test_requires_code(self):
        with self.assertRaises(ResponseFormatError):
            ApiResponse.from_payload({"msg": "ok"})

    def test_requires_boolean_signed_value(self):
        response = ApiResponse.from_payload({"code": 0, "signed": "false"})
        with self.assertRaises(ResponseFormatError):
            SignStatus.from_response(response)


if __name__ == "__main__":
    unittest.main()
