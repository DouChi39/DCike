import SwiftUI
import SafariServices
import UIKit

// Plugin data stays in the existing in-process backend. Native views never fetch
// comic images directly, so source authentication and decoding stay intact.
private func contentMap(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func contentRows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
private func contentText(_ value: Any?) -> String {
  guard let value = value, !(value is NSNull) else { return "" }
  return String(describing: value)
}
private func contentFunction(_ request: [String: Any]) -> String {
  let nested = contentMap(request["request"])
  for key in ["fnPath", "fn_path", "fn", "function"] {
    let value = contentText(request[key]).isEmpty ? contentText(nested[key]) : contentText(request[key])
    if !value.isEmpty { return value }
  }
  return ""
}
private func contentData(_ response: [String: Any]) -> [String: Any] {
  let data = contentMap(response["data"])
  return data.isEmpty ? response : data
}
private func contentMetadataText(_ item: [String: Any]) -> String {
  contentRows(item["metadata"]).flatMap { entry in
    (entry["value"] as? [Any] ?? []).map { value in
      let object = contentMap(value)
      return object.isEmpty ? contentText(value) : contentText(object["name"])
    }
  }.joined(separator: " ")
}
private func contentPluginOrder(_ item: [String: Any]) -> Int? {
  (item["sortOrder"] as? NSNumber)?.intValue
}
private func contentPluginDate(_ item: [String: Any]) -> Date? {
  guard let value = item["insertedAt"] as? String else { return nil }
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: value) { return date }
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: value)
}
private func orderedContentPlugins(_ plugins: [[String: Any]]) -> [[String: Any]] {
  plugins.enumerated().sorted { left, right in
    let leftOrder = contentPluginOrder(left.element)
    let rightOrder = contentPluginOrder(right.element)
    if let leftOrder, let rightOrder, leftOrder != rightOrder { return leftOrder < rightOrder }
    if leftOrder != nil && rightOrder == nil { return true }
    if leftOrder == nil && rightOrder != nil { return false }
    let leftDate = contentPluginDate(left.element)
    let rightDate = contentPluginDate(right.element)
    if let leftDate, let rightDate, leftDate != rightDate { return leftDate < rightDate }
    return left.offset < right.offset
  }.map { $0.element }
}

@available(iOS 16.0, *)
struct DCikeHomePage: View {
  @EnvironmentObject private var model: DCikeNativeModel
  var cloud = false
  var initialSource = ""
  @AppStorage("DCike.native.homeSource") private var rememberedHome = ""
  @AppStorage("DCike.native.cloudSource") private var rememberedCloud = ""
  @State private var source = ""
  @State private var tabs: [[String: Any]] = []
  @State private var tab = 0
  @State private var loading = false
  @State private var error = ""

  private var title: String { cloud ? "云收藏" : "首页" }
  private var orderedPlugins: [[String: Any]] { orderedContentPlugins(model.plugins) }
  private var candidates: [[String: Any]] {
    orderedPlugins.filter {
      $0["enabled"] as? Bool == true && contentMap($0["info"])[cloud ? "haveCloudFavorite" : "haveHome"] as? Bool == true
    }
  }
  private var candidateKey: String { candidates.map { contentText($0["id"]) }.joined(separator: ":") }

