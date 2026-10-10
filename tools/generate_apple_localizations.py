#!/usr/bin/env python3
"""Reuse the original desktop and iOS translations for native Apple controls."""
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'apple/Sources/SeafileApp'
KEYS = set()
for source in SOURCES.glob('*.swift'):
    for value in re.findall(r'(?:Text|Button|Label|Toggle|Section|Picker|TextField|SecureField|LabeledContent|ProgressView|PreferenceInput|LoginInput|ContentUnavailableView|navigationTitle|confirmationDialog|alert)\("([^"\n]+)"', source.read_text()):
        if '\\(' not in value:
            KEYS.add(value)
ALIASES = {
    'New library': 'Create a new library', 'New folder': 'New Folder', 'New file': 'New File',
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
    'Wikis':'知识库', 'My wikis':'我的知识库', 'Shared wikis':'共享知识库', 'Older wikis':'旧版知识库',
    'No wikis':'没有知识库', 'Loading wikis':'正在加载知识库', 'New wiki':'新建知识库', 'Rename wiki':'重命名知识库',
    'Wiki actions':'知识库操作', 'Publish wiki':'发布知识库', 'Publish':'发布', 'Published':'已发布',
    'Unpublish':'取消发布', 'Unpublish wiki?':'取消发布知识库？', 'Delete wiki':'删除知识库', 'Delete wiki?':'删除知识库？',
    'This deletes the wiki and its library from the server.':'这将从服务器删除知识库及其资料库。',
    'The public address will stop serving this wiki.':'公开地址将不再提供此知识库。',
    'Public address suffix':'公开地址后缀',
    'Publishing makes this wiki available to anyone with its address. Use 5–30 letters, numbers or hyphens.':'发布后，任何知道地址的人都可以访问此知识库。请使用 5–30 个英文字母、数字或连字符。',
    'Open collaborative editor':'打开协作编辑器', 'Opening document':'正在打开文档', 'Document':'文档', 'Response':'输入内容',
    'Reload':'重新加载', 'Close document?':'关闭文档？',
    'Check that the server has saved your changes before closing the document.':'关闭文档前，请确认服务器已保存你的修改。',
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
    'Unlock':'解锁','Empty folder':'空文件夹','New folder':'新建文件夹','New file':'新建文件','Upload files':'上传文件',
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
    'Photo backup':'照片备份','Enable photo backup':'启用照片备份','Destination':'目标位置',
    'Select destination':'选择备份位置','Choose destination':'选择备份位置','Include videos':'备份视频',
    'Include Live Photo videos':'备份 Live Photo 视频','Convert HEIC photos to JPEG':'将 HEIC 照片转换为 JPEG',
    'Wi-Fi only':'仅使用 Wi-Fi','All accessible photos':'所有可访问的照片','Selected albums':'所选相册',
    'Photo access':'照片访问权限','Allow photo access':'允许访问照片','Open system settings':'打开系统设置',
    'Backup options':'备份选项','Albums':'相册','Status':'状态','Save options':'保存选项',
    'Choose a library':'选择资料库','Choose a library and folder':'选择资料库和文件夹',
    'Backup destination':'备份位置','Choose this folder':'选择此文件夹',
    'Back up now':'立即备份','Stop backup':'暂停备份','Retry failed uploads':'重试失败的上传',
    'Check and retry failed backups':'检查并重试失败的备份','Check and retry failed photo uploads?':'检查并重试失败的照片上传？',
    'Check and retry':'检查并重试','Apply settings':'应用设置','Photo backup is off':'照片备份已关闭',
    'Live Photos include a separate paired video. Distinct photos and edited versions use distinct names.':'Live Photo 会同时备份配对视频。不同照片和编辑后的版本使用不同名称。',
    'JPEG conversion applies to HEIC/HEIF still photos. Live Photos with paired videos and other formats keep their originals. Changing this option keeps existing backups and adds the selected format for eligible photos.':'JPEG 转换适用于 HEIC/HEIF 静态照片。带配对视频的 Live Photo 和其他格式保留原件。更改此选项会保留已有备份，并为适用照片添加所选格式。',
    'Wi-Fi backups pause on a metered or Low Data Mode connection. Keep the app open while backing up.':'Wi-Fi 备份在按流量计费或低数据模式的连接下会暂停。备份时请保持应用打开。',
    'Save options after changing the album selection. Limited Photos access backs up only the photos you have allowed.':'更改相册选择后，请保存选项。仅授权部分照片时，只会备份你允许访问的照片。',
    'Stopping or losing a connection preserves upload records and local copies. Failed uploads wait for your check before they can be sent again.':'停止备份或断网会保留上传记录和本地副本。失败的上传会等待你检查后再重试。',
    'Existing destination files are verified first. A matching file is kept; a different file is never replaced. Uploads that are still missing may be submitted again.':'先核对目标目录的已有文件。内容相同的文件会保留，不同内容的文件不会被替换。仍未上传的文件可以重新提交。',
    'File information':'文件信息','Size':'大小','Dimensions':'尺寸','Camera':'相机','Taken':'拍摄时间',
    'Media actions':'媒体操作','Previous':'上一项','Next':'下一项','Share local file':'分享本地文件',
    'Save to Photos':'保存到照片','Saved to Photos':'已保存到照片','Saving to Photos':'正在保存到照片',
    'Preview unavailable':'无法预览','Retry':'重试','Transfers':'传输','Upload':'上传','Download':'下载',
    'Save local copy':'保存本地副本','Text editor':'文本编辑器','Save a copy':'另存副本',
    'Export draft':'导出草稿','Discard draft':'放弃草稿','Unsaved changes':'未保存的修改','Text drafts':'文本草稿',
    'This file changed on the server. Save a copy or export your draft to keep both versions.':'服务器上的文件已更改。另存副本或导出草稿可保留两个版本。',
    'This library is unavailable or read only. You can export the draft.':'此资料库不可用或为只读。你仍可导出草稿。',
    "The server version is preserved. Only this device's text edits are discarded.":'服务器上的版本会保留，仅放弃此设备上的文本修改。',
    'App lock':'应用锁','Require device authentication':'需要设备验证','Unlock seafile-next':'解锁 seafile-next',
}

