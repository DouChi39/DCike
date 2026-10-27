import SwiftUI
import UniformTypeIdentifiers
import WebKit
import Flutter

@available(iOS 16.0, *)
typealias DCikeSettingsPage = DCikeNativeSettings
@available(iOS 16.0, *)
typealias DCikePluginSettingsPage = DCikePluginSettings
@available(iOS 16.0, *)
typealias DCikePluginStorePage = DCikePluginStore

// Settings use system Form, Toggle, Picker and toolbar components. With the
// iOS 26 SDK their material and interaction come from the system, including
// increased contrast, reduced transparency and the user's color scheme.
@available(iOS 16.0, *)
struct DCikeNativeSettings: View {
  @EnvironmentObject private var model: DCikeNativeModel

  var body: some View {
    Form {
      Section("个性化") {
        NavigationLink { DCikePreferenceEditor(page: .appearance) } label: { Label("外观与启动", systemImage: "paintpalette") }
        NavigationLink { DCikePreferenceEditor(page: .reader) } label: { Label("阅读设置", systemImage: "book") }
        NavigationLink { DCikePreferenceEditor(page: .bookshelf) } label: { Label("书架设置", systemImage: "books.vertical") }
        NavigationLink { DCikePreferenceEditor(page: .behavior) } label: { Label("收藏与使用习惯", systemImage: "heart") }
      }
      Section("图源与数据") {
        NavigationLink { DCikeNativePlugins() } label: { Label("图源管理", systemImage: "puzzlepiece.extension") }
        NavigationLink { DCikeSyncSettings() } label: { Label("云端同步", systemImage: "arrow.triangle.2.circlepath.icloud") }
        NavigationLink { DCikeNativeBackup() } label: { Label("备份与恢复", systemImage: "externaldrive") }
        NavigationLink { DCikePreferenceEditor(page: .network) } label: { Label("内容与网络", systemImage: "network") }
        NavigationLink { DCikePreferenceEditor(page: .cache) } label: { Label("缓存管理", systemImage: "internaldrive") }
      }
      Section("隐私") {
        NavigationLink { DCikeAppLockSettings() } label: { Label("应用锁", systemImage: "lock") }
      }
      Section {
        NavigationLink { DCikeNativeAbout() } label: { Label("关于 DCike", systemImage: "info.circle") }
      }
    }
    .navigationTitle("设置")
  }
}

