"""Exercise the real OTP serializer only inside the throwaway CI container."""
import json
import os
from pathlib import Path
import secrets
import time

assert os.environ.get('SEAFILE_ISOLATED_LOGIN_TEST') == '1'
assert os.environ['SEAFILE_SERVER_HOSTNAME'] == '127.0.0.1:8080'
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'seahub.settings')

import django
django.setup()

from constance import config
from django.db import DataError
from rest_framework.test import APIRequestFactory
from seahub.api2.views import ObtainAuthToken
from seahub.two_factor.models import TOTPDevice
from seahub.two_factor.oath import TOTP

metadata = json.loads(Path('/tmp/native-login-fields.json').read_text())
user = 'smoke@example.invalid'
assert not TOTPDevice.objects.filter(user=user).exists()
previous = config.ENABLE_TWO_FACTOR_AUTH
factory = APIRequestFactory()
view = ObtainAuthToken.as_view()
try:
    config.ENABLE_TWO_FACTOR_AUTH = True
    device = TOTPDevice.objects.create(user=user, name='Isolated CI OTP', confirmed=True, key=secrets.token_hex(20))
    totp = TOTP(device.bin_key)
    totp.time = time.time()
    current = str(totp.token()).zfill(6)
    print('::add-mask::' + current, flush=True)
    fields = dict(metadata['mac'], username=user, password=os.environ['SMOKE_PASSWORD'])
    path = os.environ.get('SITE_ROOT', '/') + 'api2/auth-token/'

    def login(values, code=None):
        headers = {'HTTP_X_SEAFILE_OTP': code} if code else {}
        return view(factory.post(path, values, format='multipart', **headers))

    missing = login(fields)
    assert missing.status_code == 400 and missing['X-Seafile-OTP'] == 'required'
    assert 'missing' in missing.data['non_field_errors'][0]
    try:
        login(dict(fields, platform_version=metadata['legacyMacVersion'], device_id='d' * 40), current)
        raise AssertionError('The legacy version unexpectedly passed the strict database')
    except DataError:
        pass
    consumed = login(fields, current)
    assert consumed.status_code == 400 and consumed['X-Seafile-OTP'] == 'required'
    assert 'invalid' in consumed.data['non_field_errors'][0]
    totp.time += 30
    fresh = str(totp.token()).zfill(6)
    print('::add-mask::' + fresh, flush=True)
    assert fresh != current
    fixed = login(fields, fresh)
    assert fixed.status_code == 200 and fixed.data['token']
    print('Passed real OTP sign-in: legacy version fails after consuming the code, retry returns 400, fixed metadata plus a fresh code succeeds.')
finally:
    TOTPDevice.objects.filter(user=user).delete()
    config.ENABLE_TWO_FACTOR_AUTH = previous