  var body: some View {
    VStack(spacing: 0) {
      if tabs.count > 1 {
        ScrollView(.horizontal, showsIndicators: false) {
          Picker("分类", selection: $tab) {
            ForEach(tabs.indices, id: \.self) { index in
              Text(contentText(tabs[index]["title"])).tag(index)
            }
          }
          .pickerStyle(.segmented)
          .padding(.horizontal)
          .padding(.vertical, 8)
        }
      }
      Group {
        if loading { ProgressView("正在加载图源…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if !error.isEmpty { contentError }
        else if tabs.indices.contains(tab) {
          DCikeHomeTabContent(source: source, tab: tabs[tab], onRefresh: { await load() }).id("\(source):\(tab)")
        } else {
          VStack(spacing: 16) {
            Image(systemName: cloud ? "cloud" : "books.vertical").font(.largeTitle).foregroundStyle(.secondary)
            Text(candidates.isEmpty ? "没有支持此页面的图源" : "图源暂无内容").foregroundStyle(.secondary)
            if candidates.isEmpty { NavigationLink("添加图源") { DCikePluginStore() } }
            else { Button("重新加载") { Task { await load() } } }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .navigationTitle(title)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Menu {
          ForEach(candidates.indices, id: \.self) { index in
            let plugin = candidates[index]
            Button {
              source = contentText(plugin["id"])
              remember()
            } label: {
              if source == contentText(plugin["id"]) { Label(contentText(plugin["name"]), systemImage: "checkmark") }
              else { Text(contentText(plugin["name"])) }
            }
          }
        } label: { Label(sourceName, systemImage: "square.stack.3d.up") }
        .disabled(candidates.isEmpty)
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        NavigationLink { DCikeSearchPage(source: source) } label: { Image(systemName: "magnifyingglass") }
          .accessibilityLabel("搜索漫画")
      }
    }
    .task(id: candidateKey) { await chooseSource() }
    .task(id: source) { await load() }
  }

  private var sourceName: String { contentText(candidates.first { contentText($0["id"]) == source }?["name"]).isEmpty ? "选择图源" : contentText(candidates.first { contentText($0["id"]) == source }?["name"]) }
  private var contentError: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").font(.largeTitle).foregroundStyle(.secondary)
      Text(error).multilineTextAlignment(.center)
      Button("重新加载") { Task { await load() } }
      NavigationLink("图源登录与设置") { DCikePluginSettings(source: source) }
    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  private func remember() {
    if cloud { rememberedCloud = source } else { rememberedHome = source }
  }
  private func chooseSource() async {
    let ids = candidates.map { contentText($0["id"]) }
    guard !ids.contains(source) else { return }
    let remembered = initialSource.isEmpty ? (cloud ? rememberedCloud : rememberedHome) : initialSource
    source = ids.contains(remembered) ? remembered : (ids.first ?? "")
    remember()
  }
  @MainActor private func load() async {
    guard !source.isEmpty else { tabs = []; return }
    let loadingSource = source
    loading = true; error = ""; tabs = []; tab = 0
    do {
      let response = try await model.plugin(source, cloud ? "getPluginCloudFavoritePagesBundle" : "getPluginHomePagesBundle")
      guard loadingSource == source else { return }
      let data = contentData(response)
      tabs = contentRows(data["pages"]).isEmpty ? contentRows(data["tabs"]) : contentRows(data["pages"])
    } catch { if loadingSource == source { self.error = error.localizedDescription } }
    if loadingSource == source { loading = false }
  }
}

@available(iOS 16.0, *)
private struct DCikeHomeTabContent: View {
  let source: String
  let tab: [String: Any]
  let onRefresh: () async -> Void
  var body: some View {
    let scene = contentMap(tab["scene"])
    Group {
      if !scene.isEmpty { DCikeScenePage(source: source, scene: scene, embedded: true) }
      else {
        let page = contentMap(tab["page"])
        ScrollView {
          DCikeSchemaContent(source: source, scheme: contentMap(page["scheme"]), data: contentMap(page["data"]))
        }.refreshable { await onRefresh() }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        ForEach(actions.indices, id: \.self) { index in
          let wrapper = actions[index]
          let action = contentMap(wrapper["action"]).isEmpty ? wrapper : contentMap(wrapper["action"])
          NavigationLink {
            DCikeActionDestination(action: action, source: source)
          } label: { Image(systemName: contentText(action["type"]) == "openSearch" ? "magnifyingglass" : "ellipsis") }
          .accessibilityLabel(contentText(wrapper["title"]).isEmpty ? "更多选项" : contentText(wrapper["title"]))
        }
      }
    }
  }
  private var actions: [[String: Any]] {
    let header = contentRows(contentMap(tab["header"])["actions"])
    return header.isEmpty ? contentRows(tab["actions"]) : header
  }
}

@available(iOS 16.0, *)
struct DCikeSchemaContent: View {
  let source: String
  let scheme: [String: Any]
  let data: [String: Any]
  var body: some View {
    DCikeSchemaNode(source: source, node: contentMap(scheme["body"]), data: data)
      .padding(.vertical, 8)
  }
}

@available(iOS 16.0, *)
private struct DCikeSchemaNode: View {
  let source: String
  let node: [String: Any]
  let data: [String: Any]
  private var items: [[String: Any]] { contentRows(data[contentText(node["key"])]) }
  var body: some View { render() }

  private func render() -> AnyView {
    switch contentText(node["type"]) {
    case "list":
      let children = contentRows(node["children"])
      return AnyView(VStack(alignment: .leading, spacing: 20) {
        ForEach(children.indices, id: \.self) { index in
          DCikeSchemaNode(source: source, node: children[index], data: data)
        }
      })
    case "chip-list":
      return AnyView(ScrollView(.horizontal, showsIndicators: false) {
        HStack {
          ForEach(items.indices, id: \.self) { index in
            let item = items[index]
            NavigationLink { DCikeActionDestination(action: contentMap(item["action"]), source: source) } label: {
              Text(contentText(item["label"])).padding(.horizontal, 12).padding(.vertical, 8)
            }.modifier(DCikeContentGlassControl())
          }
        }.padding(.horizontal)
      })
    case "action-grid":
      return AnyView(LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 16) {
        ForEach(items.indices, id: \.self) { index in
          let item = items[index]
          NavigationLink { DCikeActionDestination(action: contentMap(item["action"]), source: source) } label: {
            VStack {
              DCikeContentImage(source: source, image: contentMap(item["cover"]), comicId: contentText(item["id"] ?? item["title"]), pictureType: "category")
                .aspectRatio(1, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
              Text(contentText(item["title"])).font(.subheadline).lineLimit(2).foregroundStyle(.primary)
            }
          }.buttonStyle(.plain)
        }
      }.padding(.horizontal))
    case "comic-section-list":
      return AnyView(VStack(alignment: .leading, spacing: 24) {
        ForEach(items.indices, id: \.self) { index in
          let section = items[index]
          VStack(alignment: .leading, spacing: 12) {
            DCikeContentSectionHeader(title: contentText(section["title"]), subtitle: contentText(section["subtitle"]), action: contentMap(section["action"]), source: source)
            ScrollView(.horizontal, showsIndicators: false) {
              LazyHStack(alignment: .top, spacing: 12) {
                let comics = contentRows(section["items"])
                ForEach(comics.indices, id: \.self) { i in
                  DCikeContentComicCard(item: comics[i], source: source).frame(width: 120)
                }
              }.padding(.horizontal)
            }
          }
        }
      })
    case "comic-grid":
      return AnyView(VStack(alignment: .leading, spacing: 12) {
        if !contentText(node["title"]).isEmpty {
          DCikeContentSectionHeader(title: contentText(node["title"]), subtitle: "", action: contentMap(node["action"]), source: source)
        }
        DCikeContentComicGrid(items: items, source: source)
      })
    default: return AnyView(EmptyView())
    }
  }
}

@available(iOS 16.0, *)
private struct DCikeContentSectionHeader: View {
  let title: String
  let subtitle: String
  let action: [String: Any]
  let source: String
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.title3.bold()).foregroundStyle(.primary)
        if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
      if !contentText(action["type"]).isEmpty && contentText(action["type"]) != "none" {
        NavigationLink { DCikeActionDestination(action: action, source: source) } label: { Image(systemName: "chevron.right") }
          .accessibilityLabel("查看全部\(title)")
      }
    }.padding(.horizontal)
  }
}

@available(iOS 16.0, *)
struct DCikeContentComicGrid: View {
  let items: [[String: Any]]
  let source: String
  var onReachEnd: (() -> Void)? = nil
  var body: some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], alignment: .leading, spacing: 20) {
      ForEach(items.indices, id: \.self) { index in
        DCikeContentComicCard(item: items[index], source: source)
          .onAppear { if index >= max(0, items.count - 3) { onReachEnd?() } }
      }
    }.padding(.horizontal)
  }
}

