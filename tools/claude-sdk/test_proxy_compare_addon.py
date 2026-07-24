#!/usr/bin/env python3
"""Offline regression tests for the sanitized Claude SDK proxy manifest."""
import importlib.util
import sys
import types
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("proxy-compare-addon.py")


def load_addon():
    # The sanitizer must stay unit-testable without installing mitmproxy locally.
    mitmproxy = types.ModuleType("mitmproxy")
    mitmproxy.ctx = types.SimpleNamespace(log=types.SimpleNamespace(info=lambda _message: None))
    mitmproxy.http = types.SimpleNamespace(HTTPFlow=object)
    original = sys.modules.get("mitmproxy")
    sys.modules["mitmproxy"] = mitmproxy
    try:
        spec = importlib.util.spec_from_file_location("proxy_compare_addon", MODULE_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        if original is None:
            del sys.modules["mitmproxy"]
        else:
            sys.modules["mitmproxy"] = original


ADDON = load_addon()


class ProxyCompareAddonTests(unittest.TestCase):
    def test_sanitized_payload_retains_protocol_values_but_redacts_content_and_secrets(self):
        payload = {
            "model": "claude-sonnet-5",
            "max_tokens": 8192,
            "system": [{"type": "text", "text": "private system prompt"}],
            "messages": [{"role": "user", "content": [{"type": "text", "text": "private prompt"}]}],
            "tools": [{"name": "run_shell", "description": "Run a command", "input_schema": {"type": "object"}}],
            "metadata": {"user_id": "visible-for-comparison", "api_key": "must-not-leak"},
            "thinking": {"type": "adaptive"},
        }

        actual = ADDON.sanitize_payload(payload)

        self.assertEqual("claude-sonnet-5", actual["model"])
        self.assertEqual(8192, actual["max_tokens"])
        self.assertEqual("run_shell", actual["tools"][0]["name"])
        self.assertEqual("Run a command", actual["tools"][0]["description"])
        self.assertEqual("adaptive", actual["thinking"]["type"])
        self.assertEqual("<redacted:21-chars>", actual["system"][0]["text"])
        self.assertEqual("<redacted:14-chars>", actual["messages"][0]["content"][0]["text"])
        self.assertEqual("<redacted>", actual["metadata"]["api_key"])
        self.assertNotIn("private system prompt", repr(actual))
        self.assertNotIn("private prompt", repr(actual))
        self.assertNotIn("must-not-leak", repr(actual))

    def test_headers_redact_authorization_cookie_and_api_key_but_keep_other_values(self):
        headers, redacted = ADDON.sanitize_headers({
            "Authorization": "Bearer secret",
            "Cookie": "session=secret",
            "X-Api-Key": "secret",
            "User-Agent": "claude-cli/2.1.218",
            "Anthropic-Beta": "effort-2025-11-24",
        })

        self.assertEqual({
            "user-agent": "claude-cli/2.1.218",
            "anthropic-beta": "effort-2025-11-24",
        }, headers)
        self.assertEqual(["authorization", "cookie", "x-api-key"], redacted)


if __name__ == "__main__":
    unittest.main()
