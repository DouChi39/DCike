# DCike iOS SwiftUI 迁移

## 设计依据（2026-10-27 阅读 Apple 官方文档）

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)

优先使用系统 TabView、NavigationStack、工具栏、Form、Toggle。玻璃用于导航和操作层，内容不叠加额外白底玻璃。使用语义色、SF Symbols、Dynamic Type 和系统辅助功能设置。iOS 26 使用系统 Liquid Glass；旧系统使用原生标准控件，不模拟折射或彩边。

## 架构

SwiftUI 页面通过本机 FlutterMethodChannel 调用既有 Dart/Rust 业务服务。插件脚本、图片鉴权与反混淆、ObjectBox、下载队列、云同步继续共用现有实现。界面无需 Flutter 平台视图，不传递无限高的滚动区域。

本机消息通道并非网络，不上传设置或登录信息。构建仍关闭远程诊断。版本标签保留 x，更新日志入口继续隐藏。

## 验证边界

Windows 不能运行 iOS 系统控件。静态检查与云端 Xcode 编译不代表真机交互全部验证；原生标签栏手势、图源登录、阅读恢复、云同步和深色模式需要 IPA 真机回归。迁移完成度以已接通的功能及测试结果为准。
