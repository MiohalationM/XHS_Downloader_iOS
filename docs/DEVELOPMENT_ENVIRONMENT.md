# 开发、测试与打包说明

本文档面向本地源码构建、调试、测试与无签名 IPA 打包。

---

## 环境要求

- **操作系统与工具链**：macOS + Xcode（支持 **iOS 26.0 SDK**）
- **部署目标**：主应用与 `XHSShareExtension` 均声明 `IPHONEOS_DEPLOYMENT_TARGET = 17.0`
  - **iOS 17**：iPad 使用经典底部标签栏，组件自动回退至 Material 毛玻璃样式
  - **iOS 18+**：iPad 启用自适应侧边栏（`sidebarAdaptable`）与系统缩放转场辅助
  - **iOS 26+**：启用原生 Liquid Glass 材质与同心圆角
- **签名与 App Group**：
  - 真机签名调试前，请在 Xcode 中为主目标与 `ShareExtension` 配置相同的开发者 Team，并在两者的 `Info.plist`（`XHSAppGroupIdentifier`）与 `.entitlements` 中保持一致的 App Group 标识。
  - 若仅编译无签名真机包用于自签 / TrollStore 安装，无需配置开发者账号（使用 `CODE_SIGNING_ALLOWED=NO`）。

---

## 目录结构

| 路径 | 说明 |
| :--- | :--- |
| `XHS_Downloader_iOS/` | 主应用源码、资源与本地化（`Localizable.xcstrings`） |
| `ShareExtension/` | 系统分享扩展（`XHSShareExtension`） |
| `Shared/` | 主应用与分享扩展共用的链接解析与收件箱协议（`ImportInbox.swift`、`FeedbackPreference.swift`） |
| `XHS_Downloader_iOSTests/` | 单元测试与实况照片回归测试夹具（`Fixtures/`） |
| `XHS_Downloader_iOSUITests/` | 端到端 UI 自动化测试 |
| `scripts/ios-dev.sh` | 模拟器编译与定向测试辅助脚本 |
| `dist/` | 本地打包输出的 `.ipa`（Git 忽略）与 `.ipa.sha256` 校验清单 |

---

## 常用命令行构建（无需启动模拟器）

以下编译命令不会拉起 iOS 模拟器，适合快速验证与低内存 Mac 环境：

```sh
# 1. 无签名 Release arm64 真机构建
xcodebuild build \
  -project XHS_Downloader_iOS.xcodeproj \
  -scheme XHS_Downloader_iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO

# 2. 仅编译主应用与单元测试目标（不启动模拟器）
xcodebuild build-for-testing \
  -project XHS_Downloader_iOS.xcodeproj \
  -scheme XHS_Downloader_iOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

# 3. 仅编译 UI 测试目标
xcodebuild build-for-testing \
  -project XHS_Downloader_iOS.xcodeproj \
  -scheme XHS_Downloader_iOS-UI \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

---

## 模拟器调试与定向测试

项目提供辅助脚本 `./scripts/ios-dev.sh`，默认单模拟器串行执行并关闭失败诊断包采集，以降低内存与磁盘占用：

```sh
# 指定目标模拟器 UDID（可用 `xcrun simctl list devices available` 查看）
export XHS_SIMULATOR_UDID="<你的模拟器UDID>"

# 编译、安装并启动 Debug 应用
./scripts/ios-dev.sh run

# 运行默认定向测试（MediaKindDetectionTests）
./scripts/ios-dev.sh test

# 运行指定测试类或用例
./scripts/ios-dev.sh test ReviewRegressionTests
./scripts/ios-dev.sh test NoteLibraryTests

# 运行全部单元测试
./scripts/ios-dev.sh test all

# 运行指定 UI 测试用例
./scripts/ios-dev.sh ui XHS_Downloader_iOSUITests/testLaunchShowsTaskCenter
```

> 提示：测试输出默认写入 `.build/ios-dev/`（已加入 `.gitignore`）。`XHS_Downloader_iOS` scheme 仅启用单元测试，`XHS_Downloader_iOS-UI` scheme 仅启用 UI 测试。

---

## 打包无签名 `arm64` IPA

```sh
BUILD_DIR="$(mktemp -d /tmp/xhs-ipa-build.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

xcodebuild build \
  -project XHS_Downloader_iOS.xcodeproj \
  -scheme XHS_Downloader_iOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO

mkdir -p "$BUILD_DIR/stage/Payload" dist
cp -R "$BUILD_DIR/Build/Products/Release-iphoneos/小红书下载器.app" "$BUILD_DIR/stage/Payload/"
(cd "$BUILD_DIR/stage" && zip -qry "$OLDPWD/dist/XHS-Downloader-iOS-1.0-1-unsigned.ipa" Payload)
shasum -a 256 dist/XHS-Downloader-iOS-1.0-1-unsigned.ipa > dist/XHS-Downloader-iOS-1.0-1-unsigned.ipa.sha256
```