@available(iOS 16.0, *)
struct DCikeContentComicCard: View {
  let item: [String: Any]
  let source: String
  private var itemSource: String { contentText(item["source"]).isEmpty ? source : contentText(item["source"]) }
  var body: some View {
    NavigationLink { DCikeDetailPage(source: itemSource, comicId: contentText(item["id"] ?? item["comicId"])) } label: {
      DCikeContentImage(source: itemSource, image: contentMap(item["cover"]), comicId: contentText(item["id"] ?? item["comicId"]))
        .aspectRatio(0.7, contentMode: .fit)
        .overlay(alignment: .bottom) {
          VStack(alignment: .leading, spacing: 3) {
            Text(contentText(item["title"])).font(.subheadline.weight(.semibold)).lineLimit(2)
            if !contentText(item["subtitle"]).isEmpty {
              Text(contentText(item["subtitle"])).font(.caption).lineLimit(1)
            }
          }
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain)
  }
}

@available(iOS 16.0, *)
struct DCikeContentImage: View {
  @EnvironmentObject private var model: DCikeNativeModel
  let source: String
  let image: [String: Any]
  let comicId: String
  var pictureType = "cover"
  @State private var picture: UIImage?
  private var key: String { "\(source):\(comicId):\(pictureType):\(contentText(image["url"])):\(contentText(image["path"]))" }
  var body: some View {
    GeometryReader { proxy in
      Group {
        if let picture { Image(uiImage: picture).resizable().scaledToFill() }
        else { Rectangle().fill(Color(uiColor: .secondarySystemBackground)).overlay { Image(systemName: "book.closed").foregroundStyle(.secondary) } }
      }.frame(width: proxy.size.width.isFinite ? max(0, proxy.size.width) : 0,
              height: proxy.size.height.isFinite ? max(0, proxy.size.height) : 0).clipped()
    }
    .task(id: key) {
      picture = nil
      guard let path = (try? await model.request("image", ["source": source, "comicId": comicId, "image": image, "pictureType": pictureType])) as? String else { return }
      let loaded = await DCikeLoadImage(path: path)
      if !Task.isCancelled { picture = loaded }
    }
    .accessibilityHidden(true)
  }
}

@available(iOS 16.0, *)
private struct DCikeContentGlassControl: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(iOS 26.0, *) { content.buttonStyle(.glass) }
    else { content.buttonStyle(.bordered) }
  }
}

