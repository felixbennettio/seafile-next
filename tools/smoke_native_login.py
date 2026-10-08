"""Verify native metadata against the throwaway database, never a real account."""
import json
import os
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


def main():
    base = 'http://127.0.0.1:8080' + os.environ.get('SITE_ROOT', '/')
    fields = json.loads(Path('native-login-fields/fields.json').read_text())
    password = os.environ['SMOKE_PASSWORD']
    for platform in ('mac', 'ios'):
        metadata = fields[platform]
        assert metadata['platform'] == platform
        assert len(metadata['device_id']) == (40 if platform == 'mac' else 36)
        assert 0 < len(metadata['device_name']) <= 40
        assert 0 < len(metadata['platform_version']) <= 16
        body = urllib.parse.urlencode(dict(metadata, username='smoke@example.invalid', password=password)).encode()
        request = urllib.request.Request(base + 'api2/auth-token/', data=body)
        with urllib.request.urlopen(request, timeout=30) as response:
            token = json.load(response)['token']
        request = urllib.request.Request(base + 'api2/account/info/', headers={'Authorization': 'Token ' + token})
        with urllib.request.urlopen(request, timeout=30) as response:
            assert json.load(response)['email'] == 'smoke@example.invalid'
        print('Passed native password login and canonical identity:', platform)
    legacy = fields['legacyMacVersion']
    assert len(legacy) > 16, 'The runner must provide the full legacy macOS build description'
    metadata = dict(fields['mac'], platform_version=legacy, device_id='b' * 40)
    body = urllib.parse.urlencode(dict(metadata, username='smoke@example.invalid', password=password)).encode()
    try:
        urllib.request.urlopen(urllib.request.Request(base + 'api2/auth-token/', data=body), timeout=30)
        raise AssertionError('The isolated strict database accepted the legacy overlong version')
    except urllib.error.HTTPError as error:
        assert error.code == 500
        print('Reproduced legacy Mac device-version database failure: HTTP 500; fixed fields pass.')


if __name__ == '__main__':
    main()
