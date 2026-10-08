# Seafile Next

Seafile Next 整合 Android、iOS、macOS、Windows、Linux 和 Docker 服务端，支持域名子路径部署，并保留现有 Seafile 服务端的兼容性。

iOS 与 macOS 使用 Swift / SwiftUI 原生界面，在支持的系统上采用 Liquid Glass。支持多账户、密码与双重验证、OIDC / SAML 登录、资料库和目录浏览、上传下载、文件预览、文件及文件夹收藏，以及系统「文件」App / Finder 集成。macOS 提供桌面同步、开机启动设置和独立的非沙盒版本。

[下载最新版本](https://github.com/felixbennettio/seafile-next/releases/latest) · [原生 Apple 客户端功能与验证情况](docs/apple-client-review.md)

## 项目目录

| 目录 | 产品 |
| --- | --- |
| `android/` | Android 客户端 |
| `apple/` | 原生 iOS 与 macOS 客户端 |
| `ios-legacy/` | 原有 iOS 功能与扩展源码参考 |
| `desktop/` | Windows / Linux 同步客户端及 Qt 兼容客户端 |
| `sync/` | 桌面同步引擎 |
| `server/` | 服务端核心 |
| `web/` | 网页应用 |
| `docker/` | 服务端镜像与部署文件 |

统一服务端镜像：`ghcr.io/felixbennettio/seafile-next-server`。升级镜像时沿用已有数据卷和部署配置。

本仓库整合各产品的当前源码、功能与设计。各组件保留原有许可证和作者信息，源码来源版本记录在 [source-origins.json](docs/source-origins.json)。

## 发布

在 `docs/releases/v版本号.md` 写好功能说明后，运行 Actions 中的 **Publish Seafile Next release**。所有平台构建、回归检查和 Apple TestFlight 上传完成后，才会发布一个带下载包及校验值的统一 Release。发布失败时可填写同一源码版本的 `reuse_run`，复用原包。

Apple 签名使用固定的主 App、File Provider Identifier 和 App Group，复用加密保存的发布证书私钥；有效的 Profile 也会复用。签名缓存是仅管理员可见的内部草稿，不是公开的软件版本。只有证书接近到期或 Profile 失效时才更新，缓存读取或解密失败会中止发布。

原生 Apple 客户端仍处于测试阶段，未完成的功能及设备验证范围见上方功能评审。