@available(iOS 16.0, *)
struct DCikeActionDestination: View {
  let action: [String: Any]
  let source: String
  var body: some View { destination() }
  private func destination() -> AnyView {
    let payload = contentMap(action["payload"])
    let from = contentText(payload["source"]).isEmpty ? source : contentText(payload["source"])
    switch contentText(action["type"]) {
    case "openSearch":
      var extern = contentMap(payload["extern"])
      for (key, value) in payload where key != "source" && key != "extern" { if extern[key] == nil { extern[key] = value } }
      return AnyView(DCikeSearchPage(source: from, keyword: contentText(payload["keyword"] ?? extern["keyword"]), extern: extern))
    case "openPluginFunction": return AnyView(DCikeFunctionPage(source: from, functionId: contentText(payload["id"]), title: contentText(payload["title"])))
    case "openCloudFavorite": return AnyView(DCikeScenePage(source: from, scene: [:], bundleFunction: "getCloudFavoriteSceneBundle"))
    case "openComicList": return AnyView(DCikeScenePage(source: from, scene: contentMap(payload["scene"])))
    case "openComicInfo": return AnyView(DCikeDetailPage(source: from, comicId: contentText(payload["comicId"])))
    case "openWeb":
      if let url = URL(string: contentText(payload["url"])), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
        return AnyView(DCikeContentBrowser(url: url).navigationTitle(contentText(payload["title"])).navigationBarTitleDisplayMode(.inline))
      }
      return AnyView(Text("链接无效").foregroundStyle(.secondary))
    default: return AnyView(Text("暂无可用内容").foregroundStyle(.secondary))
    }
  }
}

private struct DCikeContentBrowser: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
  func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

@available(iOS 16.0, *)
struct DCikeFunctionPage: View {
  @EnvironmentObject private var model: DCikeNativeModel
  let source: String
  let functionId: String
  let title: String
  @State private var response: [String: Any] = [:]
  @State private var loading = true
  @State private var error = ""
  var body: some View {
    ScrollView {
      if loading { ProgressView().padding(40) }
      else if !error.isEmpty {
        VStack(spacing: 12) {
          Text(error)
          Button("重试") { Task { await load() } }
          NavigationLink("图源登录与设置") { DCikePluginSettings(source: source) }
        }.padding()
      } else { DCikeSchemaContent(source: source, scheme: contentMap(response["scheme"]), data: contentData(response)) }
    }
    .navigationTitle(contentText(contentMap(response["scheme"])["title"]).isEmpty ? title : contentText(contentMap(response["scheme"])["title"]))
    .navigationBarTitleDisplayMode(.inline)
    .task { await load() }
    .refreshable { await load() }
  }
  @MainActor private func load() async {
    loading = true; error = ""
    do { response = try await model.plugin(source, "getFunctionPage", ["id": functionId]) }
    catch { self.error = error.localizedDescription }
    loading = false
  }
}