def normalize(value):
    return value.replace('&', '').strip().rstrip(':').replace('...', '…')

def quote(value):
    return json.dumps(value, ensure_ascii=False)

def read_strings(path):
    data = path.read_bytes()
    text = data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8-sig')
    # Some preserved iOS files contain a second UTF-16 BOM as a text character.
    text = text.lstrip('\ufeff')
    tokens = re.finditer(r'/\*.*?\*/|(?P<key>"(?:\\.|[^"\\])*")\s*=\s*(?P<value>"(?:\\.|[^"\\])*")\s*;', text, flags=re.DOTALL)
    return {json.loads(token['key']): json.loads(token['value']) for token in tokens if token['key'] is not None}


def ios_translations(root):
    result = {}
    files = (root / 'ios-legacy/seafile/Supporting Files').glob('*.lproj/Localizable.strings')
    # New canonical locale files take precedence over older duplicate locales.
    for file in sorted(files, key=lambda p: ('-' in p.parent.stem, '_' in p.parent.stem, p.parent.stem)):
        locale = file.parent.stem.replace('_', '-')
        if locale in {'Base', 'en'}:
            continue
        language = locale.split('-')[0]
        if language == 'zh':
            language = 'zh-Hant' if locale in {'zh-Hant', 'zh-TW'} else 'zh-Hans'
        values = result.setdefault(language, {})
        values.update({normalize(key): value for key, value in read_strings(file).items() if value.strip()})
    return result


def generate(root=ROOT):
    legacy = ios_translations(root)
    represented = set()
    for ts in sorted((root / 'desktop/i18n').glob('seafile_*.ts')):
        language = generate_locale(ts, legacy, root)
        represented.add(language)
    for language, values in legacy.items():
        if language not in represented:
            write_locale(language, {}, values, root)


def generate_locale(ts, legacy, root):
    tree = ET.parse(ts)
    language = tree.getroot().get('language') or ts.stem.removeprefix('seafile_')
    locale = language.replace('_', '-')
    if locale == 'en':
        return
    translations = {}
    for message in tree.findall('.//message'):
        source = message.findtext('source') or ''
        translation = message.find('translation')
        if translation is not None and translation.get('type') not in {'unfinished', 'obsolete', 'vanished'}:
            value = ''.join(translation.itertext()).strip()
            if value and '%1' not in source and '<' not in source:
                translations[normalize(source)] = normalize(value)
    ios_language = 'zh-Hans' if locale in {'zh-CN', 'zh-Hans'} else 'zh-Hant' if locale in {'zh-TW', 'zh-Hant'} else locale.split('-')[0]
    write_locale(locale, translations, legacy.get(ios_language, {}), root)
    return ios_language


def write_locale(locale, translations, ios_values, root):
    values = {}
    for key in KEYS:
        value = ios_values.get(normalize(key)) or translations.get(normalize(ALIASES.get(key, key)))
        if value:
            values[key] = value.replace('Seafile', 'seafile-next')
    if locale in {'zh-CN', 'zh-Hans'}:
        values.update(ZH)
        locale = 'zh-Hans'
    if locale == 'zh-TW':
        locale = 'zh-Hant'
    folder = root / 'apple/Resources' / (locale + '.lproj')
    folder.mkdir(parents=True, exist_ok=True)
    lines = ['/* Native strings include original desktop and iOS translations, under the project license. */']
    lines += [f'{quote(key)} = {quote(value)};' for key, value in sorted(values.items())]
    (folder / 'Localizable.strings').write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    generate()
