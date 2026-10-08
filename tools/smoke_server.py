#!/usr/bin/env python3
"""Exercise login and binary file operations against an isolated CI server."""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


def main():
    base = 'http://127.0.0.1:8080' + os.environ.get('SITE_ROOT', '/')
    password = os.environ['SMOKE_PASSWORD']
    token = None

    def request(path, method='GET', fields=None, body=None, content_type=None, raw=False):
        if fields is not None:
            body = urllib.parse.urlencode(fields).encode()
            content_type = 'application/x-www-form-urlencoded'
        headers = {'Accept': 'application/json'}
        if token:
            headers['Authorization'] = 'Token ' + token
        if content_type:
            headers['Content-Type'] = content_type
        url = path if path.startswith('http://127.0.0.1:8080/') else base + path
        with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers, method=method), timeout=30) as response:
            data = response.read()
            return json.loads(data) if data and not raw and 'application/json' in response.headers.get('Content-Type', '') else data

    deadline = time.monotonic() + 480
    while True:
        try:
            assert request('api2/ping/') in ('pong', b'pong', b'"pong"')
            break
        except (OSError, AssertionError):
            if time.monotonic() >= deadline:
                raise RuntimeError('The isolated server did not become ready within eight minutes') from None
            time.sleep(5)
    token = request('api2/auth-token/', 'POST', {'username': 'smoke@example.invalid', 'password': password})['token']
    assert request('api2/account/info/')['email'] == 'smoke@example.invalid'
    repo = request('api2/repos/', 'POST', {'name': 'CI ' + str(uuid.uuid4()), 'desc': 'Temporary smoke test'})['repo_id']
    try:
        assert any(item['id'] == repo for item in request('api2/repos/'))
        directory = '/Unicode 空间/'
        request('api2/repos/' + repo + '/dir/?' + urllib.parse.urlencode({'p': directory}), 'POST', {'operation': 'mkdir'})
        link = request('api2/repos/' + repo + '/upload-link/?' + urllib.parse.urlencode({'p': directory}))
        # Never send the test token to an unexpected host advertised by a server.
        assert link.startswith('http://127.0.0.1:8080/' + os.environ.get('SITE_ROOT', '/').lstrip('/'))
        payload = bytes(range(256)) * 512
        boundary = 'seafile-next-' + str(uuid.uuid4())
        prefix = f'--{boundary}\r\nContent-Disposition: form-data; name="parent_dir"\r\n\r\n{directory}\r\n--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="binary test.bin"\r\nContent-Type: application/octet-stream\r\n\r\n'.encode()
        request(link, 'POST', body=prefix + payload + f'\r\n--{boundary}--\r\n'.encode(), content_type='multipart/form-data; boundary=' + boundary, raw=True)
        path = directory + 'binary test.bin'
        for favorite in [directory, path]:
            request('api/v2.1/starred-items/', 'POST', {'repo_id': repo, 'path': favorite})
        favorites = request('api/v2.1/starred-items/')['starred_item_list']
        assert any(item['repo_id'] == repo and item['path'] == directory and item['is_dir'] for item in favorites)
        assert any(item['repo_id'] == repo and item['path'] == path and not item['is_dir'] for item in favorites)
        entries = request('api2/repos/' + repo + '/dir/?' + urllib.parse.urlencode({'p': directory}))
        assert any(item['name'] == 'binary test.bin' and item['size'] == len(payload) for item in entries)
        native_entries = request('api/v2.1/repos/' + repo + '/dir/?' + urllib.parse.urlencode({'p': directory}))['dirent_list']
        assert any(item['name'] == 'binary test.bin' and item['type'] == 'file' and item['size'] == len(payload) for item in native_entries)
        download = request('api2/repos/' + repo + '/file/?' + urllib.parse.urlencode({'p': path}))
        assert download.startswith('http://127.0.0.1:8080/')
        assert request(download, raw=True) == payload
        # Opening a favorite is read-only and must leave both records intact.
        assert request('api/v2.1/starred-items/')['starred_item_list'] == favorites
        request('api/v2.1/starred-items/?' + urllib.parse.urlencode({'repo_id': repo, 'path': path}), 'DELETE')
        remaining = request('api/v2.1/starred-items/')['starred_item_list']
        assert any(item['repo_id'] == repo and item['path'] == directory for item in remaining)
        assert not any(item['repo_id'] == repo and item['path'] == path for item in remaining)
        request('api/v2.1/starred-items/?' + urllib.parse.urlencode({'repo_id': repo, 'path': directory}), 'DELETE')
        request('api2/repos/' + repo + '/file/?' + urllib.parse.urlencode({'p': path}), 'POST', {'operation': 'rename', 'newname': 'renamed.bin'})
        request('api2/repos/' + repo + '/file/?' + urllib.parse.urlencode({'p': directory + 'renamed.bin'}), 'DELETE')
        print('Passed: deployment path, login, account identity, libraries, folders, Unicode, binary transfer, folder/file favorites, preview preserving favorites, rename and delete.')
    finally:
        request('api2/repos/' + repo + '/', 'DELETE')


if __name__ == '__main__':
    main()