@available(iOS 16.0, *)
struct DCikeScenePage: View {
  @EnvironmentObject private var model: DCikeNativeModel
  let source: String
  let scene: [String: Any]
  var bundleFunction = ""
  var embedded = false
  @State private var resolved: [String: Any] = [:]
  @State private var items: [[String: Any]] = []
  @State private var filters: [[String: Any]] = []
  @State private var selections: [String: String] = [:]
  @State private var extern: [String: Any] = [:]
  @State private var page = 0
  @State private var ended = false
  @State private var loading = false
  @State private var error = ""
  @State private var showFilters = false
  @State private var initialized = false
  @State private var draftSelections: [String: String] = [:]

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        if !items.isEmpty {
          DCikeContentComicGrid(items: items, source: source, onReachEnd: {
            if error.isEmpty { Task { await loadMore() } }
          })
        }
        if loading || !initialized { ProgressView().padding() }
        else if !error.isEmpty {
          VStack(spacing: 12) {
            Text(error).multilineTextAlignment(.center)
            Button("重试") { Task { if page == 0 { await initialize() } else { await loadMore() } } }
            NavigationLink("图源登录与设置") { DCikePluginSettings(source: source) }
          }.padding()
        } else if !ended {
          Button("加载更多") { Task { await loadMore() } }.padding()
        } else if items.isEmpty { Text("暂无漫画").foregroundStyle(.secondary).padding(40) }
      }.padding(.vertical)
    }
    .modifier(DCikeSceneTitle(title: contentText(resolved["title"]), embedded: embedded))
    .toolbar {
      if !filters.isEmpty {
        ToolbarItem(placement: .navigationBarTrailing) { Button { draftSelections = selections; showFilters = true } label: { Image(systemName: "line.3.horizontal.decrease") }.disabled(loading).accessibilityLabel("筛选漫画") }
      }
    }
    .sheet(isPresented: $showFilters) {
      NavigationStack {
        Form {
          ForEach(filters.indices, id: \.self) { index in
            let field = filters[index]
            let key = contentText(field["key"])
            Picker(contentText(field["label"]), selection: Binding(get: { draftSelections[key] ?? "" }, set: { draftSelections[key] = $0 })) {
              ForEach(flatten(contentRows(field["options"])).indices, id: \.self) { i in
                let option = flatten(contentRows(field["options"]))[i]
                Text(contentText(option["label"])).tag(contentText(option["value"]))
              }
            }
          }
        }
        .navigationTitle("筛选")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { showFilters = false } }
          ToolbarItem(placement: .confirmationAction) { Button("应用") { selections = draftSelections; showFilters = false; Task { await reloadItems() } } }
        }
      }
    }
    .task { await initialize() }
    .refreshable { await initialize() }
  }

  private func flatten(_ options: [[String: Any]], depth: Int = 0) -> [[String: Any]] {
    options.flatMap { option -> [[String: Any]] in
      var copy = option
      copy["label"] = String(repeating: "　", count: depth) + contentText(option["label"] ?? option["value"])
      return [copy] + flatten(contentRows(option["children"]), depth: depth + 1)
    }
  }
  @MainActor private func initialize() async {
    guard !loading else { return }
    loading = true; error = ""; items = []; page = 0; ended = false; extern = [:]
    do {
      resolved = scene
      if !bundleFunction.isEmpty {
        let response: [String: Any]
        do { response = try await model.plugin(source, bundleFunction) }
        catch {
          guard bundleFunction == "getCloudFavoriteSceneBundle" else { throw error }
          response = try await model.plugin(source, "get_cloud_favorite_scene_bundle")
        }
        let data = contentData(response)
        resolved = contentMap(data["scene"]).isEmpty ? data : contentMap(data["scene"])
      }
      let filter = contentMap(resolved["filter"])
      filters = []; selections = [:]
      if !contentFunction(filter).isEmpty {
        let response = try await model.plugin(source, contentFunction(filter), contentMap(filter["core"]), contentMap(filter["extern"]))
        filters = contentRows(contentMap(response["scheme"])["fields"]).filter { contentText($0["kind"]) == "choice" }
        let defaults = contentMap(contentData(response)["values"])
        for field in filters {
          let key = contentText(field["key"])
          let options = flatten(contentRows(field["options"]))
          let value = contentText(defaults[key])
          selections[key] = options.contains(where: { contentText($0["value"]) == value }) ? value : contentText(options.first?["value"])
        }
      }
    } catch { self.error = error.localizedDescription; ended = true }
    loading = false; initialized = true
    if error.isEmpty { await loadMore() }
  }
  @MainActor private func reloadItems() async { items = []; page = 0; ended = false; extern = [:]; await loadMore() }
  @MainActor private func loadMore() async {
    guard !loading && !ended else { return }
    loading = true; error = ""
    do {
      let body = contentMap(resolved["body"])
      let request = body.isEmpty ? contentMap(resolved["list"]) : contentMap(body["request"])
      let fn = contentFunction(request)
      guard !fn.isEmpty else { throw NSError(domain: "DCike", code: 1, userInfo: [NSLocalizedDescriptionKey: "图源缺少漫画列表配置"]) }
      var core = contentMap(request["core"])
      var requestExtern = contentMap(request["extern"])
      requestExtern.merge(extern) { _, next in next }
      for field in filters {
        let key = contentText(field["key"])
        let options = flatten(contentRows(field["options"]))
        if let selected = options.first(where: { contentText($0["value"]) == selections[key] }) {
          let result = contentMap(selected["result"])
          core.merge(contentMap(result["core"])) { _, next in next }
          requestExtern.merge(contentMap(result["extern"])) { _, next in next }
        }
      }
      core["page"] = page + 1
      let response = try await model.plugin(source, fn, core, requestExtern)
      let data = contentData(response)
      let next = contentRows(data["items"])
      var seen = Set(items.map { contentText($0["id"]) })
      for item in next where seen.insert(contentText(item["id"])).inserted { items.append(item) }
      let paging = contentMap(data["paging"])
      page = (paging["page"] as? NSNumber)?.intValue ?? (page + 1)
      extern = contentMap(response["extern"])
      let pages = (paging["pages"] as? NSNumber)?.intValue
      ended = paging["hasReachedMax"] as? Bool == true || next.isEmpty || (pages != nil && page >= pages!)
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}

@available(iOS 16.0, *)
private struct DCikeSceneTitle: ViewModifier {
  let title: String
  let embedded: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if embedded { content }
    else { content.navigationTitle(title.isEmpty ? "漫画" : title).navigationBarTitleDisplayMode(.inline) }
  }
}

