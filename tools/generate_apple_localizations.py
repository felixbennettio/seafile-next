#!/usr/bin/env python3
"""Reuse the original desktop translations for native Apple controls."""
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'apple/Sources/SeafileApp'
KEYS = set()
for source in SOURCES.glob('*.swift'):
    for value in re.findall(r'(?:Text|Button|Label|Toggle|Section|Picker|PreferenceInput|LoginInput|ContentUnavailableView|navigationTitle|confirmationDialog|alert)\("([^"\n]+)"', source.read_text()):
        if '\\(' not in value:
            KEYS.add(value)
ALIASES = {
    'New library': 'Create a new library', 'New folder': 'New Folder',
    'My libraries': 'My Libraries', 'Group libraries': 'Group Libraries',
    'Shared with me': 'Shared Libraries', 'Sync library': 'Sync this library',
    'Hide seafile-next icon from the Dock': 'Hide Seafile icon from the Dock',
    'Hide main window when started': 'Hide main window when started',
    'Show sync notifications': 'Show sync notifications',
    'Start seafile-next at login': 'Start Seafile at system startup',
    'Computer name': 'Computer Name:', 'Language': 'Language:',
    'System proxy': 'Use system proxy settings', 'None': 'No proxy',
    'HTTP proxy': 'HTTP Proxy', 'SOCKS5 proxy': 'SOCKS5 Proxy',
    'Lock file': 'Lock', 'Unlock file': 'Unlock', 'Preview': 'Open',
    'Copy to…': 'Copy', 'Move to…': 'Move', 'Open on server': 'View on cloud',
    'Stop syncing': 'Unsync', 'Resync this library': 'Resync this library',
    'Settings': 'Settings', 'Sync status': 'Sync Status',
    'File sync errors': 'File Sync Errors', 'Load more': 'Load more',
}
ZH = {
    'Your server':'服务器', 'Server address':'服务器地址', 'Enter your server address':'输入服务器地址',
    'Add account':'添加账号','Accounts':'账号','Account':'账号','Account settings':'账号设置',
    'Account name':'账号名称','Email or username':'邮箱或用户名','Enter your email or username':'输入邮箱或用户名',
    'Password':'密码','Enter your password':'输入密码','Two-factor code (optional)':'两步验证码（可选）',
    'Enter a code if required':'如需要，请输入验证码','Sign in':'登录','Sign in with SSO':'使用 SSO 登录',
    'Cancel':'取消','Save':'保存','Create':'创建','Done':'完成','OK':'好',
    'Settings':'设置','Save settings':'保存设置','General':'通用','Sync':'同步','Connection':'连接',
    'Language':'语言','System language':'系统语言','Computer name':'电脑名称',
    'Start seafile-next at login':'登录系统时启动 seafile-next','Approve in Login Items':'在登录项中允许启动',
    'Hide seafile-next icon from the Dock':'隐藏 Dock 中的 seafile-next 图标','Hide main window when started':'启动时隐藏主窗口',
    'Show sync notifications':'显示同步通知','Enable syncing with an existing folder':'允许与已有文件夹合并同步',
    'Keep syncing when a local folder is temporarily unavailable':'本地文件夹暂时不可用时保留同步',
    'Keep a library when it is not found on the server':'服务器找不到资料库时保留本地资料库',
    'Sync temporary files':'同步临时文件','Ignore symbolic links':'忽略符号链接',
    'Hide Windows incompatible path notifications':'隐藏不兼容 Windows 的路径通知',
    'Confirm deletions above this number of files':'删除文件数超过此值时确认',
    'Download limit (KiB/s, 0 = unlimited)':'下载限速（KiB/s，0 为不限速）',
    'Upload limit (KiB/s, 0 = unlimited)':'上传限速（KiB/s，0 为不限速）',
    'Download limit':'下载限速','Upload limit':'上传限速','Proxy':'代理',
    'System proxy':'系统代理','None':'不使用代理','HTTP proxy':'HTTP 代理','SOCKS5 proxy':'SOCKS5 代理',
    'Host':'主机','Port':'端口','Proxy host':'代理主机','Proxy port':'代理端口',
    'Username (optional)':'用户名（可选）','Password (optional)':'密码（可选）','Proxy username':'代理用户名','Proxy password':'代理密码',
    'Verify server certificates':'验证服务器证书','Disable certificate verification?':'关闭证书验证？',
    'Keep verification':'继续验证','Disable verification':'关闭验证',
    'Clear cache':'清理缓存','Remove account':'移除账号','Remove account?':'移除账号？','Remove':'移除',
    'Libraries':'资料库','My libraries':'我的资料库','Shared with me':'共享给我','Group libraries':'群组资料库',
    'Starred':'收藏','Files':'文件','Activity':'活动','Search server':'搜索服务器','Search':'搜索',
    'Search files and folders':'搜索文件和文件夹','Find a library':'查找资料库','Find a file':'查找文件',
    'Sync status':'同步状态','Sync status and download tasks':'同步状态与下载任务',
    'Edited files':'编辑中的文件','Open seafile-next':'打开 seafile-next','Quit seafile-next':'退出 seafile-next',
    'Open sync folder':'打开同步文件夹','Open logs folder':'打开日志文件夹','Show file sync errors':'查看文件同步错误',
    'Open sync log':'打开同步日志','File sync errors':'文件同步错误','No sync errors':'没有同步错误',
    'Show in Finder':'在 Finder 中显示','Discard error':'忽略错误','Download tasks':'下载任务',
    'No download tasks':'没有下载任务','Cancel download':'取消下载','Remove task':'移除任务','Recent sync activity':'最近同步活动',
    'Sync now':'立即同步','Disable auto sync':'关闭自动同步','Enable auto sync':'开启自动同步',
    'Set sync interval':'设置同步间隔','Resync this library':'重新同步此资料库','Stop syncing':'停止同步',
    'Stop syncing this library?':'停止同步此资料库？','Resync this library?':'重新同步此资料库？','Resync':'重新同步',
    'New library':'新建资料库','Name':'名称','Library name':'资料库名称','Description':'描述','Library description':'资料库描述',
    'Encrypted library':'加密资料库','Library password':'资料库密码','Repeat password':'确认密码',
    'Create without a local folder':'不关联本地文件夹','Create from an existing local folder':'从已有本地文件夹创建',
    'Creating library':'正在创建资料库','Sync library':'同步资料库','Share library':'分享资料库',
    'Library details':'资料库详情','Open on server':'在服务器上打开','Leave shared library':'退出共享资料库',
    'Leave this shared library?':'退出此共享资料库？','Leave library':'退出资料库','Encrypted':'已加密','Unencrypted':'未加密',
    'Read and write':'可读写','Read only':'只读','Refresh':'刷新','Sort':'排序','Last modified':'最后修改',
    'No libraries':'没有资料库','Loading libraries':'正在载入资料库','Could not load libraries':'无法载入资料库','Try again':'重试',
    'Unlock':'解锁','Empty folder':'空文件夹','New folder':'新建文件夹','Upload files':'上传文件',
    'Preview':'预览','Open':'打开','Open in default app':'在默认应用中打开','Download / Save as':'下载／另存为',
    'Copy':'复制','Cut':'剪切','Paste':'粘贴','Copy to…':'复制到…','Move to…':'移动到…',
    'Share…':'分享…','Share':'分享','Create share link':'创建分享链接','Star':'收藏','Unstar':'取消收藏',
    'Rename':'重命名','Delete':'删除','Lock file':'锁定文件','Unlock file':'解锁文件','Sync this folder':'同步此文件夹',
    'Selected items':'已选项目','Delete selected items':'删除已选项目','Delete selected items?':'删除已选项目？',
    'Search library':'搜索资料库','Parent folder':'上级文件夹','Library':'资料库',
    'Move here':'移动到此处','Copy here':'复制到此处','Share link':'分享链接',
    'Create download link':'创建下载链接','Create upload link':'创建上传链接','Get internal link':'获取内部链接',
    'Copy local file link':'复制本地文件链接','Copy link':'复制链接','Password (optional)':'密码（可选）','Link password':'链接密码',
    'Expires':'设置有效期','Expiration':'有效期','Share with people or groups':'分享给用户或群组',
    'Email':'邮箱','Contact':'联系人','Enter an email':'输入邮箱','Group':'群组','Share with a person':'分享给用户',
    'Permission':'权限','Add share':'添加分享','Remove share':'移除分享','Load more':'载入更多','Change details':'变更详情',
    'Open library':'打开资料库','Retry upload':'重试上传','Upload and replace':'上传并替换',
    'Stop watching':'停止监视','No edited files':'没有编辑中的文件','Sign in again':'重新登录',
    'Log out this device':'退出此设备的登录','Log out this device?':'退出此设备的登录？','Log out':'退出登录',
    'Set up default library':'设置默认资料库','Files and Finder integration':'文件 App 与 Finder 集成',
    'Open synced folders in Finder':'在 Finder 中打开同步文件夹','Online help':'在线帮助',
    'Confirm file deletions':'确认删除文件','Restore from server':'从服务器恢复','Sync deletions':'同步删除',
}

