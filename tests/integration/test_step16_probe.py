#!/usr/bin/env python3
"""Unit checks for the Step 16 probe helper (no Nim server required)."""
import unittest
from unittest.mock import patch

import step16_probe as probe


class ExpectResponseTests(unittest.TestCase):
    def test_request_body_is_sent_and_expected_body_is_compared(self):
        form_data = b"v=%2525"
        headers = {"Content-Type": "application/x-www-form-urlencoded"}
        with patch.object(probe, "http_request", return_value=(200, [], b"%25")) as call:
            probe.expect_response(
                "POST", "/form", 200, b"%25",
                request_body=form_data, headers=headers,
            )
        call.assert_called_once_with(
            "POST", "/form", headers=headers,
            body=form_data, connection=None,
        )

    def test_multipart_truncation_is_sent_not_compared_as_response(self):
        boundary = b"step16-example-boundary"
        incomplete = probe.multipart_payload(boundary, b"incomplete", final=False)
        self.assertTrue(incomplete.startswith(b"--" + boundary + b"\r\n"))
        self.assertFalse(incomplete.endswith(b"--" + boundary + b"--\r\n"))
        with patch.object(probe, "http_request", return_value=(400, [], b"error")) as call:
            probe.expect_response(
                "POST", "/upload", 400,
                request_body=incomplete,
                headers={"Content-Type": "multipart/form-data; boundary=" + boundary.decode()},
            )
        self.assertEqual(call.call_args.kwargs["body"], incomplete)

    def test_mismatched_expected_body_fails(self):
        with patch.object(probe, "http_request", return_value=(200, [], b"actual")):
            with self.assertRaises(AssertionError):
                probe.expect_response("GET", "/ping", 200, b"expected")

    def test_ambiguous_body_keyword_is_not_accepted(self):
        with self.assertRaises(TypeError):
            probe.expect_response("POST", "/form", 200, body=b"v=1")


if __name__ == "__main__":
    unittest.main()