private func settingsMap(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func settingsRows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
private func settingsText(_ value: Any?, _ fallback: String = "") -> String {
  guard let value, !(value is NSNull) else { return fallback }
  return String(describing: value)
}
private func settingsValue(_ map: [String: Any], _ path: String) -> Any? {
  path.split(separator: ".").reduce(map as Any?) { result, part in settingsMap(result)[String(part)] }
}
private func settingsAssign(_ map: inout [String: Any], _ path: String, _ value: Any) {
  let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
  guard let first = parts.first else { return }
  if parts.count == 1 { map[first] = value }
  else { var child = settingsMap(map[first]); settingsAssign(&child, parts[1], value); map[first] = child }
}

enum PreferencePage: String {
  case appearance = "外观与启动", reader = "阅读设置", bookshelf = "书架设置"
  case behavior = "收藏与使用习惯", network = "内容与网络", cache = "缓存管理"
}
private enum PreferenceKind {
  case toggle, text, secret, number, multiline
  case choice([(String, String)])
}
private struct PreferenceField: Identifiable {
  let path: String
  let label: String
  let kind: PreferenceKind
  var hint: String = ""
  var id: String { path }
}
private struct PreferenceSection: Identifiable {
  let title: String
  let fields: [PreferenceField]
  var id: String { title }
}

@available(iOS 16.0, *)
struct DCikePreferenceEditor: View {
  @EnvironmentObject private var model: DCikeNativeModel
  let page: PreferencePage
  var comicSource: String? = nil
  var comicId: String? = nil
  var onComicUpdate: (([String: Any]) -> Void)? = nil
  @State private var draft: [String: Any] = [:]
  @State private var changedPaths: Set<String> = []
  @State private var loaded = false
  @State private var saving = false
  @State private var message: String?

  private var sections: [PreferenceSection] {
    switch page {
    case .appearance:
      return [PreferenceSection(title: "显示", fields: [
        .init(path: "themeMode", label: "外观", kind: .choice([("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")])),
        .init(path: "welcomePageNum", label: "启动页面", kind: .choice([("0", "首页"), ("1", "云收藏"), ("2", "书架"), ("3", "发现"), ("4", "设置")]))
      ])]
    case .behavior:
      return [PreferenceSection(title: "收藏", fields: [
        .init(path: "autoFollowOnCollect", label: "收藏自动追更", kind: .toggle, hint: "本地收藏漫画时，同时加入追更列表。"),
        .init(path: "autoCloudCollectOnCollect", label: "收藏自动云收藏", kind: .toggle, hint: "本地收藏时同步加入图源的云收藏；仅对已登录且支持云收藏的图源生效。"),
        .init(path: "clickCoverToStartReading", label: "点击封面直接阅读", kind: .toggle),
        .init(path: "leftHandModeEnabled", label: "左手模式", kind: .toggle),
        .init(path: "retryDownloadUntilSuccess", label: "下载失败自动重试", kind: .toggle)
      ])]
    case .bookshelf:
      return [PreferenceSection(title: "书架", fields: [
        .init(path: "bookshelfSetting.homePageIndex", label: "默认分类", kind: .choice([("0", "收藏"), ("1", "历史"), ("2", "下载"), ("3", "追更")])),
        .init(path: "bookshelfSetting.rememberFavoriteSort", label: "记住收藏排序", kind: .toggle),
        .init(path: "bookshelfSetting.rememberHistorySort", label: "记住历史排序", kind: .toggle),
        .init(path: "bookshelfSetting.rememberDownloadSort", label: "记住下载排序", kind: .toggle),
        .init(path: "bookshelfSetting.detailLayout", label: "显示详细信息", kind: .toggle),
        .init(path: "bookshelfSetting.reverseChapters", label: "章节倒序", kind: .toggle)
      ])]
    case .cache:
      return [PreferenceSection(title: "图片缓存", fields: [
        .init(path: "cacheSetting.autoCleanCache", label: "自动清理缓存", kind: .toggle),
        .init(path: "cacheSetting.cacheSizeLimit", label: "缓存上限", kind: .choice([("536870912", "512 MB"), ("1073741824", "1 GB"), ("2147483648", "2 GB"), ("4294967296", "4 GB")])),
        .init(path: "needCleanCache", label: "下次启动清理缓存", kind: .toggle)
      ])]
    case .network:
      return [PreferenceSection(title: "内容", fields: [
        .init(path: "maskedKeywords", label: "屏蔽关键词", kind: .multiline, hint: "每行一个关键词。"),
        .init(path: "chineseConvertMode", label: "简繁转换", kind: .choice([("off", "关闭"), ("simplified", "转为简体"), ("traditional", "转为繁体")]))
      ]), PreferenceSection(title: "代理", fields: [
        .init(path: "proxySetting.enabled", label: "启用代理", kind: .toggle),
        .init(path: "proxySetting.type", label: "代理协议", kind: .choice([("http", "HTTP"), ("socks5", "SOCKS5")])),
        .init(path: "proxySetting.address", label: "代理地址", kind: .text, hint: "例如 http://127.0.0.1:7890")
      ])]
    case .reader:
      return [PreferenceSection(title: "翻页", fields: [
        .init(path: "readSetting.readMode", label: "阅读模式", kind: .choice([("0", "竖向连续"), ("1", "从左向右翻页"), ("2", "从右向左翻页")])),
        .init(path: "readSetting.reverseHorizontalPageTurn", label: "横向从右向左翻页", kind: .toggle),
        .init(path: "readSetting.tapPageTurnMode", label: "点击翻页区域", kind: .choice([("fullScreen", "全屏"), ("leftHand", "左手"), ("rightHand", "右手")])),
        .init(path: "readSetting.tapPageTurnInWebtoon", label: "连续阅读时点击翻页", kind: .toggle),
        .init(path: "readSetting.noAnimation", label: "关闭翻页动画", kind: .toggle),
        .init(path: "readSetting.doubleTapZoom", label: "双击放大", kind: .toggle),
        .init(path: "readSetting.doubleTapOpenMenu", label: "双击打开菜单", kind: .toggle)
      ]), PreferenceSection(title: "显示", fields: [
        .init(path: "readSetting.readerBackgroundMode", label: "阅读背景", kind: .choice([("auto", "跟随外观"), ("black", "黑色"), ("white", "白色"), ("grey", "灰色")])),
        .init(path: "readSetting.readFilterEnabled", label: "阅读滤镜", kind: .toggle),
        .init(path: "readSetting.readFilterOpacityPercent", label: "滤镜强度（0–100）", kind: .number),
        .init(path: "readSetting.landscapeReader", label: "横屏阅读", kind: .toggle),
        .init(path: "readSetting.doublePageMode", label: "双页模式", kind: .toggle),
        .init(path: "readSetting.doublePageSeamless", label: "双页无缝拼接", kind: .toggle),
        .init(path: "readSetting.doublePageLeadingBlank", label: "双页首张留白", kind: .toggle),
        .init(path: "readSetting.sidePaddingEnabled", label: "左右留白", kind: .toggle),
        .init(path: "readSetting.sidePaddingPercent", label: "留白比例（%）", kind: .number)
      ]), PreferenceSection(title: "墨水屏", fields: [
        .init(path: "readSetting.einkOptimization", label: "墨水屏优化", kind: .toggle),
        .init(path: "readSetting.einkDelayMs", label: "翻页延迟（毫秒）", kind: .number)
      ]), PreferenceSection(title: "预加载与自动滚动", fields: [
        .init(path: "readSetting.preloadImageCount", label: "预加载图片数", kind: .number),
        .init(path: "readSetting.preloadChapterCount", label: "预加载章节数", kind: .number),
        .init(path: "readSetting.autoScroll", label: "自动滚动", kind: .toggle),
        .init(path: "readSetting.autoScrollSmooth", label: "平滑自动滚动", kind: .toggle),
        .init(path: "readSetting.autoScrollHidePauseButton", label: "隐藏暂停按钮", kind: .toggle),
        .init(path: "readSetting.autoScrollColumnIntervalMs", label: "滚动间隔（毫秒）", kind: .number),
        .init(path: "readSetting.autoScrollPageIntervalMs", label: "翻页间隔（毫秒）", kind: .number),
        .init(path: "readSetting.autoScrollColumnDistancePercent", label: "每次滚动距离（%）", kind: .number)
      ]), PreferenceSection(title: "阅读信息", fields: [
        .init(path: "readSetting.pageInfoShowPage", label: "显示页码", kind: .toggle),
        .init(path: "readSetting.pageInfoShowNetwork", label: "显示网络状态", kind: .toggle),
        .init(path: "readSetting.pageInfoShowBattery", label: "显示电量", kind: .toggle),
        .init(path: "readSetting.pageInfoShowTime", label: "显示时间", kind: .toggle),
        .init(path: "readSetting.pageInfoVerticalPosition", label: "垂直位置", kind: .choice([("top", "顶部"), ("bottom", "底部")])),
        .init(path: "readSetting.pageInfoHorizontalPosition", label: "水平位置", kind: .choice([("left", "左侧"), ("center", "居中"), ("right", "右侧")])),
        .init(path: "readSetting.pageInfoTopInStatusBar", label: "顶部信息放入状态栏", kind: .toggle),
        .init(path: "readSetting.pageInfoEdgePadding", label: "边缘间距", kind: .number),
        .init(path: "readSetting.pageInfoOpacityPercent", label: "不透明度（%）", kind: .number),
        .init(path: "readSetting.pageInfoFontSize", label: "文字大小", kind: .number)
      ])]
    }
  }

  var body: some View {
    Form {
      ForEach(sections) { section in
        Section(section.title) { ForEach(section.fields) { field in preferenceRow(field) } }
      }
      if comicSource != nil {
        Section { Button("恢复跟随全局设置", role: .destructive) { resetComicSettings() } }
      }
    }
    .navigationTitle(comicSource == nil ? page.rawValue : "本漫画设置")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { ToolbarItem(placement: .confirmationAction) {
      Button("保存") { save() }.disabled(!loaded || saving)
    } }
    .task { if !loaded { await loadDraft() } }
    .alert("设置", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
  }

  @ViewBuilder private func preferenceRow(_ field: PreferenceField) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      switch field.kind {
      case .toggle:
        Toggle(isOn: Binding(get: { settingsValue(draft, field.path) as? Bool ?? false }, set: { assign(field.path, $0) })) {
          if field.path == "autoCloudCollectOnCollect" { Label(field.label, systemImage: "cloud") }
          else if field.path == "autoFollowOnCollect" { Label(field.label, systemImage: "bell") }
          else { Text(field.label) }
        }
      case .choice(let options):
        Picker(field.label, selection: Binding(get: { settingsText(settingsValue(draft, field.path)) }, set: { value in
          let previous = settingsValue(draft, field.path)
          assign(field.path, previous is NSNumber ? (Int(value) ?? 0) as Any : value)
        })) { ForEach(options.indices, id: \.self) { i in Text(options[i].1).tag(options[i].0) } }
      case .multiline:
        Text(field.label)
        TextEditor(text: Binding(get: { (settingsValue(draft, field.path) as? [String] ?? []).joined(separator: "\n") }, set: { settingsAssign(&draft, field.path, $0.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) })).frame(minHeight: 110)
      case .secret:
        SecureField(field.label, text: textBinding(field.path)).textInputAutocapitalization(.never).autocorrectionDisabled()
      case .number:
        HStack { Text(field.label); Spacer(); TextField(field.label, text: Binding(get: { settingsText(settingsValue(draft, field.path)) }, set: { if let v = Int($0), v >= 0 { assign(field.path, v) } })).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(maxWidth: 110) }
      case .text:
        TextField(field.label, text: textBinding(field.path)).textInputAutocapitalization(.never).autocorrectionDisabled()
      }
      let hint = field.hint.isEmpty ? preferenceHint(field.path) : field.hint
      if !hint.isEmpty { Text(hint).font(.footnote).foregroundStyle(.secondary) }
    }
  }
  private func preferenceHint(_ path: String) -> String {
    switch path {
    case "themeMode": return "选择浅色、深色或跟随系统外观。"
    case "welcomePageNum": return "选择启动后首先显示的页面。"
    case "clickCoverToStartReading": return "点击漫画封面时直接开始阅读。"
    case "leftHandModeEnabled": return "调整界面操作位置以方便左手使用。"
    case "retryDownloadUntilSuccess": return "下载失败时自动重试。"
    case "bookshelfSetting.homePageIndex": return "选择打开书架时显示的分类。"
    case "bookshelfSetting.rememberFavoriteSort": return "保留收藏列表上次使用的排序方式。"
    case "bookshelfSetting.rememberHistorySort": return "保留历史记录上次使用的排序方式。"
    case "bookshelfSetting.rememberDownloadSort": return "保留下载列表上次使用的排序方式。"
    case "bookshelfSetting.detailLayout": return "在书架中显示更多漫画信息。"
    case "bookshelfSetting.reverseChapters": return "倒序显示章节。"
    case "cacheSetting.autoCleanCache": return "根据缓存上限自动清理缓存。"
    case "cacheSetting.cacheSizeLimit": return "设置图片缓存的大小上限。"
    case "needCleanCache": return "下次启动时清理图片缓存。"
    case "chineseConvertMode": return "选择漫画文字的简繁转换方式。"
    case "proxySetting.enabled": return "通过设置的代理访问网络。"
    case "proxySetting.type": return "选择代理服务器使用的协议。"
    case "readSetting.readMode": return "选择连续滚动或横向翻页。"
    case "readSetting.reverseHorizontalPageTurn": return "调整横向阅读的翻页方向。"
    case "readSetting.tapPageTurnMode": return "选择点击屏幕翻页的区域。"
    case "readSetting.tapPageTurnInWebtoon": return "连续阅读时也可点击屏幕翻页。"
    case "readSetting.noAnimation": return "翻页时不显示动画。"
    case "readSetting.doubleTapZoom": return "双击阅读页面以放大图片。"
    case "readSetting.doubleTapOpenMenu": return "双击阅读页面以打开菜单。"
    case "readSetting.readerBackgroundMode": return "选择阅读页面的背景颜色。"
    case "readSetting.readFilterEnabled": return "在阅读图片上应用滤镜。"
    case "readSetting.readFilterOpacityPercent": return "调整阅读滤镜的强度。"
    case "readSetting.landscapeReader": return "阅读时使用横屏显示。"
    case "readSetting.doublePageMode": return "同时显示两页漫画。"
    case "readSetting.doublePageSeamless": return "减少双页之间的间隙。"
    case "readSetting.doublePageLeadingBlank": return "双页阅读时在开头留出空白页。"
    case "readSetting.sidePaddingEnabled": return "在阅读页面左右留出空白。"
    case "readSetting.sidePaddingPercent": return "调整左右留白的比例。"
    case "readSetting.einkOptimization": return "横向翻页时短暂显示白色画面，减少墨水屏残影。"
    case "readSetting.einkDelayMs": return "设置横向翻页白色画面的显示时间，范围为 50 至 500 毫秒。"
    case "readSetting.preloadImageCount": return "提前加载指定数量的图片。"
    case "readSetting.preloadChapterCount": return "提前加载指定数量的章节。"
    case "readSetting.autoScroll": return "阅读时自动滚动或翻页。"
    case "readSetting.autoScrollSmooth": return "使用平滑的自动滚动。"
    case "readSetting.autoScrollHidePauseButton": return "自动滚动时隐藏暂停按钮。"
    case "readSetting.autoScrollColumnIntervalMs": return "设置连续阅读自动滚动的间隔。"
    case "readSetting.autoScrollPageIntervalMs": return "设置自动翻页的间隔。"
    case "readSetting.autoScrollColumnDistancePercent": return "设置每次自动滚动的距离。"
    case "readSetting.pageInfoShowPage": return "在阅读页面显示当前页码。"
    case "readSetting.pageInfoShowNetwork": return "在阅读页面显示网络状态。"
    case "readSetting.pageInfoShowBattery": return "在阅读页面显示电量。"
    case "readSetting.pageInfoShowTime": return "在阅读页面显示时间。"
    case "readSetting.pageInfoVerticalPosition": return "选择阅读信息在顶部或底部显示。"
    case "readSetting.pageInfoHorizontalPosition": return "选择阅读信息的水平位置。"
    case "readSetting.pageInfoTopInStatusBar": return "将顶部阅读信息放入状态栏区域。"
    case "readSetting.pageInfoEdgePadding": return "调整阅读信息与屏幕边缘的间距。"
    case "readSetting.pageInfoOpacityPercent": return "调整阅读信息的不透明度。"
    case "readSetting.pageInfoFontSize": return "调整阅读信息的文字大小。"
    default: return ""
    }
  }
  private func textBinding(_ key: String) -> Binding<String> { Binding(get: { settingsText(settingsValue(draft, key)) }, set: { settingsAssign(&draft, key, $0) }) }
  private func assign(_ path: String, _ value: Any) { settingsAssign(&draft, path, value); changedPaths.insert(path) }
  private func loadDraft() async {
    guard let comicSource, let comicId else { draft = model.settings; loaded = true; return }
    do {
      let result = settingsMap(try await model.request("comicReadSettings", ["source": comicSource, "comicId": comicId]))
      draft = ["readSetting": settingsMap(result["effective"])]; onComicUpdate?(result); loaded = true
    } catch { message = error.localizedDescription }
  }
  private func resetComicSettings() {
    guard let comicSource, let comicId else { return }
    saving = true
    Task {
      do {
        let result = settingsMap(try await model.request("comicReadSettings", ["source": comicSource, "comicId": comicId, "reset": true]))
        draft = ["readSetting": settingsMap(result["effective"])]; changedPaths = []; onComicUpdate?(result); message = "已恢复跟随全局设置"
      } catch { message = error.localizedDescription }
      saving = false
    }
  }
  private func save() {
    saving = true
    var patch: [String: Any] = [:]
    for field in sections.flatMap(\.fields) where comicSource == nil || changedPaths.contains(field.path) { if let value = settingsValue(draft, field.path) { settingsAssign(&patch, field.path, value) } }
    Task {
      do {
        if let comicSource, let comicId {
          let result = settingsMap(try await model.request("comicReadSettings", ["source": comicSource, "comicId": comicId, "patch": settingsMap(patch["readSetting"])]))
          draft = ["readSetting": settingsMap(result["effective"])]; changedPaths = []; onComicUpdate?(result)
        } else { _ = try await model.request("settings", ["patch": patch]); await model.refresh() }
        message = "已保存"
      }
      catch { message = error.localizedDescription }
      saving = false
    }
  }
}

