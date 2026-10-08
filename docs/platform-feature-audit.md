# 全平台功能迁移审查

审查日期：2026-10-08。这里区分源文件保留、实际构建接入和运行验证。文件数量相同或编译成功，均不等于全部功能已在设备上验证。

## 源码保留情况

基准是整合前各仓库的最后一个源代码快照，来自 [source-origins.json](source-origins.json)。逐文件 Git 对比结果保存在 [platform-source-audit.json](platform-source-audit.json)。原仓库删除以后，这些源码仍保留在统一仓库中。

| 组件 | 整合前文件数 | 整合后新增 / 修改 / 删除 | 当前安装包使用的实现 |
| --- | ---: | --- | --- |
| Android | 1,282 | 2 / 9 / **0** | `android/` 原 Java 客户端，修复刷新与生命周期问题 |
| Windows / Linux 桌面界面 | 756 | 0 / 6 / **0** | `desktop/` 原 Qt 客户端；6 个修改涉及构建、会话状态和 Mac 开机启动 |
| 桌面同步引擎 | 210 | 0 / 0 / **0** | `sync/` 原同步引擎；原生 Mac 也继续使用这个引擎 |
| 旧 iOS | 881 | 0 / 0 / **0** | `ios-legacy/` 仅作迁移参照；新版 Apple 构建并未编译这些控制器和扩展 |

## Android

`android.yml` 运行原 Gradle 项目和原应用入口 `SeadroidApplication` / `SplashActivity`。原 Manifest 的 Activities、Providers 和 Services 均保留；没有通过新建简化界面替换原客户端。原 JNI 库也仍从 `app/libs` 打包。

| 原功能 | 入口与实现 | 审查结论 |
| --- | --- | --- |
| 多账号、密码、OTP、SSO | `ui/account/`、`ui/account/sso/`，原 Manifest 的认证服务 | 源码和构建入口保留 |
| 资料库与目录、搜索、收藏、批量操作 | `ui/repo/`、`ui/star/`，原菜单和适配器 | 保留；目录刷新请求增加代次控制和恢复刷新 |
| 相机/视频自动备份 | `ui/camera_upload/`、`AlbumBackupScanJobService`、`CameraSyncService` | 保留；不是仅保留设置文字 |
| 指定文件夹备份 | `ui/folder_backup/`、`FolderBackupScanJobService` | 保留 |
| 上传下载队列与文件监控 | `ui/transfer_list/`、`framework/file_monitor/`、原 Worker | 保留 |
| 系统文档提供程序与外部分享导入 | `provider/SeafileProvider`、`ui/share/`，Manifest 的 SEND / SEND_MULTIPLE | 保留并注册 |
| 文本/Markdown、SDoc、Office、图片和视频 | `ui/editor/`、`ui/markdown/`、`ui/sdoc/`、`ui/office_doc/`、`ui/media/` | 保留 |
| 原账户、缓存、安全锁及设置 | 原控制器、资源与数据库 | 保留；此次修改没有删除这些功能 |

现有 APK 是调试签名版，包名带 `.debug`；它与原正式版的应用数据隔离，不会自动读到原正式版账号或缓存。原自动备份在新版 Android 系统的后台限制、权限变化下是否可靠，不能靠源码保留或两个单元测试类证明。本轮未对真实 Android 设备完成全功能回归，不能宣称所有闪退已经消除。

## Windows

`desktop.yml` 实际编译 `seafile-client.sln` 和 `seafile.sln`，并保留 `HAVE_SHIBBOLETH_SUPPORT`。现有 ZIP 包中的主程序就是原桌面界面与原同步引擎。

