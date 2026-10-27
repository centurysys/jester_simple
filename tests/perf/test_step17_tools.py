#!/usr/bin/env python3
"""Unit tests for the Step 17 measurement/reporting tools."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile
import threading
import unittest

import step17_probe as p
import compare_step17 as c


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/bench/plain":
            body = b"OK"
        elif self.path == "/bench/json":
            body = b'{"status":"ok","count":42}'
        elif self.path == "/bench/query?q=test&field=5":
            body = b"q=test&field=5"
        elif self.path == "/small.txt":
            body = p.SMALL
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class Step17Tests(unittest.TestCase):
    def test_percentiles(self):
        self.assertEqual(p.percentile([1, 2, 3, 4, 5], 50), 3)
        self.assertEqual(p.percentile([1, 2, 3, 4, 5], 99), 4.96)

    def test_empty_percentile(self):
        with self.assertRaises(ValueError):
            p.percentile([], 50)

    def test_compare(self):
        base = {
            "label": "legacy", "git_head": "old", "arch": "x86_64",
            "measurement": "python_http_client_persistent_serial",
            "binary_bytes": 1000, "settings": {"repeats": 1},
            "checkpoints": {"ready": {"hwm_kib": 10}},
            "cases": [{"route": "plain", "rps": 100, "p50_ms": 1, "p99_ms": 2}],
        }
        modified = json.loads(json.dumps(base))
        modified["label"] = "current"
        modified["binary_bytes"] = 1200
        modified["cases"][0]["rps"] = 95
        report = c.generate(base, modified)
        self.assertIn("-5.0%", report)
        self.assertIn("1200 bytes", report)
        modified["arch"] = "armv7l"
        with self.assertRaises(ValueError):
            c.generate(base, modified)

    def test_http_helpers(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
        server.daemon_threads = True
        task = threading.Thread(target=server.serve_forever, daemon=True)
        task.start()
        try:
            import http.client
            conn = http.client.HTTPConnection("127.0.0.1", server.server_port,
                                              timeout=2)
            try:
                for name, method, path, expected, kind in p.ROUTES[:5]:
                    self.assertGreaterEqual(p.exchange(conn, method, path, expected), 0)
            finally:
                conn.close()
        finally:
            server.shutdown()
            server.server_close()
            task.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
