#!/usr/bin/env python3
"""Throwaway OAuth/OIDC provider for the isolated server integration workflow.

This only issues an identity for smoke@example.invalid. It is never a production
authenticator and must not be run against real accounts or exposed to the public.
"""
import json
import os
import secrets
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

codes = set()
lock = threading.Lock()


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if url.path == '/authorize':
            query = urllib.parse.parse_qs(url.query)
            redirect = query.get('redirect_uri', [''])[0]
            target = urllib.parse.urlsplit(redirect)
            assert target.scheme == 'http' and target.hostname == '127.0.0.1' and target.port == 8080
            assert target.path.endswith('/oauth/callback/') and not target.query and not target.fragment
            assert query.get('client_id') == ['isolated-ci-client'] and query.get('state')
            code = secrets.token_hex(20)
            with lock:
                codes.add(code)
            self.send_response(302)
            self.send_header('Location', redirect + '?' + urllib.parse.urlencode({'code': code, 'state': query['state'][0]}))
            self.end_headers()
        elif url.path == '/userinfo':
            assert self.headers.get('Authorization') == 'Bearer isolated-ci-access-token'
            self.json({'sub': 'smoke@example.invalid', 'email': 'smoke@example.invalid', 'name': 'CI test account'})
        else:
            self.json({'error': 'not_found'}, 404)

    def do_POST(self):
        assert self.path == '/token'
        fields = urllib.parse.parse_qs(self.rfile.read(int(self.headers.get('Content-Length', 0))).decode())
        code = fields.get('code', [''])[0]
        with lock:
            assert code in codes
            codes.remove(code)
        self.json({'access_token': 'isolated-ci-access-token', 'token_type': 'Bearer', 'expires_in': 300})


if __name__ == '__main__':
    if os.environ.get('SEAFILE_ISOLATED_TEST_IDP') != '1':
        raise SystemExit('This fixture must only run in the isolated CI test container.')
    ThreadingHTTPServer(('0.0.0.0', 8081), Provider).serve_forever()
