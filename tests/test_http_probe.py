# SPDX-License-Identifier: MIT
"""Exercise the actual installer probe with synthetic HTTP responses."""
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = (ROOT / 'src/install.template.sh').read_text()
PROBE = TEMPLATE.split('  /usr/bin/python3 -I - "$WEB" <<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]


class HttpProbeTests(unittest.TestCase):
    def run_probe(self, public_status=500, public_body=b'file not found', api_status=401):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('pve-sensors.css', 'pve-sensors.js'):
                (root / name).write_bytes(b'asset')

            def open_url(url, timeout):
                if '/api2/' in url:
                    status, body = api_status, b'no ticket'
                elif 'pve-sensors.json' in url or 'pve-sensors.html' in url:
                    if isinstance(public_status, Exception):
                        raise public_status
                    status, body = public_status, public_body
                else:
                    response = io.BytesIO(b'asset')
                    response.geturl = lambda: url
                    return response
                if status >= 400 or 300 <= status < 400:
                    raise HTTPError(url, status, 'synthetic response', {}, io.BytesIO(body))
                return io.BytesIO(body)

            with patch('sys.argv', ['probe', directory]), \
                 patch('urllib.request.build_opener') as builder, \
                 patch('sys.stdout', new_callable=io.StringIO):
                builder.return_value.open.side_effect = open_url
                exec(compile(PROBE, 'installer-http-probe', 'exec'), {})

    def test_missing_static_file_500_is_accepted(self):
        self.run_probe(public_status=500)

    def test_missing_static_file_404_is_accepted(self):
        self.run_probe(public_status=404)

    def test_successful_public_response_is_rejected(self):
        for body in (b'{}', b'{"metrics":[{"value":42}]}'):
            with self.subTest(body=body), self.assertRaises(SystemExit):
                self.run_probe(public_status=200, public_body=body)

    def test_error_response_containing_metrics_is_rejected(self):
        for status in (404, 500):
            for payload in ({'metrics': []}, {'data': {'metrics': [{'value': 42}]}}):
                with self.subTest(status=status, payload=payload), self.assertRaises(SystemExit):
                    self.run_probe(public_status=status, public_body=json.dumps(payload).encode())

    def test_unexpected_static_status_is_rejected(self):
        for status in (302, 403, 503):
            with self.subTest(status=status), self.assertRaises(SystemExit):
                self.run_probe(public_status=status)

    def test_api_still_requires_401(self):
        for status in (200, 403, 404, 500):
            with self.subTest(status=status), self.assertRaises(SystemExit):
                self.run_probe(public_status=404, api_status=status)

    def test_network_failure_is_not_treated_as_missing_file(self):
        with self.assertRaises(URLError):
            self.run_probe(public_status=URLError('connection refused'))

    def test_public_file_and_dangling_symlink_are_rejected_even_when_http_is_skipped(self):
        guard = TEMPLATE.split('# The public paths must stay absent even when HTTPS checks are skipped.\n', 1)[1].split('\n\n', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = 'WEB="$1"\ndie() { exit 1; }\n' + guard
            def check(expected):
                result = subprocess.run(['bash', '-c', script, 'probe', directory], capture_output=True)
                self.assertEqual(result.returncode, expected)
            check(0)
            for name in ('pve-sensors.json', 'pve-sensors.html'):
                public = root / name
                public.write_text('{}')
                check(1)
                public.unlink()
                public.symlink_to(root / 'absent-file')
                check(1)
                public.unlink()