@available(iOS 16.0, *)
struct DCikeSearchPage: View {
  @EnvironmentObject private var model: DCikeNativeModel
  var source = ""
  var keyword = ""
  var extern: [String: Any] = [:]
  @State private var query = ""
  @State private var searchWord = ""
  @State private var selectedSource = ""
  @State private var items: [[String: Any]] = []
  @State private var pages: [String: Int] = [:]
  @State private var reached: Set<String> = []
  @State private var continuation: [String: [String: Any]] = [:]
  @State private var loading = false
  @State private var searched = false
  @State private var errors: [String: String] = [:]
  @State private var generation = UUID()
  @State private var searchExtern: [String: Any] = [:]
  @State private var showAdvanced = false
  @State private var showSources = false
  @State private var aggregateSources: Set<String> = []
  @State private var draftSources: Set<String> = []
  @State private var showClearHistory = false
  private var candidates: [[String: Any]] { orderedContentPlugins(model.plugins).filter { $0["enabled"] as? Bool == true } }
  private var history: [String] { model.settings["searchHistory"] as? [String] ?? [] }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if !searched {
          if history.isEmpty { Text("输入名称搜索漫画").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40) }
          else {
            HStack {
              Text("搜索历史").font(.headline)
              Spacer()
              Button { showClearHistory = true } label: { Image(systemName: "trash") }.accessibilityLabel("清空搜索历史")
            }.padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], alignment: .leading, spacing: 12) {
              ForEach(Array(history.enumerated()), id: \.offset) { _, word in
                Button { query = word; Task { await search(reset: true) } } label: {
                  Text(word).lineLimit(2).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .modifier(DCikeContentGlassControl())
                .contextMenu { Button("删除", role: .destructive) { saveHistory(history.filter { $0 != word }) } }
              }
            }.padding(.horizontal)
          }
        }
        DCikeContentComicGrid(items: visibleItems, source: selectedSource, onReachEnd: {
          if errors.isEmpty { Task { await search(reset: false) } }
        })
        ForEach(errors.keys.sorted(), id: \.self) { key in
          VStack(alignment: .leading, spacing: 8) {
            Text("\(sourceName(key))：\(errors[key] ?? "加载失败")").font(.footnote).foregroundStyle(.secondary)
            NavigationLink("图源登录与设置") { DCikePluginSettings(source: key) }
          }.padding(.horizontal)
        }
        if loading { ProgressView().frame(maxWidth: .infinity).padding() }
        else if searched && hasMore {
          Button(errors.isEmpty ? "加载更多" : "重试未加载的图源") { Task { await search(reset: false) } }.frame(maxWidth: .infinity).padding()
        } else if searched && items.isEmpty && errors.isEmpty { Text("没有找到漫画").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding() }
      }
    }
    .navigationTitle("搜索")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, prompt: "漫画名称")
    .onSubmit(of: .search) { Task { await search(reset: true) } }
    .toolbar {
      if !selectedSource.isEmpty {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button { showAdvanced = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("高级搜索")
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Menu {
          Button { select("") } label: { if selectedSource.isEmpty { Label("全部图源", systemImage: "checkmark") } else { Text("全部图源") } }
          if selectedSource.isEmpty {
            Button { draftSources = aggregateSources; showSources = true } label: { Label("选择参与搜索的图源", systemImage: "checklist") }
          }
          ForEach(candidates.indices, id: \.self) { index in
            let item = candidates[index]
            Button { select(contentText(item["id"])) } label: {
              if selectedSource == contentText(item["id"]) { Label(contentText(item["name"]), systemImage: "checkmark") }
              else { Text(contentText(item["name"])) }
            }
          }
        } label: { Image(systemName: "line.3.horizontal.decrease") }.accessibilityLabel("选择搜索图源")
      }
    }
    .sheet(isPresented: $showAdvanced) {
      DCikeAdvancedSearch(source: selectedSource, initial: searchExtern) { values in
        searchExtern = values
        if searched { Task { await search(reset: true) } }
      }
    }
    .sheet(isPresented: $showSources) {
      NavigationStack {
        List {
          ForEach(candidates.indices, id: \.self) { index in
            let plugin = candidates[index]
            let id = contentText(plugin["id"])
            Toggle(contentText(plugin["name"]), isOn: Binding(get: { draftSources.contains(id) }, set: { enabled in
              if enabled { draftSources.insert(id) } else { draftSources.remove(id) }
            }))
          }
        }
        .navigationTitle("参与搜索的图源")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { showSources = false } }
          ToolbarItem(placement: .confirmationAction) { Button("完成") { aggregateSources = draftSources; showSources = false; if searched { Task { await search(reset: true) } } } }
        }
      }
    }
    .confirmationDialog("清空所有搜索历史？", isPresented: $showClearHistory, titleVisibility: .visible) {
      Button("清空", role: .destructive) { saveHistory([]) }
    }
    .task {
      selectedSource = source; aggregateSources = Set(candidates.map { contentText($0["id"]) }); query = keyword; searchExtern = extern
      if !keyword.isEmpty { await search(reset: true) }
    }
    .onChange(of: model.revision) { _ in
      if !searched && aggregateSources.isEmpty && !candidates.isEmpty {
        aggregateSources = Set(candidates.map { contentText($0["id"]) })
      }
    }
    .refreshable { if searched { await search(reset: true) } }
  }
  private var visibleItems: [[String: Any]] {
    let keywords = (model.settings["maskedKeywords"] as? [String] ?? []).map { normalized($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.isEmpty }
    guard !keywords.isEmpty else { return items }
    return items.filter { item in
      let metadata = contentMetadataText(item)
      let all = normalized(contentText(item["title"]) + contentText(item["subtitle"]) + metadata)
      return !keywords.contains { all.contains($0) }
    }
  }
  private var sources: [String] { selectedSource.isEmpty ? candidates.map { contentText($0["id"]) }.filter { aggregateSources.contains($0) } : [selectedSource] }
  private var hasMore: Bool { sources.contains { !reached.contains($0) } }
  private func normalized(_ value: String) -> String { (value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value).lowercased() }
  private func sourceName(_ id: String) -> String { contentText(candidates.first { contentText($0["id"]) == id }?["name"]) }
  private func select(_ id: String) { selectedSource = id; searchExtern = [:]; if searched { Task { await search(reset: true) } } }
  private func saveHistory(_ values: [String]) {
    model.perform {
      _ = try await model.request("settings", ["patch": ["searchHistory": Array(values.prefix(300))]])
      await model.refresh()
    }
  }
  @MainActor private func search(reset: Bool) async {
    let word = reset ? query.trimmingCharacters(in: .whitespacesAndNewlines) : searchWord
    guard !word.isEmpty else { return }
    if reset {
      generation = UUID(); items = []; pages = [:]; reached = []; continuation = [:]; errors = [:]
      searchWord = word
      saveHistory([word] + history.filter { $0 != word })
    } else if loading { return }
    let token = generation
    loading = true; searched = true
    let pendingSources = errors.isEmpty ? sources : sources.filter { errors[$0] != nil }
    for from in pendingSources where !reached.contains(from) {
      guard generation == token else { return }
      do {
        let nextPage = (pages[from] ?? 0) + 1
        var parameters = searchExtern
        parameters.merge(continuation[from] ?? [:]) { _, next in next }
        let response = try await model.plugin(from, "searchComic", ["keyword": word, "page": nextPage], parameters)
        guard generation == token else { return }
        let data = contentData(response)
        let next = contentRows(data["items"])
        var existing = Set(items.map { contentText($0["source"]) + ":" + contentText($0["id"]) })
        items += next.compactMap { item in
          var row = item; row["source"] = from
          return existing.insert(from + ":" + contentText(row["id"])).inserted ? row : nil
        }
        let paging = contentMap(data["paging"])
        pages[from] = (paging["page"] as? NSNumber)?.intValue ?? nextPage
        continuation[from] = contentMap(response["extern"])
        let count = (paging["pages"] as? NSNumber)?.intValue
        if paging["hasReachedMax"] as? Bool == true || next.isEmpty || (count != nil && pages[from]! >= count!) { reached.insert(from) }
        errors.removeValue(forKey: from)
      } catch { if generation == token { errors[from] = error.localizedDescription } }
    }
    if generation == token { loading = false }
  }
}