| 原功能 | 审查结论 |
| --- | --- |
| 多账号、密码/OTP、SSO、资料库、群组/共享资料库 | 原控制器仍参与构建 |
| 桌面同步、加密资料库、同步间隔、暂停/恢复、限速、删除确认、同步错误 | 原 Qt / RPC / 引擎实现仍参与构建 |
| 云文件浏览、预览、默认程序编辑与回传、复制/移动、文件锁、分享/内部链接、活动和搜索 | 原 `src/filebrowser/` 及相应服务仍参与构建 |
| 自启动、HTTP/SOCKS/系统代理、通知、缓存、语言、证书校验设置 | 原实现仍参与构建 |
| Explorer 右键与同步/锁徽标 | **原源码保留，但此前发布 ZIP 未包含 DLL，属于打包遗漏。** 新流水线独立编译原 `desktop/extensions/`，验证七个 COM 工厂，并把 DLL 与安装/卸载入口加入包中 |
| `seafile://` 从浏览器打开本地文件 | 客户端处理器已保留，但便携包缺少协议注册；新集成安装脚本补上带引号的 `--open-local-file` 注册 |
| 应用自动升级 | 保留的旧 `AutoUpdateService` 写有上游 appcast 地址，但当前启动、设置和关于界面没有调用该服务；不能将保留这段代码算作已接入的新项目升级功能。新项目没有可用的 Windows 自动安装更新链路 |