@available(iOS 16.0, *)
struct DCikeSyncSettings: View {
  @EnvironmentObject private var model: DCikeNativeModel
  @State private var draft: [String: Any] = [:]
  @State private var busy = false
  @State private var message: String?
  @State private var confirmDownload = false
  @State private var confirmClear = false
  private var kind: String { settingsText(draft["syncServiceType"], "none") }

  var body: some View {
    Form {
      Section("同步服务") {
        Picker("服务", selection: bind("syncServiceType", fallback: "none")) { Text("关闭").tag("none"); Text("WebDAV").tag("webdav"); Text("S3").tag("s3") }
      }
      if kind == "webdav" {
        Section("WebDAV") {
          TextField("服务器地址", text: bind("webdavSetting.host")).keyboardType(.URL)
          TextField("用户名", text: bind("webdavSetting.username"))
          SecureField("密码", text: bind("webdavSetting.password"))
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
      }
      if kind == "s3" {
        s3Section
      }
      if kind != "none" {
        Section {
          Button("测试连接") { testConnection() }
          Button("删除配置", role: .destructive) { confirmClear = true }
        } footer: { Text("删除配置只清除当前服务的本地连接信息，不会删除云端数据。") }
        Section("同步内容") {
          syncToggle("同步应用设置", "同步外观、书架和阅读设置。", "syncSettings")
          syncToggle("同步图源配置", "同步图源配置，可能包含图源登录信息。", "syncPlugins")
          syncToggle("自动同步", "自动同步本地和云端数据。", "autoSync", fallback: true)
          syncToggle("显示同步通知", "显示同步操作的结果通知。", "syncNotify", fallback: true)
        }
        Section("手动同步") {
          Button("上传本地数据") { synchronize("upload") }
          Button("从云端恢复") { confirmDownload = true }
        } footer: { Text("服务器信息和密码只保存在你的应用中；上传图源配置可能包含该图源的登录信息。") }
      }
    }
    .navigationTitle("云端同步").navigationBarTitleDisplayMode(.inline)
    .disabled(busy)
    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { save() } } }
    .task { draft = settingsMap(model.settings["syncSetting"]) }
    .confirmationDialog("从云端恢复数据？", isPresented: $confirmDownload, titleVisibility: .visible) { Button("恢复云端数据", role: .destructive) { synchronize("download") } } message: { Text("云端数据将合并或替换对应的本地记录，请先保留备份。") }
    .confirmationDialog("删除当前服务的配置？", isPresented: $confirmClear, titleVisibility: .visible) { Button("删除配置", role: .destructive) { clearConfiguration() } } message: { Text("只删除本机保存的连接信息，不会删除云端数据。") }
    .alert("同步", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
  }
  private var s3Section: some View {
    Section("S3") {
      TextField("Endpoint", text: bind("s3Setting.endpoint")).keyboardType(.URL)
      TextField("Bucket", text: bind("s3Setting.bucket"))
      TextField("Region", text: bind("s3Setting.region"))
      SecureField("Access Key", text: bind("s3Setting.accessKey"))
      SecureField("Secret Key", text: bind("s3Setting.secretKey"))
      TextField("端口（0 为默认）", text: s3PortBinding).keyboardType(.numberPad)
      Toggle("使用 HTTPS", isOn: toggle("s3Setting.useSSL", fallback: true))
      Toggle("Path-style 地址", isOn: toggle("s3Setting.pathStyle"))
    }.textInputAutocapitalization(.never).autocorrectionDisabled()
  }
  private var s3PortBinding: Binding<String> {
    Binding(
      get: { settingsText(settingsValue(draft, "s3Setting.port"), "0") },
      set: { if let port = Int($0), (0...65535).contains(port) { settingsAssign(&draft, "s3Setting.port", port) } }
    )
  }
  private func bind(_ key: String, fallback: String = "") -> Binding<String> { Binding(get: { settingsText(settingsValue(draft, key), fallback) }, set: { settingsAssign(&draft, key, $0) }) }
  private func toggle(_ key: String, fallback: Bool = false) -> Binding<Bool> { Binding(get: { settingsValue(draft, key) as? Bool ?? fallback }, set: { settingsAssign(&draft, key, $0) }) }
  private func syncToggle(_ label: String, _ hint: String, _ key: String, fallback: Bool = false) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(label, isOn: toggle(key, fallback: fallback))
      Text(hint).font(.footnote).foregroundStyle(.secondary)
    }
  }
  private func persist() async throws { _ = try await model.request("settings", ["patch": ["syncSetting": draft]]); await model.refresh() }
  private func save() { busy = true; Task { do { try await persist(); message = "已保存" } catch { message = error.localizedDescription }; busy = false } }
  private func testConnection() { busy = true; Task { do { _ = try await model.request("testSyncConnection", ["syncSetting": draft]); message = "连接成功" } catch { message = error.localizedDescription }; busy = false } }
  private func clearConfiguration() {
    if kind == "webdav" { draft["webdavSetting"] = ["host": "", "username": "", "password": ""] }
    else if kind == "s3" { draft["s3Setting"] = ["endpoint": "", "bucket": "", "region": "", "accessKey": "", "secretKey": "", "port": 0, "useSSL": true, "pathStyle": false] }
    busy = true
    Task { do { try await persist(); draft = settingsMap(model.settings["syncSetting"]); message = "配置已删除" } catch { message = error.localizedDescription }; busy = false }
  }
  private func synchronize(_ direction: String) { busy = true; Task { do { try await persist(); _ = try await model.request("sync", ["direction": direction]); message = "同步完成" } catch { message = error.localizedDescription }; busy = false } }
}