def normalize(value):
    return value.replace('&', '').strip().rstrip(':').replace('...', '…')

def quote(value):
    return json.dumps(value, ensure_ascii=False)

for ts in sorted((ROOT / 'desktop/i18n').glob('seafile_*.ts')):
    tree = ET.parse(ts)
    language = tree.getroot().get('language') or ts.stem.removeprefix('seafile_')
    locale = language.replace('_', '-')
    if locale == 'en':
        continue
    translations = {}
    for message in tree.findall('.//message'):
        source = message.findtext('source') or ''
        translation = message.find('translation')
        if translation is not None and translation.get('type') not in {'unfinished', 'obsolete', 'vanished'}:
            value = ''.join(translation.itertext()).strip()
            if value and '%1' not in source and '<' not in source:
                translations[normalize(source)] = normalize(value)
    values = {}
    for key in KEYS:
        value = translations.get(normalize(ALIASES.get(key, key)))
        if value:
            values[key] = value.replace('Seafile', 'seafile-next')
    if locale in {'zh-CN', 'zh-Hans'}:
        values.update(ZH)
        locale = 'zh-Hans'
    if locale == 'zh-TW':
        locale = 'zh-Hant'
    folder = ROOT / 'apple/Resources' / (locale + '.lproj')
    folder.mkdir(parents=True, exist_ok=True)
    lines = ['/* Native strings include translations from desktop/i18n, under the project license. */']
    lines += [f'{quote(key)} = {quote(value)};' for key, value in sorted(values.items())]
    (folder / 'Localizable.strings').write_text('\n'.join(lines) + '\n')
