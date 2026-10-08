#!/usr/bin/env python3
"""Exercise Seafile's browser client sign-in in an isolated loopback CI server."""
import http.cookiejar
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser


class FormFields(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.values = {}
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'input' and attrs.get('name') and attrs.get('type') == 'hidden':
            self.values[attrs['name']] = attrs.get('value', '')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    base = 'http://127.0.0.1:8080' + os.environ.get('SITE_ROOT', '/')
    password = os.environ['SMOKE_PASSWORD']
    platform = os.environ.get('SSO_PLATFORM', 'ios')
    flow = os.environ.get('SSO_FLOW', 'password')
    assert flow in ('password', 'direct', 'web')
    direct_sso = flow == 'direct'
    assert platform in ('ios', 'mac')
    browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def call(url, fields=None, api=False, token=None):
        # This script accepts only the throwaway local CI deployment. It must
        # never submit test credentials or sign-in nonces to a remote service.
        assert url.startswith(base)
        headers = {'Referer': url}
        if token:
            headers['Authorization'] = 'Token ' + token
        body = urllib.parse.urlencode(fields).encode() if fields is not None else None
        request = urllib.request.Request(url, data=body, headers=headers)
        opener = urllib.request.build_opener() if api else browser
        with opener.open(request, timeout=30) as response:
            data = response.read()
            return (json.loads(data) if api else data.decode()), response.url

    deadline = time.monotonic() + 300
    while True:
        try:
            info, _ = call(base + 'api2/server-info/', api=True)
            if 'client-sso-via-local-browser' in info['features']:
                break
        except (OSError, KeyError):
            pass
        if time.monotonic() > deadline:
            raise RuntimeError('Isolated browser SSO did not become available')
        time.sleep(3)

    link, _ = call(base + 'api2/client-sso-link/', fields={}, api=True)
    assert link['link'].startswith(base + 'client-sso/')
    nonce = urllib.parse.urlsplit(link['link']).path.rstrip('/').split('/')[-1]
    status_url = base + 'api2/client-sso-link/' + nonce + '/'
    pending, _ = call(status_url, api=True)
    assert pending['status'] == 'waiting'
    parameters = {
        'shib_platform': platform,
        'shib_device_id': '00000000-0000-4000-8000-000000000001' if platform == 'ios' else '0' * 40,
        'shib_device_name': 'CI iPhone + Test & Co' if platform == 'ios' else 'CI Mac + Test & Co',
        'shib_client_version': '1.0.0', 'shib_platform_version': '26.0',
    }
    native = Path('native-login-fields/fields.json')
    if native.is_file():
        contract = json.loads(native.read_text())
        parameters = {'shib_' + key: value for key, value in contract[platform].items()}
        if os.environ.get('SSO_LEGACY_METADATA') == '1':
            assert platform == 'mac' and len(contract['legacyMacVersion']) > 16
            parameters['shib_platform_version'] = contract['legacyMacVersion']
            parameters['shib_device_id'] = 'c' * 40
    if direct_sso:
        # Match the native app: mark the nonce visited without following the
        # redirect or copying web cookies, then enter the server SSO dispatcher
        # in an independent browser session with a fully encoded next value.
        opener = urllib.request.build_opener(NoRedirect())
        try:
            opener.open(link['link'] + '?' + urllib.parse.urlencode(parameters), timeout=30)
            raise AssertionError('Expected a redirect from the single-use visit')
        except urllib.error.HTTPError as error:
            assert error.code == 302
            assert error.headers['Location'].startswith(os.environ.get('SITE_ROOT', '/'))
        completion = urllib.parse.urlsplit(link['link']).path + 'complete/?' + urllib.parse.urlencode(parameters)
        confirmation, confirmation_url = call(base + 'sso/?' + urllib.parse.urlencode({'next': completion}))
    else:
        login_html, login_url = call(link['link'] + '?' + urllib.parse.urlencode(parameters))
        login_fields = FormFields(login_html).values
        assert login_fields.get('csrfmiddlewaretoken') and 'next' in login_fields
        if flow == 'web':
            # Execute the rendered login button's JavaScript, then follow its
            # actual URL through the mock IdP. This catches HTML-escaped or
            # unencoded nested queries even when password/direct SSO pass.
            body = re.search(r"\$\('#sso'\)\.on\('click', function\(\) \{(.*?)\n\s*\}\);", login_html, re.S)
            assert body, 'SSO button handler missing from rendered login page'
            payload = {'body': body.group(1), 'next': login_fields['next'], 'origin': 'http://127.0.0.1:8080'}
            script = """
            const fs = require('node:fs'), vm = require('node:vm');
            const input = JSON.parse(fs.readFileSync(0, 'utf8'));
            const context = {URL, window: {location: {origin: input.origin}},
              document: {location: {hash: ''}, querySelector: () => ({value: input.next})},
              $: () => ({is: () => false})};
            vm.runInNewContext('(function() {' + input.body + '})()', context, {timeout: 1000});
            process.stdout.write(String(context.window.location));
            """
            target = subprocess.run(['node', '-e', script], input=json.dumps(payload), text=True,
                                    check=True, capture_output=True, timeout=5).stdout
            assert target.startswith(base + 'sso/?')
            assert urllib.parse.parse_qs(urllib.parse.urlsplit(target).query)['next'] == [login_fields['next']]
            confirmation, confirmation_url = call(target)
        else:
            login_fields.update({'login': 'smoke@example.invalid', 'password': password})
            confirmation, confirmation_url = call(login_url, fields=login_fields)
    assert '/client-sso/' + nonce + '/complete/' in confirmation_url
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(confirmation_url).query)
    assert all(query.get(key) == [value] for key, value in parameters.items())
    # The API must keep waiting until the user confirms the browser prompt.
    pending, _ = call(status_url, api=True)
    assert pending['status'] == 'waiting'
    fields = FormFields(confirmation).values
    assert fields.get('csrfmiddlewaretoken')
    if os.environ.get('SSO_LEGACY_METADATA') == '1':
        try:
            call(confirmation_url, fields=fields)
            raise AssertionError('The isolated strict database accepted legacy SSO metadata')
        except urllib.error.HTTPError as error:
            assert error.code == 500 and 'Page unavailable' in error.read().decode()
            print('Reproduced legacy native Mac SSO: Page unavailable after client confirmation; normal native SSO passes.')
            return
    call(confirmation_url, fields=fields)
    completed, _ = call(status_url, api=True)
    assert completed['status'] == 'success' and completed['apiToken']
    assert completed['username'] == 'smoke@example.invalid'
    profile, _ = call(base + 'api2/account/info/', api=True, token=completed['apiToken'])
    assert profile['email'] == completed['username']
    repositories, _ = call(base + 'api2/repos/', api=True, token=completed['apiToken'])
    assert isinstance(repositories, list)
    print('Passed:', platform, {'direct': 'direct OIDC', 'web': 'rendered web SSO button + OIDC', 'password': 'password browser SSO'}[flow], 'creation, pending state, confirmation, all device parameters, token identity and library access.')


if __name__ == '__main__':
    main()