Explorer 安装脚本只在用户运行安装入口时注册，并提供卸载入口；不会由应用启动自动修改注册表或重启 Explorer。独立验证使用随机的临时注册表子树，验证卸载以及后来安装者的所有权保护。实际桌面上徽标是否受 Windows 的 overlay 数量限制，还需设备检查。[Microsoft 的注册说明](https://learn.microsoft.com/en-us/windows/win32/shell/how-to-register-icon-overlay-handlers)说明了这项系统集成的注册位置。

## Linux

`linux.yml` 直接构建原 `desktop/` Qt 客户端和 `sync/` 引擎，并显式启用 Shibboleth / Qt WebEngine。资源和翻译通过原 CMake 规则嵌入，DEB 包附带引擎及运行库依赖、应用图标和桌面启动入口。

| 原功能 | 审查结论 |
| --- | --- |
| 账号/SSO、资料库、云文件浏览、文件操作、分享、活动、搜索 | 原实现仍参与构建 |
| 同步、加密、间隔、暂停/恢复、限速、错误、删除确认 | 原实现仍参与构建 |
| 系统托盘、开机启动、代理、通知、缓存和语言 | 原实现仍参与构建；实际桌面环境行为尚未逐一验证 |
| Explorer / Finder 扩展 | 原客户端的 Windows / Mac 专属实现；Linux 没有因为合并而失去这两个其他平台的扩展 |
| FUSE | 构建显式关闭独立 FUSE 工具，原 Qt 桌面同步功能仍在；不能把本 DEB 称为完整包含源码树内每一个附属命令行产品 |
| 浏览器 `seafile://` 协议注册 | 此前 DEB 缺少注册。本轮添加独立协议处理 `.desktop` 和安装/卸载缓存刷新；重打包验证原二进制哈希全部保持不变，桌面数据库能识别该协议 |
| 应用自动升级 | Linux 未构建 Sparkle；本项目目前提供 DEB 下载，没有建立 APT 仓库/自动升级链路 |

当前正式下载只覆盖 Linux amd64 和 Windows x64，不能把保留跨平台源码理解为已发布 ARM64/其他发行版安装包。

## 原生 iOS：确实还存在功能缺口

`apple/project.yml` 的 iOS 目标仅编译 `Sources/SeafileApp`、`SeafileCore` 和新的 File Provider。旧 `ios-legacy/` 的控制器和 Share / FileProviderActionsUI / FileProviderUI 扩展没有编入新版，**不能声称完成原 iOS 全功能迁移**。

| 功能 | 现有原生 iOS | 原实现参照 |
| --- | --- | --- |
| 多账号、密码/OTP、现代客户端 SSO | 已接入；SSO、错误恢复、账号切换有回归覆盖 | `SeafAccountViewController`、`SeafShibbolethViewController` |
| 资料库、目录、刷新、缓存、上传下载、Quick Look | 已接入；基本导航和预览有模拟器覆盖 | `SeafFileViewController`、`SeafDirViewController`、`SeafDetailViewController` |
| 目录创建、改名、删除、文件/文件夹收藏、简单分享链接 | 已接入 | 原 Selection 协调器和对应控制器 |
| 「文件」App 枚举、下载、编辑提交、创建/删除、改名/移动 | 新 File Provider 已编译签名；真实设备会话未完整验证 | 旧 `SeafFileProvider/` |
| 相机/相册/视频自动备份、Live Photo / Motion Photo、Wi-Fi 和后台备份设置 | **尚未迁移** | `SeafSettingsViewController`、`SeafBackupGuideViewController`、`SeafPhotoBackupTool`、原相册处理逻辑 |
| 应用内批量选择、复制/移动、目标目录与最近目录 | **尚未接入 iOS 界面**；系统 Files 的移动不能替代这个入口 | `Selection/`、`SeafDestinationPickerViewController`、`RecentDirs/` |
| 创建/删除/退出资料库、共享权限管理、密码/到期分享链接 | **尚未在 iOS 接入完整界面** | `SeafMkLibAlertController`、原账户和目录控制器 |
| 服务器全局搜索、活动与变更详情 | Core API 及 Mac 界面已有，**iOS 仍只有当前列表过滤，没有完整入口** | `SeafSearchResultViewController`、`SeafActivityViewController` |
| 文本/Markdown 编辑与回传 | **尚未迁移** | `SeafTextEditorViewController` |
| SDoc 协作编辑、评论/@成员、Wiki、Office 专用体验 | **尚未迁移**；Quick Look 不能代替 | `SDoc/`、`Comment/`、`Wiki/` |
| 照片画廊、专用视频播放器、照片信息与缩略图行为 | **未达原实现功能** | `SeafPhotoGalleryViewController`、`SeafVideoPlayerViewController` 等 |
| 可持久化/恢复的上传下载队列、后台续传、独立传输管理 | 独立前台队列已加入源码，带进度、取消、重试、持久化与本地副本保护；**iOS 系统后台续传仍未实现**，不能称为完整迁移 | `SeafSyncInfoViewController`、`SeafFileOperationManager`、原任务模型 |
| 外部 App 分享导入扩展 | **未包含**；应用内文件导入不等同 Share Extension | `SeafShare/` |
| Files 自定义操作 UI、旧 Document Picker 功能 | **未包含对应扩展**；Mac 自定义 File Provider 操作不适用于 iOS | `SeafFileProviderActionsUI/`、`SeafFileProviderUI/` |
| Face ID / Touch ID 应用锁、完整备份/缓存设置 | **尚未迁移完整设置与应用锁** | `SeafSettingsViewController`、原 AppDelegate |
| 加密资料库本地解密与加密上传、离线加密行为 | **未迁移原可选本地解密路径**；当前是服务器解锁接口，不等同本地解密 | `SeafConnection.localDecryptionEnabled`、原加密与文件任务代码 |
| 所有原语言的完整译文 | 共享资源已加入，但新增原生文字和旧 iOS 专用界面尚未达到完整覆盖 | 旧 `.lproj` 和原资源 |
| 较旧服务器的 cookie-bridge SSO | **尚未实现回退**；当前使用服务端宣告的 client SSO 协议 | 原 Shibboleth 控制器 |

这份缺口表是后续迁移的验收清单，不应在发布说明中将这些项目描述为已完成。补齐 iOS 集成之前，仍使用现有两个 Apple Identifiers 和现有证书；新增扩展如果需要注册，必须明确说明用途，不能悄悄生成新 Apple Portal Identifier。

## 原生 macOS 本轮补齐与验证

修复可编辑、空值、左对齐且有清晰边界的登录输入；恢复 Dock 隐藏、开机启动状态、代理、语言、账号/服务器设置、同步策略和错误处理。接入原同步引擎，补齐库创建、批量文件操作、权限分享、全局搜索、活动、默认程序编辑回传及待上传编辑保护、内部协议链接、资料库/目录导航。直接安装版加入原生 Finder 同步徽标和右键操作；沙盒版继续使用已有 File Provider。直接安装版增加版本检查、包完整性校验及保留旧应用的更新安装路径。

[Native validation 37731550245](https://github.com/felixbennettio/seafile-next/actions/runs/37731550245)通过 4 个 Mac 界面测试、8 个 iPhone 回归测试，并成功构建沙盒 Mac 和 File Provider；本机 Core 测试有 37 项通过，包含真实打包同步引擎的隔离 RPC、实际 HTTP 代理请求及隔离临时应用的签名校验/更新安装/旧版保留。实际用户设备的 Finder 菜单/徽标、重启后登录项、完整更新重启和生产账号会话仍需分别验证。

[Windows integration 37750265170](https://github.com/felixbennettio/seafile-next/actions/runs/37750265170)成功加载原扩展的 DLL、获取七个 COM 工厂，并通过六个状态徽标注册、协议引号、卸载和其他安装者保护测试。[Linux integration 37751171840](https://github.com/felixbennettio/seafile-next/actions/runs/37751171840)复用原 DEB，验证全部原运行文件哈希不变、桌面文件有效、协议进入 MIME 缓存，再生成 DEB。两项工作均未重新编译原 Windows/Linux 主程序。

这轮新增的直接安装版 Finder 扩展 Bundle ID 只用于本地构建与 ad-hoc 签名，没有在 Apple Developer Portal 新注册 Identifier、证书或 profile。已有 iOS / Mac / File Provider 的正式签名继续复用。

## 后续补齐：目录排序与独立传输队列

2026-10-08 后续源码加入目录按名称、大小、类型、修改时间排序及升降序；Mac、iOS 共用独立的上传下载队列。队列支持两项并行、目录递归上传/下载、进度、取消、失败重试、导出本地副本与持久化记录，不再由目录页面退出触发取消。收藏预览也使用该队列，离开页面后的完成事件不会强行打开预览。

上传先保存私有副本。程序重启后，曾处于执行中的上传会显示为中断并等待用户检查服务器后重试，避免重放已经成功但未收到响应的写操作；未发出的队列项可以继续，下载则从头安全重试。它不等同于断点续传，也不等同于 iOS 系统后台传输。历史损坏时保持原文件并禁用新传输，避免覆盖旧记录；账号移除保护尚未处理的上传。

本机最新源码的 44 项 Core 测试通过，包括真实本地 HTTP 上传/下载进度及文件内容、两项并行与重复下载合并、取消/重试、进程中断恢复、失败上传副本、权限及损坏历史保护。[Native validation 37761811837](https://github.com/felixbennettio/seafile-next/actions/runs/37761811837) 对 `509e068c252420f6fa79f9fb4eb55d679894bef1` 通过 5 个 Mac 界面测试和 9 个 iPhone 回归测试，包括离开目录后的下载完成，并构建通过沙盒 Mac 与 File Provider。之后仅修正了缺失/零时间戳排序的一致性，以及失败上传的提示文字，并再次通过 44 项 Core 测试与界面源文件语法检查。

这段更新表示源码进展；已发布的 TestFlight `1.0.0 (2422.53.59)` 和 v1.0.0 直装包仍是此前修复版本，尚不包含这轮队列与排序。不得将 CI 测试包或源码合并描述为已推送到用户设备。

Mac 的真实 Finder / 开机启动 / 更新重启、旧服务器 SSO 回退及全部原语言覆盖仍不能宣称完成验收。iOS 上表中的相册备份、后台传输、批量操作、编辑器、外部分享、安全锁及本地加密解密缺口依然存在。**原版五个平台全部能力迁移尚未完成。**