@available(iOS 16.0, *)
struct DCikeNativePlugins: View {
  @EnvironmentObject private var model: DCikeNativeModel
  var body: some View {
    List {
      Section {
        NavigationLink { DCikePluginStore() } label: { Label("添加图源", systemImage: "plus.circle") }
      }
      Section("已安装") {
        ForEach(model.plugins.indices, id: \.self) { index in
          let p = model.plugins[index]
          NavigationLink { DCikePluginSettings(source: settingsText(p["id"]), name: settingsText(p["name"])) } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(settingsText(p["name"]))
              Text("\(settingsText(p["version"])) · \((p["enabled"] as? Bool ?? false) ? ((p["ready"] as? Bool ?? false) ? "已启用" : "初始化中") : "已停用")").font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }.navigationTitle("图源管理").refreshable { await model.refresh() }
  }
}

@available(iOS 16.0, *)
struct DCikePluginSettings: View {
  @EnvironmentObject private var model: DCikeNativeModel
  let source: String
  var name: String = "图源设置"
  @State private var sections: [[String: Any]] = []
  @State private var values: [String: Any] = [:]
  @State private var actions: [[String: Any]] = []
  @State private var user: [String: Any] = [:]
  @State private var canLogin = false
  @State private var loginTitle = "登录"
  @State private var loading = true
  @State private var message: String?
  @State private var webFlow: SettingsWebFlow?
  private var enabled: Bool { model.plugins.first { settingsText($0["id"]) == source }?["enabled"] as? Bool ?? true }

  var body: some View {
    Form {
      Section {
        Toggle("启用图源", isOn: Binding(get: { enabled }, set: { value in run { _ = try await model.request("pluginEnabled", ["source": source, "value": value]); await model.refresh() } }))
        if canLogin { NavigationLink(loginTitle) { DCikePluginLogin(source: source) } }
        ForEach((user["lines"] as? [String] ?? []).indices, id: \.self) { i in Text((user["lines"] as? [String] ?? [])[i]).foregroundStyle(.secondary) }
      }
      if loading { ProgressView("正在读取图源设置") }
      ForEach(sections.indices, id: \.self) { i in
        Section(settingsText(sections[i]["title"])) {
          let fields = settingsRows(sections[i]["fields"])
          ForEach(fields.indices, id: \.self) { j in
            DCikePluginSettingField(field: fields[j], value: values[settingsText(fields[j]["key"])]) { newValue in commit(fields[j], newValue) }
          }
        }
      }
      if !actions.isEmpty {
        Section("操作") {
          ForEach(actions.indices, id: \.self) { i in
            Button(settingsText(actions[i]["title"], "执行操作")) { runAction(actions[i]) }
          }
        }
      }
    }
    .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .refreshable { await load() }
    .sheet(item: $webFlow, onDismiss: { Task { await load() } }) { flow in
      NavigationStack { DCikePluginWebLogin(source: source, flow: flow).environmentObject(model) }
    }
    .alert("图源", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
  }
  private func load() async {
    loading = true
    do {
      let response = try await model.plugin(source, "getSettingsBundle")
      let data = settingsMap(response["data"])
      sections = settingsRows(settingsMap(response["scheme"])["sections"])
      values = settingsMap(data["values"])
      canLogin = data["canLogin"] as? Bool ?? false
      loginTitle = settingsText(data["loginTitle"], "登录")
      if loginTitle.isEmpty { loginTitle = "登录" }
      if data["canLogin"] == nil { canLogin = (try? await model.plugin(source, "getLoginBundle")) != nil }
      if data["canShowUserInfo"] as? Bool == true { user = settingsMap((try? await model.plugin(source, "getUserInfoBundle"))?["data"]) }
      let capability = try? await model.plugin(source, "getCapabilitiesBundle")
      actions = settingsRows(settingsMap(capability?["scheme"])["actions"]).filter { settingsText($0["fnPath"]) != "dumpRuntimeInfo" }
    } catch { message = error.localizedDescription }
    loading = false
  }
  private func commit(_ field: [String: Any], _ value: Any) {
    let key = settingsText(field["key"])
    run {
      let result = settingsMap(try await model.request("pluginField", ["source": source, "field": field, "value": value]))
      values[key] = value
      if let flow = SettingsWebFlow(result) { webFlow = flow }
    }
  }
  private func runAction(_ action: [String: Any]) {
    let fn = settingsText(action["fnPath"])
    guard !fn.isEmpty else { return }
    run {
      let response = try await model.plugin(source, fn)
      if let flow = SettingsWebFlow(response) { webFlow = flow }
      else { message = settingsText(response["message"], settingsText(settingsMap(response["data"])["message"], "操作完成")); await load() }
    }
  }
  private func run(_ action: @escaping () async throws -> Void) { Task { do { try await action() } catch { message = error.localizedDescription } } }
}

private struct SettingsOption: Identifiable {
  let label: String
  let value: Any
  var id: String { settingsText(value) }
}
private func settingsOptions(_ raw: Any?) -> [SettingsOption] {
  if let options = raw as? [Any] { return options.map { item in
    if let m = item as? [String: Any] { return SettingsOption(label: settingsText(m["label"], settingsText(m["name"], settingsText(m["value"]))), value: m["value"] ?? m["id"] ?? "") }
    return SettingsOption(label: settingsText(item), value: item)
  } }
  return settingsMap(raw).keys.sorted().map { key in SettingsOption(label: settingsText(settingsMap(raw)[key]), value: key) }
}

@available(iOS 16.0, *)
private struct DCikePluginSettingField: View {
  let field: [String: Any]
  let value: Any?
  let commit: (Any) -> Void
  @State private var text = ""
  private var kind: String { settingsText(field["kind"], "text") }
  private var label: String { settingsText(field["label"], settingsText(field["key"])) }
  private var options: [SettingsOption] { settingsOptions(field["options"]) }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if kind == "switch" {
        Toggle(label, isOn: Binding(get: { value as? Bool ?? false }, set: { commit($0) }))
      } else if kind == "select" || kind == "choice" {
        Picker(label, selection: Binding(get: { settingsText(value) }, set: { selected in if let item = options.first(where: { $0.id == selected }) { commit(item.value) } })) {
          ForEach(options) { option in Text(option.label).tag(option.id) }
        }
      } else if kind == "multiChoice" {
        DisclosureGroup(label) {
          ForEach(options) { option in
            let selected = (value as? [Any] ?? []).map { settingsText($0) }
            Toggle(option.label, isOn: Binding(get: { selected.contains(option.id) }, set: { state in
              var next = selected.filter { $0 != option.id }; if state { next.append(option.id) }; commit(next)
            }))
          }
        }
      } else {
        Text(label).font(.subheadline).foregroundStyle(.secondary)
        HStack {
          if kind == "password" { SecureField(label, text: $text) }
          else { TextField(label, text: $text) }
          Button("保存") { commit(text) }.disabled(text == settingsText(value))
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
      }
      let subtitle = settingsText(field["description"], settingsText(field["help"]))
      if !subtitle.isEmpty { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
    }.onAppear { text = settingsText(value) }.onChange(of: settingsText(value)) { text = $0 }
  }
}

@available(iOS 16.0, *)
struct DCikePluginLogin: View {
  @EnvironmentObject private var model: DCikeNativeModel
  @Environment(\.dismiss) private var dismiss
  let source: String
  @State private var fields: [[String: Any]] = []
  @State private var values: [String: String] = [:]
  @State private var captcha: [String: Data] = [:]
  @State private var submitFn = ""
  @State private var busy = false
  @State private var message: String?
  @State private var webFlow: SettingsWebFlow?
  var body: some View {
    Form {
      if fields.isEmpty && busy { ProgressView("读取登录方式") }
      Section {
        ForEach(fields.indices, id: \.self) { i in
          let field = fields[i]
          let key = settingsText(field["key"])
          let label = settingsText(field["label"], key)
          VStack(alignment: .leading, spacing: 8) {
            if settingsText(field["kind"]) == "password" { SecureField(label, text: fieldBinding(key)) }
            else { TextField(label, text: fieldBinding(key)).keyboardType(settingsText(field["kind"]) == "email" ? .emailAddress : .default) }
            if settingsText(field["kind"]) == "captcha-image" {
              if let bytes = captcha[key], let image = UIImage(data: bytes) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 100).accessibilityLabel("验证码") }
              Button(settingsText(settingsMap(field["captcha"])["refreshText"], "刷新验证码")) { Task { await fetchCaptcha(field) } }
            }
            if let help = field["help"] as? String, !help.isEmpty { Text(help).font(.footnote).foregroundStyle(.secondary) }
          }
        }
      }.textInputAutocapitalization(.never).autocorrectionDisabled()
      if !submitFn.isEmpty { Section { Button("登录") { submit() }.disabled(busy) } }
      if !busy && fields.isEmpty && webFlow == nil { Text("此图源未提供账号表单。请返回图源设置，使用图源提供的登录入口。").foregroundStyle(.secondary) }
    }
    .navigationTitle("登录").navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .sheet(item: $webFlow) { flow in NavigationStack { DCikePluginWebLogin(source: source, flow: flow).environmentObject(model) } }
    .alert("登录", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
  }
  private func fieldBinding(_ key: String) -> Binding<String> { Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }) }
  private func load() async {
    busy = true
    do {
      let response = try await model.plugin(source, "getLoginBundle")
      if let flow = SettingsWebFlow(response) { webFlow = flow }
      let scheme = settingsMap(response["scheme"])
      let data = settingsMap(response["data"])
      fields = settingsRows(scheme["fields"])
      submitFn = settingsText(settingsMap(scheme["action"])["fnPath"], settingsText(scheme["submitFnPath"], settingsText(scheme["fnPath"])))
      let initial = data.merging(settingsMap(data["values"])) { _, value in value }
      for field in fields { let key = settingsText(field["key"]); values[key] = settingsText(initial[key]) }
      for field in fields where settingsText(field["kind"]) == "captcha-image" { await fetchCaptcha(field) }
    } catch { message = error.localizedDescription }
    busy = false
  }
  private func fetchCaptcha(_ field: [String: Any]) async {
    let fn = settingsText(settingsMap(field["captcha"])["fetchFnPath"])
    guard !fn.isEmpty else { return }
    do {
      let response = try await model.plugin(source, fn)
      let payload = response.merging(settingsMap(response["data"])) { _, value in value }
      var raw = settingsText(payload["imageBase64"], settingsText(payload["image"]))
      if raw.hasPrefix("data:"), let comma = raw.firstIndex(of: ",") { raw = String(raw[raw.index(after: comma)...]) }
      guard let bytes = Data(base64Encoded: raw, options: .ignoreUnknownCharacters), !bytes.isEmpty else { throw NSError(domain: "DCike", code: 1, userInfo: [NSLocalizedDescriptionKey: "验证码图片读取失败"]) }
      captcha[settingsText(field["key"])] = bytes
    } catch { message = error.localizedDescription }
  }
  private func submit() {
    for field in fields where field["required"] as? Bool == true {
      if (values[settingsText(field["key"])] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { message = "请填写\(settingsText(field["label"], settingsText(field["key"])))"; return }
    }
    busy = true
    Task {
      do {
        var core: [String: Any] = values; core["values"] = values
        let response = try await model.plugin(source, submitFn, core)
        if let flow = SettingsWebFlow(response) { webFlow = flow }
        else { await model.refresh(); values.removeAll(); dismiss() }
      } catch {
        message = error.localizedDescription
        for field in fields where settingsText(field["kind"]) == "captcha-image" { values[settingsText(field["key"])] = ""; await fetchCaptcha(field) }
      }
      busy = false
    }
  }
}

private struct SettingsWebFlow: Identifiable {
  let id = UUID()
  let url: URL
  let title: String
  let callback: String
  let redirect: URL?
  let ignored: Set<String>
  init?(_ response: [String: Any]) {
    let data = response.merging(settingsMap(response["data"])) { _, value in value }
    let payload = settingsMap(settingsMap(data["action"])["payload"])
    guard let url = URL(string: settingsText(data["openUrl"], settingsText(payload["url"]))), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
    let callback = settingsText(data["setCookieFnPath"])
    guard !callback.isEmpty else { return nil }
    self.url = url; self.callback = callback
    title = settingsText(data["openTitle"], settingsText(payload["title"], "网页登录"))
    redirect = URL(string: settingsText(data["redirectWatchUrl"]))
    ignored = Set((data["ignoreCookieNames"] as? [String] ?? []).map { $0.lowercased() } + ["cf_clearance"])
  }
}

@available(iOS 16.0, *)
private struct DCikePluginWebLogin: View {
  @EnvironmentObject private var model: DCikeNativeModel
  @Environment(\.dismiss) private var dismiss
  let source: String
  let flow: SettingsWebFlow
  @State private var message: String?
  @State private var currentURL: URL?
  @State private var busy = false
  @StateObject private var session = SettingsWebSession()
  var body: some View {
    SettingsLoginWebView(session: session, url: flow.url, visited: { currentURL = $0 })
      .navigationTitle(flow.title).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("完成登录") { finish() }.disabled(busy) }
      }
      .alert("网页登录", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
  }
  private func finish() {
    if let redirect = flow.redirect {
      guard let current = currentURL,
        current.host?.lowercased() == redirect.host?.lowercased(),
        current.path.hasPrefix(redirect.path) else {
        message = "请先完成网站登录，再点完成登录。"
        return
      }
    }
    busy = true
    session.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
      let target = flow.redirect ?? currentURL ?? flow.url
      let host = (target.host ?? "").lowercased()
      let path = target.path.isEmpty ? "/" : target.path
      let relevant = cookies.filter { cookie in
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let domainMatches = host == domain || host.hasSuffix("." + domain)
        let pathMatches = path == cookie.path || (path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || path.dropFirst(cookie.path.count).hasPrefix("/")))
        return domainMatches && pathMatches && (!cookie.isSecure || target.scheme == "https") && !flow.ignored.contains(cookie.name.lowercased()) && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
      }
      let cookie = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      guard !cookie.isEmpty else { message = "没有读取到登录状态，请先完成网站登录。"; busy = false; return }
      Task {
        do { _ = try await model.plugin(source, flow.callback, ["cookie": cookie, "url": target.absoluteString]); await model.refresh(); dismiss() }
        catch { message = error.localizedDescription }
        busy = false
      }
    }
  }
}

