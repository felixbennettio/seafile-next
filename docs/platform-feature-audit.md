# 全平台功能迁移审查

审查日期：2026-10-09。这里区分源文件保留、实际构建接入和运行验证。文件数量相同或编译成功，均不等于全部功能已在设备上验证。

## 源码保留情况

基准是整合前各仓库的最后一个源代码快照，来自 [source-origins.json](source-origins.json)。逐文件 Git 对比结果保存在 [platform-source-audit.json](platform-source-audit.json)。原仓库删除以后，这些源码仍保留在统一仓库中。下表文件数量描述最初整合快照；后续修复与迁移状态见各平台及文末记录。

| 组件 | 整合前文件数 | 最初整合时新增 / 修改 / 删除 | 当前安装包使用的实现 |
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

审查还发现旧 CI 每次运行会新建调试签名，不同构建不能保证覆盖安装。后续流程从固定的 `ANDROID_DEBUG_KEYSTORE` Secret 恢复同一签名，校验 `ANDROID_DEBUG_CERT_SHA256` 指纹；缺少密钥或指纹不符就停止，禁止生成替代签名。当前 Release 已切换为经过实际 APK 签名验证的固定调试签名包。首次切换到固定签名的后续 APK，不能覆盖现有旧调试包，需先备份尚未上传的本地文件并重新安装；后续构建才可持续覆盖升级。包名不同的原正式版不受影响。

