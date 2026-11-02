# 栖间 · Qijian

面向 Mac、iPhone 和 iPad 的家庭管理应用，使用 SwiftUI、Mac Catalyst 和 Apple HomeKit。
以 2D 户型与 3D 空间展示家庭、房间和设备，并提供本机 HTTP MCP 接口。

当前源码版本：**0.12.4（42）**。本仓库发布源码，不提供签名安装包或 App Store 下载。

## 功能

- 家庭、房间、配件与场景管理，读取设备状态并按设备能力控制。
- 2D 户型与 3D 空间视图，家具摆放、房间描摹、设备定位与布局导入。
- 图片/PDF 户型底图；基于 JSON Schema 的 AI 布局导入与预览。
- iCloud / CloudKit 布局同步与共享。
- HomeKit 摄像头实时预览。
- 本机 Streamable HTTP MCP：10 个只读工具、16 个修改工具，读写凭据分离。

栖间通过 HomeKit 读取已经加入 Apple 家庭的设备，不直接调用 Home Assistant API。
使用 HA 摄像头时，需要通过 HA 的 HomeKit Bridge 将其加入 Apple 家庭，再由栖间访问。
[小米摄像头 HA 直连集成](https://github.com/bkcarlos/ha-xiaomi-camera-direct) 是独立项目。

## 源码结构

| 目录 | 内容 |
| --- | --- |
| `App/` | SwiftUI 界面、HomeKit、摄像头、CloudKit 与 HTTP 服务 |
| `Sources/HomeKitReadOnlyCore/` | 布局模型、导入校验、HTTP/MCP 协议与控制逻辑 |
| `Tests/` | 核心逻辑测试 |
| `Resources/` | 家具模型、预览图与品牌资源 |
| `docs/layout-json/` | 布局 Schema、样例与提示词 |
| `project.yml` | XcodeGen 项目定义 |

历史工程名及模块名仍为 `HomeKitReadOnly`；应用显示名是「栖间」。

## 测试与构建

需要 macOS、Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。
当前源码使用 Swift tools 5.9，iOS 最低目标为 16.0，Mac App 使用 Mac Catalyst。

```sh
git clone https://github.com/bkcarlos/qijian.git
cd qijian
swift test
xcodegen generate
open HomeKitReadOnly.xcodeproj
```

在 Xcode 中选择自己的开发团队，并配置 HomeKit、iCloud / CloudKit 能力。
源码保留原项目 Bundle ID 与 CloudKit 容器标识，**不包含证书、描述文件或云端数据**。
独立构建时应修改为自己有权限的标识：

1. `project.yml` 中的 `PRODUCT_BUNDLE_IDENTIFIER` 与签名团队。
2. `App/HomeKitReadOnly.entitlements` 和 `App/HomeKitMobile.entitlements` 中的 iCloud 容器。
3. `App/LayoutCloudSync.swift` 中的 `containerID`，与上述容器保持一致。

真机使用需要有效签名和系统 HomeKit 授权；CloudKit 功能需要相应容器和环境配置。
Release 默认使用 CloudKit Production，Debug 使用 Development。

只检查 Mac Catalyst 源码编译、无需签名时：

```sh
zsh scripts/build.sh CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

未签名构建只用于编译验证，不代表可以正常使用 HomeKit 或 CloudKit。

## 本机 MCP

在 App 的「MCP 与连接」页面启动服务，端点为 `http://127.0.0.1:18765/mcp`。
默认只读；修改操作还需要 App 内开启控制权限并使用独立控制令牌。

通过 App 导出凭据到本机 `work` 目录后，可运行：

```sh
python3 scripts/mcp_client.py tools
python3 scripts/mcp_client.py call list_rooms
```

令牌、家庭数据、户型图、运行日志和个人布局均不随源码发布。
服务仅监听本机，不提供公网部署或远程代理。

## 资源来源

家具模型来自 Kenney Furniture Pack，采用 CC0，保留在
[`Resources/Furniture/LICENSE-Kenney.txt`](Resources/Furniture/LICENSE-Kenney.txt)
及 [`SOURCE.txt`](Resources/Furniture/SOURCE.txt) 中的许可与来源说明。