@MainActor
private final class SettingsWebSession: ObservableObject {
  let webView: WKWebView
  init() {
    let configuration = WKWebViewConfiguration()
    // Each login sheet has an isolated session. Cookies are returned only to
    // the requesting plugin and never printed or uploaded as diagnostics.
    configuration.websiteDataStore = .nonPersistent()
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.allowsBackForwardNavigationGestures = true
  }
}
private struct SettingsLoginWebView: UIViewRepresentable {
  let session: SettingsWebSession
  let url: URL
  let visited: (URL) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(visited: visited) }
  func makeUIView(context: Context) -> WKWebView { session.webView.navigationDelegate = context.coordinator; session.webView.load(URLRequest(url: url)); return session.webView }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
  final class Coordinator: NSObject, WKNavigationDelegate {
    let visited: (URL) -> Void
    init(visited: @escaping (URL) -> Void) { self.visited = visited }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { if let url = webView.url { visited(url) } }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
      decisionHandler(["https", "http", "about"].contains(scheme) ? .allow : .cancel)
    }
  }
}

@available(iOS 16.0, *)
struct DCikePluginStore: View {
  @EnvironmentObject private var model: DCikeNativeModel
  @State private var items: [[String: Any]] = []
  @State private var url = ""
  @State private var search = ""
  @State private var importer = false
  @State private var loading = false
  @State private var message: String?
  private var filtered: [[String: Any]] { items.filter { search.isEmpty || settingsText(settingsMap($0["manifest"])["name"]).localizedCaseInsensitiveContains(search) } }
  var body: some View {
    List {
      Section("手动安装") {
        TextField("图源下载地址", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("从地址安装") { install(["url": url.trimmingCharacters(in: .whitespacesAndNewlines)]) }.disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
        Button("从文件安装") { importer = true }
      }
      Section("图源商店") {
        if loading { ProgressView() }
        ForEach(filtered.indices, id: \.self) { i in
          let item = filtered[i]
          let manifest = settingsMap(item["manifest"])
          HStack {
            VStack(alignment: .leading, spacing: 5) {
              Text(settingsText(manifest["name"], settingsText(item["repo"]))).font(.headline)
              Text(settingsText(manifest["describe"])).font(.caption).foregroundStyle(.secondary)
              Text(settingsText(manifest["version"])).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("安装") { install(["item": item]) }.buttonStyle(.bordered).disabled(loading)
          }
        }
      }
    }.navigationTitle("添加图源").searchable(text: $search, prompt: "搜索图源")
    .task { await load() }.refreshable { await load() }
    .fileImporter(isPresented: $importer, allowedContentTypes: [.data, .json, .zip, .javaScript], allowsMultipleSelection: false) { result in
      switch result {
      case .success(let urls): if let file = urls.first { importFile(file) }
      case .failure(let error): message = error.localizedDescription
      }
    }
    .alert("图源安装", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
  }
  private func load() async {
    loading = true
    do { let result = try await model.request("pluginStore"); items = settingsRows(result); if items.isEmpty { items = settingsRows(settingsMap(result)["plugins"]) } }
    catch { message = error.localizedDescription }
    loading = false
  }
  private func install(_ arguments: [String: Any]) {
    loading = true
    Task { do { _ = try await model.request("installPlugin", arguments); await model.refresh(); message = "安装完成" } catch { message = error.localizedDescription }; loading = false }
  }
  private func importFile(_ file: URL) {
    let scoped = file.startAccessingSecurityScopedResource()
    loading = true
    Task {
      defer { if scoped { file.stopAccessingSecurityScopedResource() }; loading = false }
      do { _ = try await model.request("installPlugin", ["path": file.path, "name": file.lastPathComponent]); await model.refresh(); message = "安装完成" }
      catch { message = error.localizedDescription }
    }
  }
}

@available(iOS 16.0, *)
struct DCikeNativeBackup: View {
  @EnvironmentObject private var model: DCikeNativeModel
  @State private var includeDownloads = false
  @State private var exportURL: URL?
  @State private var importURL: URL?
  @State private var showImporter = false
  @State private var confirm = false
  @State private var busy = false
  @State private var message: String?
  var body: some View {
    Form {
      Section {
        Toggle("包含已下载漫画", isOn: $includeDownloads)
        Button("生成备份文件") { export() }
        if let file = exportURL { ShareLink(item: file) { Label("保存或分享备份", systemImage: "square.and.arrow.up") } }
      } header: { Text("备份") } footer: { Text("备份可能包含你的账号与图源设置，请保存到自己的安全位置。") }
      Section {
        Button("选择备份文件") { showImporter = true }
      } header: { Text("恢复") } footer: { Text("恢复前请先备份当前数据。选中文件后仍需确认，才会写入应用。") }
      if busy { ProgressView("正在处理数据") }
    }.navigationTitle("备份与恢复").navigationBarTitleDisplayMode(.inline).disabled(busy)
    .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
      switch result { case .success(let urls): importURL = urls.first; confirm = importURL != nil; case .failure(let error): message = error.localizedDescription }
    }
    .confirmationDialog("恢复此备份？", isPresented: $confirm, titleVisibility: .visible) {
      Button("恢复备份", role: .destructive) { restore() }
      Button("取消", role: .cancel) { importURL = nil }
    } message: { Text("备份中的记录和配置将写入本地，可能覆盖现有数据。") }
    .alert("备份与恢复", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好", role: .cancel) {} } message: { Text(message ?? "") }
  }
  private func export() { busy = true; Task { do { if let path = try await model.request("export", ["includeDownloads": includeDownloads]) as? String { exportURL = URL(fileURLWithPath: path) } } catch { message = error.localizedDescription }; busy = false } }
  private func restore() {
    guard let file = importURL else { return }
    let scoped = file.startAccessingSecurityScopedResource(); busy = true
    Task {
      defer { if scoped { file.stopAccessingSecurityScopedResource() }; importURL = nil; busy = false }
      do { _ = try await model.request("import", ["path": file.path, "confirmed": true]); await model.refresh(); message = "恢复完成" }
      catch { message = error.localizedDescription }
    }
  }
}

@available(iOS 16.0, *)
struct DCikeNativeAbout: View {
  @EnvironmentObject private var model: DCikeNativeModel
  @State private var avatar: UIImage?
  @State private var contributors: [[String: Any]] = []
  var body: some View {
    List {
      Section {
        VStack(spacing: 12) {
          if let avatar { Image(uiImage: avatar).resizable().scaledToFill().frame(width: 88, height: 88).clipShape(Circle()) }
          else { Image(systemName: "book.closed.fill").font(.system(size: 56)).foregroundStyle(.blue) }
          Text("DCike").font(.largeTitle.bold())
          Text("DouChi39 · 版本 x").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
      }
      Section("项目") {
        Link(destination: URL(string: "https://github.com/DouChi39/DCike")!) { Label("项目地址", systemImage: "link") }
        Link(destination: URL(string: "https://github.com/DouChi39/DCike/graphs/contributors")!) { Label("项目贡献者", systemImage: "person.2") }
        Link(destination: URL(string: "https://github.com/deretame/Breeze")!) { Label("原作 Breeze", systemImage: "heart") }
      }
      if !contributors.isEmpty { Section("贡献者") {
        ForEach(contributors.indices, id: \.self) { i in
          let contributor = contributors[i]
          if let url = URL(string: settingsText(contributor["html_url"])) { Link(settingsText(contributor["login"]), destination: url) }
        }
      } }
      Section { NavigationLink("免责声明") { DCikeDisclaimer() } }
    }.navigationTitle("关于").navigationBarTitleDisplayMode(.inline)
    .task {
      if let raw = try? await model.request("asset", ["name": "avatar"]) {
        if let bytes = raw as? FlutterStandardTypedData { avatar = UIImage(data: bytes.data) }
        else if let bytes = raw as? Data { avatar = UIImage(data: bytes) }
      }
      do {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/DouChi39/DCike/contributors?per_page=20")!)
        request.setValue("DCike", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 200 { contributors = settingsRows(try JSONSerialization.jsonObject(with: data)) }
      } catch { /* The project and contributor links remain usable offline. */ }
    }
  }
}

@available(iOS 16.0, *)
private struct DCikeDisclaimer: View {
  private let items = [
    ("1. 项目性质与声明", "本项目为开源软件，由本人独立开发并维护。项目以\"原样\"形式提供，开发者不对项目的功能完整性、稳定性、安全性或适用性作出任何明示或暗示的担保。"),
    ("2. 责任限制", "开发者对因使用、修改或分发本项目（包括但不限于直接使用、二次开发或集成至其他项目）而导致的任何直接、间接、特殊、附带或后果性损害不承担任何责任。这些损害可能包括但不限于数据丢失、设备损坏、业务中断、利润损失或其他经济损失。"),
    ("3. 用户责任", "用户在使用本项目时，应自行评估其适用性并承担所有风险。用户须确保其使用行为符合所在国家或地区的法律法规及道德规范。开发者不对用户因违反法律法规或不当使用本项目而导致的任何后果负责。"),
    ("4. 第三方依赖与资源", "本项目可能依赖或引用第三方库、工具、服务或其他资源。开发者不对这些第三方资源的内容、功能、安全性或合法性负责。用户应自行评估并承担使用第三方资源的风险。"),
    ("5. 无担保声明", "开发者明确声明不对本项目提供任何形式的担保，包括但不限于：适销性担保；特定用途适用性担保；不侵犯第三方权利担保；无错误或无中断运行担保。"),
    ("6. 项目修改与终止", "开发者保留随时修改、暂停或终止本项目的权利，且无需提前通知用户。开发者不对因项目修改、暂停或终止而导致的任何后果负责。"),
    ("7. 贡献者责任", "如果本项目接受外部贡献，贡献者的行为仅代表其个人立场，不代表开发者的观点或立场。开发者对贡献者的行为及其贡献内容不承担责任。"),
    ("8. 法律合规性", "用户在使用本项目时，应确保其行为符合所在国家或地区的法律法规。开发者不对用户因违反法律法规而导致的任何后果负责。"),
    ("重要提示", "在使用本项目之前，请仔细阅读并理解本免责声明。如果您不同意本声明的任何条款，请立即停止使用本项目。继续使用本项目即表示您已阅读、理解并同意本免责声明的全部内容。")
  ]
  var body: some View {
    List { ForEach(items.indices, id: \.self) { i in Section(items[i].0) { Text(items[i].1).textSelection(.enabled) } } }
      .navigationTitle("免责声明").navigationBarTitleDisplayMode(.inline)
  }
}
