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
• SSO 支持现代服务器的默认浏览器授权，也恢复较旧服务器的兼容登录窗口。
• 新增独立传输列表，支持进度、取消、重试和本地副本保存；切换目录后传输仍继续。
• 支持按名称、大小、类型和修改时间排序。
• 补回旧 iOS 译文和缺失的语言资源，并补充中文备份、编辑及媒体菜单。
• 离开目录或收藏页面后，完成的下载不会突然打开预览。
• 修复 Mac 密码及 SSO 登录的设备信息兼容问题，显示具体的账号、验证码或参数错误；网络中断后不再重复提交已使用的两步验证码。

请使用现有服务器验证登录、传输、连续预览和收藏。iOS 系统后台续传尚未实现。此 App 更新不要求更换 Docker。
""",
    'en-US': """This update:
• Improves connection recovery after network interruptions or TLS handshake failures, with the hostname and error code shown on failure.
• Supports starring folders and browsing their contents from Starred.
• Separates preview from unstar; removing a favorite requires confirmation.
• Uses default-browser SSO for modern servers and restores a compatible sign-in window for older servers.
• Adds a separate transfer list with progress, cancellation, retry and saving local copies. Transfers continue when changing folders.
• Supports sorting by name, size, type and modification time.
• Restores original iOS translations and missing language resources, with additional Chinese backup, editing and media controls.
• A completed download no longer opens a late preview after leaving its folder or Starred.
• Fixes Mac device metadata compatibility for password and SSO sign-in, shows specific login errors, and avoids replaying a used verification code after a network interruption.

Please test sign-in, transfers, repeated previews and favorites against your existing server. iOS system background transfers are not yet implemented. This app update does not require replacing Docker.
""",
}


def update_build_notes(build_id, platform):
    existing = api('builds/' + build_id + '/betaBuildLocalizations', query={'limit': '200'})['data']
    for locale, notes in NOTES.items():
        if platform == 'IOS':
            notes += {
                'zh-Hans': '\niPhone 新增：\n• 批量复制、移动、删除与下载，保留已完成项目和最近目标目录。\n• 资料库管理与新建文件、共享权限、密码及到期分享链接、服务器搜索、活动和应用锁。\n• 原生文本/Markdown 编辑与回传，保留中断和冲突草稿，支持恢复、导出和另存副本。\n• 前台相册备份，支持视频、Live Photo 成对资源、相册选择及 Wi-Fi 限制，可选择将 HEIC/HEIF 静态照片转为 JPEG；完成记录避免重复上传。\n• 相邻图片切换和缩放、照片信息、原生视频播放、原文件分享与保存到照片。\n',
                'en-US': '\niPhone additions:\n• Batch copy, move, delete and download, preserving completed items and recent destinations.\n• Library management and new-file creation, sharing permissions, protected and expiring links, server search, activity and app lock.\n• Native text/Markdown editing with uploads, recoverable drafts, export and save-as-copy after interruptions or conflicts.\n• Foreground photo backup with videos, paired Live Photo resources, album selection and Wi-Fi restrictions, with optional HEIC/HEIF still-photo conversion to JPEG; durable records prevent duplicate uploads.\n• Adjacent-image navigation and zoom, photo information, native video playback, original-file sharing and saving to Photos.\n',
            }[locale]
        if platform == 'MAC_OS':
            notes += {
                'zh-Hans': '\nMac 新增与修复：\n• 服务器和账号输入框可正常编辑，内容左对齐，边界清晰。\n• 恢复 Dock 图标隐藏、开机启动状态、代理、语言与账号设置，升级时保留已保存的设置。\n• 补齐资料库与文件创建、批量复制移动、共享权限、全局搜索和活动。\n• 支持默认应用编辑后回传、同步错误与大量删除确认；未上传编辑会保留。\n• Finder 文件集成继续使用现有账号；非沙盒版本另提供同步徽标与右键操作。\n',
                'en-US': '\nMac additions and fixes:\n• Editable, left-aligned server and account fields with visible borders.\n• Dock visibility, launch-at-login status, proxies, language and account settings, preserving saved preferences across upgrades.\n• Library and file creation, batch copy/move, sharing permissions, server search and activity.\n• Default-app editing with upload, sync errors and bulk-deletion confirmation; pending edits are preserved.\n• Finder integration uses existing accounts; the direct edition also includes sync badges and context actions.\n',
            }[locale]
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
    print('Automatic internal TestFlight group ready. Testers:', len(testers), flush=True)
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
