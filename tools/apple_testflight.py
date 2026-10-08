#!/usr/bin/env python3
"""Wait for the requested universal app platforms to be usable in TestFlight."""
import argparse
import os
import time
from apple_signing import api, BUNDLE

NOTES = {
    'zh-Hans': """本次更新：
• 改善网络中断或 TLS 握手失败后的连接恢复，并显示主机和错误码。
• 支持收藏文件夹，并从收藏列表浏览其内容。
• 文件预览与取消收藏分开操作，取消收藏需要确认。
• SSO 直接进入系统默认浏览器授权。确认客户端登录后，返回 seafile-next 即可继续。

请使用现有服务器验证登录、连续预览和收藏。此 App 更新不要求更换 Docker。
""",
    'en-US': """This update:
• Improves connection recovery after network interruptions or TLS handshake failures, with the hostname and error code shown on failure.
• Supports starring folders and browsing their contents from Starred.
• Separates preview from unstar; removing a favorite requires confirmation.
• Opens SSO directly in your default browser. Confirm client sign-in, then return to seafile-next to continue.

Please test sign-in, repeated previews and favorites against your existing server. This app update does not require replacing Docker.
""",
}


def update_build_notes(build_id, platform):
    existing = api('builds/' + build_id + '/betaBuildLocalizations', query={'limit': '200'})['data']
    for locale, notes in NOTES.items():
        current = next((item for item in existing if item['attributes'].get('locale') == locale), None)
        if current:
            result = api('betaBuildLocalizations/' + current['id'], 'PATCH', {'data': {
                'type': 'betaBuildLocalizations', 'id': current['id'], 'attributes': {'whatsNew': notes},
            }})['data']
        else:
            result = api('betaBuildLocalizations', 'POST', {'data': {
                'type': 'betaBuildLocalizations', 'attributes': {'locale': locale, 'whatsNew': notes},
                'relationships': {'build': {'data': {'type': 'builds', 'id': build_id}}},
            }})['data']
        saved = api('betaBuildLocalizations/' + result['id'])['data']['attributes']
        if saved.get('whatsNew') != notes:
            raise RuntimeError('TestFlight notes did not match after saving: ' + platform + ' ' + locale)
    print('Verified TestFlight notes:', platform, 'Chinese and English', flush=True)


def internal_group(app_id):
    groups = api('apps/' + app_id + '/betaGroups', query={'limit': '200'})['data']
    automatic = [group for group in groups if group['attributes'].get('isInternalGroup') and group['attributes'].get('hasAccessToAllBuilds')]
    if automatic:
        group = automatic[0]
    else:
        group = api('betaGroups', 'POST', {'data': {
            'type': 'betaGroups', 'attributes': {
                'name': 'Seafile Next Internal', 'isInternalGroup': True,
                'hasAccessToAllBuilds': True, 'publicLinkEnabled': False,
            }, 'relationships': {'app': {'data': {'type': 'apps', 'id': app_id}}},
        }})['data']
    testers = api('betaGroups/' + group['id'] + '/betaTesters', query={'limit': '200'})['data']
    print('Automatic internal TestFlight group:', group['attributes']['name'], 'testers:', len(testers), flush=True)
    if not testers:
        print('::notice::Add your Apple ID to this internal group once in App Store Connect. Future builds are distributed automatically.', flush=True)
    return group


def add_internal_tester(app_id, email):
    # Only the owner's explicitly supplied Apple ID is enrolled. Never invite
    # another team member or create a new App Store Connect user.
    users = api('users', query={'filter[username]': email, 'limit': '200'})['data']
    if len(users) != 1:
        raise RuntimeError('The supplied Apple ID is not an existing App Store Connect team user; internal testing requires team membership')
    group = internal_group(app_id)
    existing = api('betaTesters', query={'filter[email]': email, 'limit': '200'})['data']
    if existing:
        tester = existing[0]
        api('betaGroups/' + group['id'] + '/relationships/betaTesters', 'POST', {'data': [{'type': 'betaTesters', 'id': tester['id']}]})
    else:
        attributes = {'email': email}
        for key in ('firstName', 'lastName'):
            if users[0]['attributes'].get(key):
                attributes[key] = users[0]['attributes'][key]
        tester = api('betaTesters', 'POST', {'data': {'type': 'betaTesters', 'attributes': attributes, 'relationships': {'betaGroups': {'data': [{'type': 'betaGroups', 'id': group['id']}]}}}})['data']
    print('Configured the requested owner as an internal tester. State:', tester['attributes'].get('state'), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--build', required=True)
    parser.add_argument('--timeout', type=int, default=2400)
    parser.add_argument('--platform', choices=['IOS', 'MAC_OS', 'BOTH'], default='BOTH')
    args = parser.parse_args()
    required = ['IOS', 'MAC_OS'] if args.platform == 'BOTH' else [args.platform]
    apps = api('apps', query={'filter[bundleId]': BUNDLE})['data']
    if len(apps) != 1:
        raise RuntimeError('Cannot uniquely find the existing App record')
    app_id = apps[0]['id']
    deadline = time.monotonic() + args.timeout
    last = None
    while time.monotonic() < deadline:
        records = api('builds', query={'filter[app]': app_id, 'filter[version]': args.build, 'include': 'preReleaseVersion', 'limit': '200'})
        versions = {item['id']: item['attributes']['platform'] for item in records.get('included', []) if item['type'] == 'preReleaseVersions'}
        builds = records['data']
        status = {versions[item['relationships']['preReleaseVersion']['data']['id']]: item['attributes']['processingState'] for item in builds}
        if status != last:
            print('TestFlight processing:', status, flush=True)
            last = status
        if any(status.get(platform) in ('FAILED', 'INVALID') for platform in required):
            raise RuntimeError('Apple rejected a build during processing; inspect App Store Connect build diagnostics')
        if all(status.get(platform) == 'VALID' for platform in required):
            internal_group(app_id)
            for build in builds:
                platform = versions[build['relationships']['preReleaseVersion']['data']['id']]
                if platform in required:
                    update_build_notes(build['id'], platform)
            print(f'{", ".join(required)} build {args.build} is VALID in TestFlight.', flush=True)
            return
        time.sleep(30)
    raise RuntimeError('Timed out waiting for ' + ', '.join(required) + ' TestFlight builds to become VALID')


if __name__ == '__main__':
    main()