@available(iOS 16.0, *)
private struct DCikeAdvancedSearch: View {
  @EnvironmentObject private var model: DCikeNativeModel
  @Environment(\.dismiss) private var dismiss
  let source: String
  let initial: [String: Any]
  let onApply: ([String: Any]) -> Void
  @State private var fields: [[String: Any]] = []
  @State private var values: [String: Any] = [:]
  @State private var loading = true
  @State private var error = ""

  var body: some View {
    NavigationStack {
      Form {
        if loading { ProgressView("正在加载搜索选项…") }
        else if !error.isEmpty {
          Text(error).foregroundStyle(.secondary)
          Button("重试") { Task { await load() } }
        } else if fields.isEmpty { Text("此图源没有提供高级搜索选项").foregroundStyle(.secondary) }
        else {
          ForEach(fields.indices, id: \.self) { index in field(fields[index]) }
        }
      }
      .navigationTitle("高级搜索")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("应用") { apply(); dismiss() }.disabled(loading || !error.isEmpty || fields.isEmpty)
        }
      }
      .task(id: source) { await load() }
    }
  }
  @ViewBuilder private func field(_ item: [String: Any]) -> some View {
    let key = contentText(item["key"])
    let label = contentText(item["label"]).isEmpty ? key : contentText(item["label"])
    let kind = contentText(item["kind"]).isEmpty ? "choice" : contentText(item["kind"])
    let options = contentRows(item["options"])
    if !key.isEmpty {
      if kind == "switch" {
        Toggle(label, isOn: Binding(get: { flag(values[key]) }, set: { values[key] = $0 }))
      } else if kind == "text" {
        TextField(label, text: Binding(get: { contentText(values[key]) }, set: { values[key] = $0 }))
      } else if kind == "choice" && !options.isEmpty {
        Picker(label, selection: Binding(get: { contentText(values[key]) }, set: { selected in
          values[key] = options.first { contentText($0["value"]) == selected }?["value"] ?? NSNull()
        })) {
          if contentText(values[key]).isEmpty && !options.contains(where: { contentText($0["value"]).isEmpty }) { Text("未选择").tag("") }
          ForEach(options.indices, id: \.self) { index in
            Text(contentText(options[index]["label"] ?? options[index]["value"])).tag(contentText(options[index]["value"]))
          }
        }
      } else if kind == "multiChoice" && !options.isEmpty {
        NavigationLink {
          Form {
            ForEach(options.indices, id: \.self) { index in
              let option = options[index]
              let value = contentText(option["value"])
              Toggle(contentText(option["label"] ?? option["value"]), isOn: Binding(get: { multiValues(key).contains(value) }, set: { selected in
                var current = multiValues(key)
                current.removeAll { $0 == value }
                if selected { current.append(value) }
                values[key] = current
              }))
            }
          }.navigationTitle(label).navigationBarTitleDisplayMode(.inline)
        } label: {
          HStack { Text(label); Spacer(); Text(multiValues(key).isEmpty ? "未选择" : "已选择 \(multiValues(key).count) 项").foregroundStyle(.secondary) }
        }
      }
    }
  }
  private func multiValues(_ key: String) -> [String] { (values[key] as? [Any] ?? []).map { contentText($0) } }
  private func flag(_ value: Any?) -> Bool {
    if let flag = value as? Bool { return flag }
    return ["true", "1"].contains(contentText(value).lowercased())
  }
  private func apply() {
    var result = initial
    for item in fields {
      let key = contentText(item["key"])
      guard !key.isEmpty else { continue }
      switch contentText(item["kind"]) {
      case "multiChoice": result[key] = multiValues(key)
      case "switch": result[key] = flag(values[key])
      case "text": result[key] = contentText(values[key])
      case "choice", "": result[key] = values[key] ?? NSNull()
      default: break
      }
    }
    onApply(result)
  }
  @MainActor private func load() async {
    loading = true; error = ""
    do {
      let response = try await model.plugin(source, "getAdvancedSearchScheme", [:], initial)
      fields = contentRows(contentMap(response["scheme"])["fields"])
      values = contentMap(contentData(response)["values"])
      for item in fields {
        let key = contentText(item["key"])
        guard let value = initial[key] else { continue }
        if let selected = value as? [String: Any] { values[key] = selected.filter { flag($0.value) }.map { $0.key } }
        else { values[key] = value }
      }
    } catch { self.error = error.localizedDescription }
    loading = false
  }
}