[Android signing validation 37766572494](https://github.com/felixbennettio/seafile-next/actions/runs/37766572494) 成功从仓库 Secret 连续两次恢复相同密钥并验证固定证书指纹，未构建或替换 APK。本地另外验证了缺少密钥、指纹不符时停止并保持已有签名文件不变。固定签名解决后续版本之间的升级身份问题，不等同于原正式版签名，也没有补做 Android 真机功能回归。

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
| 多账号、密码/OTP、现代及旧服务器 SSO | 已接入；SSO、错误恢复、账号切换有回归覆盖 | `SeafAccountViewController`、`SeafShibbolethViewController` |
| 资料库、目录、刷新、缓存、上传下载、Quick Look | 已接入；基本导航和预览有模拟器覆盖 | `SeafFileViewController`、`SeafDirViewController`、`SeafDetailViewController` |
| 目录创建、改名、删除、文件/文件夹收藏、简单分享链接 | 已接入 | 原 Selection 协调器和对应控制器 |
| 「文件」App 枚举、下载、编辑提交、创建/删除、改名/移动 | 新 File Provider 已编译签名；真实设备会话未完整验证 | 旧 `SeafFileProvider/` |
| 相机/相册/视频自动备份、Live Photo / Motion Photo、Wi-Fi 和后台备份设置 | 前台原始照片/视频/Live Photo 成对资源备份、Wi-Fi 限制、相册选择与私有持久化记录已加入待验证源码；后台续传、JPEG 转换和 Motion Photo 合并仍未实现 | `SeafSettingsViewController`、`SeafBackupGuideViewController`、`SeafPhotoBackupTool`、原相册处理逻辑 |
| 应用内批量选择、复制/移动、目标目录与最近目录 | 已加入原生选择、复制/移动、删除、下载、目标目录与按账号保存的最近目录；失败后保留已确认结果，剩余项目需人工确认后重试。已通过原生界面验证并发布到 TestFlight 2429.18.65 和现有 Release | `Selection/`、`SeafDestinationPickerViewController`、`RecentDirs/` |
| 创建/删除/退出资料库、共享权限管理、密码/到期分享链接 | 已加入创建（含原 iOS 的服务端加密创建方式）、删除/退出、详情，以及用户/群组权限、密码和到期分享链接；已通过界面及隔离服务器验证并发布到 TestFlight 2429.18.65 和现有 Release | `SeafMkLibAlertController`、原账户和目录控制器 |
| 服务器全局搜索、活动与变更详情 | 已加入 iOS 入口；社区版按库搜索文件/文件夹名称，Pro 全局搜索依赖服务器能力声明。活动与变更详情有原生页面；已通过界面验证并发布到 TestFlight 2429.18.65 和现有 Release | `SeafSearchResultViewController`、`SeafActivityViewController` |
| 文本/Markdown 编辑与回传 | UTF-8 文本/Markdown 源码编辑、草稿持久化、导出、另存副本及保存前内容冲突检查已实现并通过 18 项 iPhone 界面测试；SDoc/富文本协作未包含，已发布到 TestFlight 2430.69.19 与现有 Release | `SeafTextEditorViewController` |
| SDoc 协作编辑、评论/@成员、Wiki、Office 专用体验 | **尚未迁移**；Quick Look 不能代替 | `SDoc/`、`Comment/`、`Wiki/` |
| 照片画廊、专用视频播放器、照片信息与缩略图行为 | 已加入相邻照片切换、缩放、文件信息、原生视频控件与保存到 Photos 的待验证源码；动画 GIF、Motion Photo 及全部原画廊细节尚未恢复 | `SeafPhotoGalleryViewController`、`SeafVideoPlayerViewController` 等 |
| 可持久化/恢复的上传下载队列、后台续传、独立传输管理 | 独立前台队列已加入源码，带进度、取消、重试、持久化与本地副本保护；**iOS 系统后台续传仍未实现**，不能称为完整迁移 | `SeafSyncInfoViewController`、`SeafFileOperationManager`、原任务模型 |
| 外部 App 分享导入扩展 | **未包含**；应用内文件导入不等同 Share Extension | `SeafShare/` |
| Files 自定义操作 UI、旧 Document Picker 功能 | **未包含对应扩展**；Mac 自定义 File Provider 操作不适用于 iOS | `SeafFileProviderActionsUI/`、`SeafFileProviderUI/` |
| Face ID / Touch ID 应用锁、完整备份/缓存设置 | 已加入系统 Face ID / Touch ID / 设备密码应用锁，后台重锁、弹窗与预览遮罩；它不限制系统 Files 的访问。备份与缓存设置仍未完整迁移，应用锁已通过模拟器验证并发布到 TestFlight 2429.18.65；真实设备生物认证尚需验证 | `SeafSettingsViewController`、原 AppDelegate |
| 加密资料库本地解密与加密上传、离线加密行为 | **未迁移原可选本地解密路径**；当前是服务器解锁接口，不等同本地解密 | `SeafConnection.localDecryptionEnabled`、原加密与文件任务代码 |
| 所有原语言的完整译文 | 共享资源已加入，但新增原生文字和旧 iOS 专用界面尚未达到完整覆盖 | 旧 `.lproj` 和原资源 |
| 较旧服务器的 cookie-bridge SSO | 已加入旧 `shib-login` 兼容源码；现代服务器保持系统浏览器。根路径/子路径隔离 OIDC 服务器已通过旧 cookie 返回及身份验证，原生界面验证中 | 原 Shibboleth 控制器 |

这份缺口表是后续迁移的验收清单，不应在发布说明中将这些项目描述为已完成。补齐 iOS 集成之前，仍使用现有两个 Apple Identifiers 和现有证书；新增扩展如果需要注册，必须明确说明用途，不能悄悄生成新 Apple Portal Identifier。

## 原生 macOS 本轮补齐与验证

修复可编辑、空值、左对齐且有清晰边界的登录输入；恢复 Dock 隐藏、开机启动状态、代理、语言、账号/服务器设置、同步策略和错误处理。接入原同步引擎，补齐库创建、批量文件操作、权限分享、全局搜索、活动、默认程序编辑回传及待上传编辑保护、内部协议链接、资料库/目录导航。直接安装版加入原生 Finder 同步徽标和右键操作；沙盒版继续使用已有 File Provider。直接安装版增加版本检查、包完整性校验及保留旧应用的更新安装路径。

[Native validation 37731550245](https://github.com/felixbennettio/seafile-next/actions/runs/37731550245)通过 4 个 Mac 界面测试、8 个 iPhone 回归测试，并成功构建沙盒 Mac 和 File Provider；本机 Core 测试有 37 项通过，包含真实打包同步引擎的隔离 RPC、实际 HTTP 代理请求及隔离临时应用的签名校验/更新安装/旧版保留。实际用户设备的 Finder 菜单/徽标、重启后登录项、完整更新重启和生产账号会话仍需分别验证。

[Windows integration 37750265170](https://github.com/felixbennettio/seafile-next/actions/runs/37750265170)成功加载原扩展的 DLL、获取七个 COM 工厂，并通过六个状态徽标注册、协议引号、卸载和其他安装者保护测试。[Linux integration 37751171840](https://github.com/felixbennettio/seafile-next/actions/runs/37751171840)复用原 DEB，验证全部原运行文件哈希不变、桌面文件有效、协议进入 MIME 缓存，再生成 DEB。两项工作均未重新编译原 Windows/Linux 主程序。

这轮新增的直接安装版 Finder 扩展 Bundle ID 只用于本地构建与 ad-hoc 签名，没有在 Apple Developer Portal 新注册 Identifier、证书或 profile。已有 iOS / Mac / File Provider 的正式签名继续复用。

## 后续补齐：目录排序与独立传输队列

2026-10-08 后续源码加入目录按名称、大小、类型、修改时间排序及升降序；Mac、iOS 共用独立的上传下载队列。队列支持两项并行、目录递归上传/下载、进度、取消、失败重试、导出本地副本与持久化记录，不再由目录页面退出触发取消。收藏预览也使用该队列，离开页面后的完成事件不会强行打开预览。

上传先保存私有副本。程序重启后，曾处于执行中的上传会显示为中断并等待用户检查服务器后重试，避免重放已经成功但未收到响应的写操作；未发出的队列项可以继续，下载则从头安全重试。它不等同于断点续传，也不等同于 iOS 系统后台传输。历史损坏时保持原文件并禁用新传输，避免覆盖旧记录；账号移除保护尚未处理的上传。

本机最新源码的 44 项 Core 测试通过，包括真实本地 HTTP 上传/下载进度及文件内容、两项并行与重复下载合并、取消/重试、进程中断恢复、失败上传副本、权限及损坏历史保护。[Native validation 37761811837](https://github.com/felixbennettio/seafile-next/actions/runs/37761811837) 对 `509e068c252420f6fa79f9fb4eb55d679894bef1` 通过 5 个 Mac 界面测试和 9 个 iPhone 回归测试，并构建通过沙盒 Mac 与 File Provider。

之后修正了缺失/零时间戳排序的一致性及失败上传提示。截图复查发现原页面切换测试存在固定延迟与测试驱动等待的竞态，因此改为切换后手动释放模拟下载，使用侧栏专用标识并验证无额外预览窗口；同时增加导航代次保护，防止 SwiftUI 保留旧目录时打开迟到的预览。[最终验证 37766570924](https://github.com/felixbennettio/seafile-next/actions/runs/37766570924) 对 `91d17279835b13ead43564a9711178adc087c502` 通过 44 项 Core 测试、5 个 Mac 界面测试和 9 个 iPhone 回归测试，并构建通过沙盒 Mac 与 File Provider。

队列与排序先通过 [Apple delivery 37770759612](https://github.com/felixbennettio/seafile-next/actions/runs/37770759612) 发布到 iOS 与 macOS TestFlight `1.0.0 (2423.48.29)`。之后包含登录修复的 [Apple delivery 37861588411](https://github.com/felixbennettio/seafile-next/actions/runs/37861588411) 已发布 TestFlight `1.0.0 (2427.95.44)`，两平台状态均为 VALID，并分配给现有内部测试组；50 项 Core、5 个 Mac 与 9 个 iPhone 界面测试通过。此次复用原分发证书、安装证书及四个描述文件，没有增加 Identifier。v1.0.0 公共 Release 已替换 Mac 非沙盒 ZIP、iPhone 设备未签名 IPA、清单与校验文件，并以匿名公开下载核对哈希；原 Android、Windows、Linux 包及镜像引用、Release 身份和标签保持不变。

Mac 登录检查发现原生客户端把完整的 macOS 构建描述发送为 `platform_version`，超出 `TokenV2` 的 16 字符数据库字段限制；设备名空白或过长也未处理。现改为数字系统版本，并按原服务端字符限制处理设备名与版本。密码及 SSO 共享相同的元数据生成入口。400 响应中的 `non_field_errors` 和字段错误现在会显示具体原因；带两步验证码的登录不会在响应丢失后自动重放，因为原服务端会消费已验证的 TOTP。[隔离登录验证 37861584890](https://github.com/felixbennettio/seafile-next/actions/runs/37861584890) 在根路径与 `/seafile/` 子路径使用实际 Swift 入口生成的字段，成功重现旧 Mac 元数据导致的数据库 500 与 SSO 确认后 Page unavailable；新字段通过密码登录、完整 OIDC 授权和资料库访问。**此验证使用隔离服务器和测试账号，用户服务器上的实际授权仍需实测。**

Mac 的真实 Finder / 开机启动 / 更新重启、旧服务器 SSO 回退及全部原语言覆盖仍不能宣称完成验收。iOS 上表中的相册备份、后台传输、编辑器、外部分享及本地加密解密缺口依然存在；批量操作、资料库与高级分享、搜索活动、应用锁已完成本轮验证和发布；后续文本编辑、备份、媒体及旧 SSO 按下列记录推进。**原版五个平台全部能力迁移尚未完成。**

## 2026-10-09 已验证与继续补齐

本轮 iPhone 批量操作采用原服务端 copy-move-task API。隔离社区服务器暴露了原生 Mac API 同样存在的兼容问题：小任务直接返回 `{}`，只有后台任务返回 `task_id`。现在两种成功响应分别处理；错误、取消和异常响应均不显示为成功，且不自动重复提交写请求。单次批量窗口记录已确认的项目，停止会等待当前项目结束，错误后的手动重试跳过已确认项目。这不等同于可跨应用重启恢复的批量任务队列。最近目录按账号隔离、限制二十条并持久化；损坏历史保持原文件。

iOS 共享与资料库管理复用 Mac / Core 接口；加密库在 iOS 上采用旧 iOS 客户端发送 `passwd` 的服务端创建流程，Mac 继续由同步引擎生成加密元数据。该项创建能力不等同于已经迁移本地加密解密。应用锁通过 LocalAuthentication 验证设备持有人，并用独立场景窗口遮住设置弹窗、Quick Look 和后台快照；模拟器使用仅 Debug 可用的验证替身，不能算 Face ID / Touch ID 真机认证验证。没有新增 Apple Identifier、证书或描述文件。

本机及 [最终原生验证 37876122402](https://github.com/felixbennettio/seafile-next/actions/runs/37876122402) 的 65 项 Core 测试通过；CI 还通过 5 项 Mac、17 项 iPhone 界面测试，以及沙盒 Mac / File Provider 构建。覆盖社区版搜索、活动详情、资料库创建和删除、批量复制/移动/删除、部分失败后跳过已确认结果、密码/到期分享及应用锁遮住设置弹窗。首次验证暴露的折叠搜索输入、选中项目按钮溢出、收藏路径结尾斜线和开关测试定位均已修正。预览等待可以单独取消，不会取消共享的队列下载或在离开页面后弹出迟到预览。

[真实隔离服务器验证 37873683274](https://github.com/felixbennettio/seafile-next/actions/runs/37873683274) 在根路径与 `/seafile/` 两种部署通过复制/移动和密码/到期分享。本节功能已由 [Apple delivery 37878523602](https://github.com/felixbennettio/seafile-next/actions/runs/37878523602) 发布到 iOS 与 macOS TestFlight `1.0.0 (2429.18.65)`，两平台均为 VALID、现有测试组保留。公共 v1.0.0 已替换本批 Mac 直装 ZIP 与 iOS 未签名 IPA，匿名下载验证四个替换资产；原 Android/Windows/Linux 与镜像资产、Release 身份和标签保持不变。签名日志确认复用原两项证书和四项描述文件。

## 2026-10-09 后续验证中的功能

文本编辑 [PR 7](https://github.com/felixbennettio/seafile-next/pull/7) 已合并。[原生验证 37879487219](https://github.com/felixbennettio/seafile-next/actions/runs/37879487219) 通过 68 项 Core、5 项 Mac、18 项 iPhone 测试，以及沙盒 Mac / File Provider 构建；文本编辑测试上传实际编辑后再次读取预览。草稿保留原 UTF-8 BOM 和换行；保存前比较服务器内容，失败或冲突保留草稿。它没有提供服务器原子比较写入或 SDoc 协作。

相册备份 [PR 8](https://github.com/felixbennettio/seafile-next/pull/8) 采用逐资源私有 SQLite 记录和流式内容哈希，保留不确定上传记录，核对目标后才允许手动重试，绝不覆盖已有文件。兼容旧备份名称时也先验证字节内容。73 项 Core 测试通过，实际服务器单文件元数据接口已在根/子路径部署验证；相册界面与真实 PhotoKit 图片导出已在 [原生验证 37902516926](https://github.com/felixbennettio/seafile-next/actions/runs/37902516926) 通过：73 项 Core、5 项 Mac、3 项针对性 iPhone 回归及沙盒 Mac / File Provider 构建；实际导出七项模拟器照片，重复扫描不重新上传。前台备份仍不能替代系统后台传输。

旧服务器 SSO [PR 9](https://github.com/felixbennettio/seafile-next/pull/9) 只在服务器未声明现代客户端协议时启用，使用每次独立的临时 WebKit 会话；精确核对 cookie 名称、服务器域名、返回页面和令牌格式，并通过账号接口验证。原库实现中的 TLS 放行和凭据日志没有迁入。76 项 Core 和 12 项工具测试通过。[实际旧 OIDC 验证 37900249190](https://github.com/felixbennettio/seafile-next/actions/runs/37900249190) 在禁用现代协议的根/子路径服务器上通过 iOS/Mac 的授权、cookie 令牌身份与资料库访问。合并功能的 [原生验证 37902631117](https://github.com/felixbennettio/seafile-next/actions/runs/37902631117) 通过 76 项 Core、6 项 Mac 界面测试和 iPhone 的取消后密码登录回归；该运行只有画廊尺寸标签断言失败。单独 scoped 验证在 Mac 界面启动前超时，没有计为通过。旧 cookie 协议仍不能保证外部认证 App 的跳回。

媒体画廊 [PR 10](https://github.com/felixbennettio/seafile-next/pull/10) 已加入原生相邻切换、图片缩放、尺寸/相机/拍摄时间信息、原文件分享、主动收藏、保存到 Photos，以及下载后原生 MP4/M4V/MOV 视频控件。显示用图片最大 4096 像素，导出保留原文件；进行中的保存和打开文件阻止清理对应缓存。新图片下载、切换、信息和收藏测试正在验证，真实视频播放与 Photos 保存未经过设备验收。

以上后续 PR 的源码状态不等同于已交付安装包。系统后台/断点传输、SDoc/评论/Wiki/Office、外部分享扩展、全部语言、原本地加解密及 Motion Photo 等能力仍有缺口。

## 2026-10-09 后续交付与成品复查

[Apple delivery 37899313246](https://github.com/felixbennettio/seafile-next/actions/runs/37899313246) 已把文本编辑版发布到 iOS / macOS TestFlight `1.0.0 (2430.69.19)`，两端均 VALID，复用原两项证书和四项描述文件。该源码通过 68 项 Core、5 项 Mac、18 项 iPhone 界面测试。公共 v1.0.0 的 Mac 直装 ZIP、iOS 未签名 IPA、清单和校验文件已替换并匿名下载验证；原其他平台资产和 Release 身份保持不变。

Windows / Linux 原 Qt 客户端保存服务端能力时遗漏现代 SSO 标志，相等比较也忽略这项变化；[PR 11](https://github.com/felixbennettio/seafile-next/pull/11) 已修复。[Qt 回归 37901784464](https://github.com/felixbennettio/seafile-next/actions/runs/37901784464) 在 Windows 2025 / Ubuntu 24.04、Qt 6.8.3 通过原用例与新增的保存恢复、能力切换测试。[Windows 构建 37902630009](https://github.com/felixbennettio/seafile-next/actions/runs/37902630009) 与 [Linux 构建 37902630015](https://github.com/felixbennettio/seafile-next/actions/runs/37902630015) 已成功，包含既有系统集成。

Android 收藏请求原先并行删除本地缓存，网络失败也会丢失离线收藏；现只在有效响应后按账号事务替换，数据库失败回滚，过期刷新不覆盖新结果。[PR 12](https://github.com/felixbennettio/seafile-next/pull/12) 已合并，[17 项回归和 APK 构建 37903623585](https://github.com/felixbennettio/seafile-next/actions/runs/37903623585) 成功。成品复查发现此 APK 虽有有效 v2 签名，却没有使用恢复的固定证书，因此没有发布该包。此前 signing-only 验证仅证明密钥恢复一致，不能证明 APK 使用了它。[PR 13](https://github.com/felixbennettio/seafile-next/pull/13) 正在将 Gradle 显式绑定到固定签名文件，并在上传前核验实际 APK。首次由旧 Release 调试证书迁移到固定证书仍需保留本地未上传文件后重新安装。

## 2026-10-09 后续迁移与发布状态

此前的“待发布”描述记录对应阶段，不代表当前所有已验证功能仍未发布。批量操作、资料库/共享管理、搜索/活动与应用锁已经发布；文本/Markdown 编辑的 iOS 与 macOS TestFlight `1.0.0 (2430.69.19)` 均为 VALID，v1.0.0 的 Mac 直装 ZIP 与 iPhone 设备 IPA 已替换并匿名下载核对。

- [前台照片备份验证 37902516926](https://github.com/felixbennettio/seafile-next/actions/runs/37902516926)通过 73 项 Core、5 项 Mac 和 3 项 iPhone 检查，包括真实模拟器 PhotoKit 导出、重复扫描不重复上传，以及视频/Live Photo 配对资源。备份默认为关闭、Wi-Fi 限制开启；历史采用按资源持久化的事务，上传不确定时检查远端字节后才允许用户重试。它仍是前台备份，不等同 iOS 系统后台续传。
- [旧服务器 SSO 验证 37900249190](https://github.com/felixbennettio/seafile-next/actions/runs/37900249190)在实际隔离服务端根路径与子路径完成旧客户端授权、cookie 校验和账户/资料库访问。现代服务器继续使用默认浏览器和 nonce 协议；旧服务器回退采用独立临时网页会话。旧 IdP 的外部认证 App 回调仍不能声称已在用户设备验证。
- [画廊最终回归 37908270751](https://github.com/felixbennettio/seafile-next/actions/runs/37908270751)通过 76 项 Core 和 3 项针对性 iPhone 检查，构建通过沙盒 Mac / File Provider。照片原件由队列取得，界面解码限制缩略图大小；预览、显式收藏和相邻切换相互独立。完整验证中的一项照片尺寸断言曾与实际合并标签不一致，已依据截图/层级修正并通过；不能把先前失败的整轮记录算作成功。
- Windows / Linux 的原账号状态比较与持久化遗漏了现代 SSO 能力字段。已修复，并在两种系统通过契约测试；[Windows 构建 37902630009](https://github.com/felixbennettio/seafile-next/actions/runs/37902630009)和 [Linux 构建 37902630015](https://github.com/felixbennettio/seafile-next/actions/runs/37902630015)通过，完整 ZIP / DEB 已替换公开包并匿名核对。Windows 包含原 Explorer 扩展 DLL 与安装/卸载入口。
- Android 收藏请求失败时不再提前清空离线记录；有效结果在单次数据库事务中替换，失败写入会回滚。较早请求不能覆盖新账号/新刷新结果。[Android 验证 37911813239](https://github.com/felixbennettio/seafile-next/actions/runs/37911813239)通过 19 项检查，含真实 Room 事务失败与生命周期/账号切换。登录和账号删除日志同时移除了访问令牌与网页会话。
- Android 实际打包曾使用预装 SDK 的另一张调试证书，仅验证恢复的 keystore 不足以确认 APK 的签名。现显式指定固定 keystore，并用 SDK 验证最终 APK 的密码学签名及固定指纹，再允许上传。新版 APK 已替换 v1.0.0，今后构建复用这张证书；从之前不同签名的调试 APK 首次切换需先保留未上传文件再重新安装。

照片备份、旧 SSO 和媒体功能正在 [Apple delivery 37910073177](https://github.com/felixbennettio/seafile-next/actions/runs/37910073177)发布；该记录仍在执行，尚不能写成新的 TestFlight 已可安装。后续 HEIC/HEIF→JPEG 的原规则选项在独立分支验证，默认关闭并保留旧格式记录；本机 79 项 Core 检查通过，iPhone 上传和格式切换回归尚未完成。

仍需补齐 iOS 系统后台/断点续传、合并 Motion Photo、SDoc/评论/Wiki/Office 专用体验、外部 Share 与 Files 自定义扩展、本地加密解密和完整语言覆盖。Windows 自动安装更新及 Linux 包更新仓库仍未建立。Mac Finder、开机启动/更新重启，Android 后台权限，以及各平台原功能的用户设备回归仍未全部验收。**不能宣称原版所有能力已全部迁移并验证。**