@available(iOS 16.0, *)
struct DCikeDiscoverPage: View {
  @EnvironmentObject private var model: DCikeNativeModel
  var body: some View {
    List {
      Section {
        NavigationLink { DCikePluginStore() } label: { Label("图源商店", systemImage: "square.grid.2x2") }
        NavigationLink { DCikeSearchPage() } label: { Label("搜索所有图源", systemImage: "magnifyingglass") }
      }
      Section("图源") {
      ForEach(orderedContentPlugins(model.plugins).map { contentText($0["id"]) }, id: \.self) { source in
        if let item = model.plugins.first(where: { contentText($0["id"]) == source }) {
        let info = contentMap(item["info"])
          DisclosureGroup {
            Toggle(isOn: Binding(get: { item["enabled"] as? Bool == true }, set: { enabled in
              model.perform { _ = try await model.request("pluginEnabled", ["source": source, "value": enabled]); await model.refresh() }
            })) { Text("启用图源") }
            if item["enabled"] as? Bool == true {
              NavigationLink { DCikeSearchPage(source: source) } label: { Label("搜索", systemImage: "magnifyingglass") }
              ForEach(functions(info).indices, id: \.self) { functionIndex in
                let function = functions(info)[functionIndex]
                NavigationLink {
                  DCikeActionDestination(action: functionAction(function), source: source)
                } label: { Text(contentText(function["title"]).isEmpty ? "图源功能" : contentText(function["title"])) }
              }
              if item["ready"] as? Bool != true { Text("图源正在初始化，稍后可下拉刷新。") }
            }
            NavigationLink { DCikePluginSettings(source: source, name: contentText(item["name"])) } label: { Label("账号与图源设置", systemImage: "gearshape") }
          } label: { Label(contentText(item["name"]), systemImage: "puzzlepiece.extension") }
        }
      }
      }
    }
    .navigationTitle("发现")
    .refreshable { await model.refresh() }
  }
  private func functions(_ info: [String: Any]) -> [[String: Any]] { contentRows(info["functions"]).isEmpty ? contentRows(info["function"]) : contentRows(info["functions"]) }
  private func functionAction(_ value: [String: Any]) -> [String: Any] {
    let action = contentMap(value["action"])
    return action.isEmpty ? ["type": "openPluginFunction", "payload": ["id": contentText(value["id"]), "title": contentText(value["title"])]] : action
  }
}
