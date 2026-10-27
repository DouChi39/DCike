import SwiftUI
import Network

private final class DCikeReaderNetwork: ObservableObject {
    @Published private(set) var symbol = "network.slash"
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dcike.reader.network")
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let symbol: String
            if path.status != .satisfied { symbol = "network.slash" }
            else if path.usesInterfaceType(.wifi) { symbol = "wifi" }
            else if path.usesInterfaceType(.cellular) { symbol = "antenna.radiowaves.left.and.right" }
            else { symbol = "network" }
            DispatchQueue.main.async { self?.symbol = symbol }
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}

@available(iOS 16.0, *)
struct DCikeComicGrid: View {
    let items: [[String: Any]]
    var source: String = ""
    var moveToFolder: (([String: Any]) -> Void)? = nil
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 14)], alignment: .leading, spacing: 20) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let from = textValue(item["source"]).isEmpty ? source : textValue(item["source"])
                NavigationLink {
                    DCikeDetailPage(source: from, comicId: textValue(item["comicId"] ?? item["id"]))
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        DCikeNativeImage(source: from, image: map(item["cover"]), comicId: textValue(item["comicId"] ?? item["id"]))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(textValue(item["title"])).font(.subheadline.weight(.semibold)).lineLimit(2)
                            if !textValue(item["subtitle"] ?? item["chapterTitle"]).isEmpty {
                                Text(textValue(item["subtitle"] ?? item["chapterTitle"])).font(.caption).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white).padding(8)
                    }
                    .aspectRatio(0.7, contentMode: .fit)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).contextMenu {
                    if let moveToFolder { Button { moveToFolder(item) } label: { Label("移动到文件夹", systemImage: "folder") } }
                }
            }
        }
    }
}

@available(iOS 16.0, *)
struct DCikeDetailPage: View {
    @EnvironmentObject private var model: DCikeNativeModel
    let source: String
    let comicId: String
    @State private var detail: [String: Any] = [:]
    @State private var loading = true
    @State private var error: String?
    @State private var reading: DCikeReadingRoute?
    @State private var downloading = false
    @State private var selectedChapters: Set<Int> = []
    @State private var reverse = false
    private var info: [String: Any] { map(detail["comicInfo"]) }
    private var chapters: [[String: Any]] { rows(detail["eps"]) }
    var body: some View {
        ScrollView {
            if loading { ProgressView().padding(40) }
            else if let error {
                VStack(spacing: 16) { Text(error); Button("重新加载") { Task { await load() } } }.padding()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    detailContent
                }
            }
        }
        .navigationTitle("漫画详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !loading && error == nil && detail["allowDownload"] as? Bool != false {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if downloading && !selectedChapters.isEmpty { queueDownload() }
                        else { downloading.toggle(); selectedChapters = [] }
                    } label: { Image(systemName: downloading ? "checkmark" : "arrow.down.to.line") }
                    .accessibilityLabel(downloading ? "完成下载选择" : "选择下载章节")
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !loading && error == nil && !chapters.isEmpty && !downloading {
                Button { reading = DCikeReadingRoute(index: resumeIndex) } label: {
                    Label(map(detail["history"]).isEmpty ? "开始阅读" : "继续阅读", systemImage: "book")
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).padding(16)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .fullScreenCover(item: $reading, onDismiss: { Task { await load() } }) { route in
            NavigationStack { DCikeReaderPage(source: source, comicId: comicId, chapters: chapters, initialIndex: route.index) }.environmentObject(model)
        }
    }
    private var detailContent: some View {
                VStack(alignment: .leading, spacing: 24) {
                    actions
                    if !textValue(info["description"]).isEmpty {
                        Text(textValue(info["description"])).font(.body).textSelection(.enabled)
                    }
                    ForEach(Array(rows(info["metadata"]).enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 10) {
                            Text(textValue(entry["name"]))
                                .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.5)))
                            metadataTags(rows(entry["value"]))
                        }.font(.subheadline)
                    }
                    HStack {
                        Text("章节").font(.title3.bold())
                        Spacer()
                        Button { reverse.toggle() } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel("反转章节顺序")
                    }
                    if downloading {
                        HStack { Button("全选") { selectedChapters = Set(chapters.indices) }; Button("取消选择") { selectedChapters = [] }; Spacer(); Text("已选 \(selectedChapters.count) 章").foregroundStyle(.secondary) }
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(reverse ? Array(chapters.indices.reversed()) : Array(chapters.indices), id: \.self) { index in
                            Button {
                                if downloading {
                                    if selectedChapters.contains(index) { selectedChapters.remove(index) } else { selectedChapters.insert(index) }
                                } else { reading = DCikeReadingRoute(index: index) }
                            } label: {
                                HStack {
                                    Text(textValue(chapters[index]["name"])).lineLimit(2)
                                    if downloading && selectedChapters.contains(index) { Image(systemName: "checkmark.circle.fill") }
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle)
                        }
                    }
                    let recommendations = rows(detail["recommend"])
                    if !recommendations.isEmpty { Text("相关推荐").font(.title3.bold()); DCikeComicGrid(items: recommendations, source: source) }
                }.padding(20).padding(.bottom, 66)
    }
    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            DCikeDetailHeroImage(source: source, comicId: comicId, image: map(info["cover"]))
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 8) {
                Text(textValue(info["title"])).font(.title.bold()).textSelection(.enabled)
                metadataValues([map(info["creator"])]).font(.subheadline)
                metadataValues(rows(info["titleMeta"])).font(.caption)
            }.foregroundStyle(.white).padding(20)
        }.frame(height: 460).clipped()
    }
    private var actions: some View {
        VStack(spacing: 12) {
            nativeAction {
                model.perform {
                    let result = map(try await model.request("favorite", ["source": source, "comicId": comicId]))
                    detail.merge(result) { _, new in new }
                    if let warning = result["warning"] as? String { model.message = warning }
                }
            } label: { Label(detail["localFavorite"] as? Bool == true ? "已收藏到本地" : "本地收藏", systemImage: detail["localFavorite"] as? Bool == true ? "heart.fill" : "heart").frame(maxWidth: .infinity) }
            HStack(spacing: 10) {
                nativeAction {
                    model.perform { detail["following"] = try await model.request("follow", ["source": source, "comicId": comicId]) }
                } label: { Label("追更", systemImage: detail["following"] as? Bool == true ? "bell.fill" : "bell").frame(maxWidth: .infinity) }
                nativeAction {
                    model.perform { detail["isFavourite"] = try await model.request("cloudFavorite", ["source": source, "comicId": comicId, "current": detail["isFavourite"] as? Bool == true]) }
                } label: { Label("云收藏", systemImage: detail["isFavourite"] as? Bool == true ? "cloud.fill" : "cloud").frame(maxWidth: .infinity) }
                    .disabled(detail["allowCollected"] as? Bool == false)
                NavigationLink { DCikeCommentsPage(source: source, comicId: comicId) } label: {
                    Label("评论", systemImage: "bubble").frame(maxWidth: .infinity)
                }.modifier(DCikeActionButtonStyle()).disabled(detail["allowComments"] as? Bool == false)
            }.font(.subheadline)
        }
    }
    private func nativeAction<L: View>(_ action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action, label: label).modifier(DCikeActionButtonStyle())
    }
    private var resumeIndex: Int {
        let history = map(detail["history"])
        return chapters.firstIndex { textValue($0["id"]) == textValue(history["chapterId"]) } ?? 0
    }
    private func load() async {
        loading = detail.isEmpty; error = nil
        if detail.isEmpty { reverse = map(model.settings["bookshelfSetting"])["reverseChapters"] as? Bool ?? false }
        do { detail = map(try await model.request("detail", ["source": source, "comicId": comicId])) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
    private func metadataValues(_ values: [[String: Any]]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                if !map(value["onTap"]).isEmpty {
                    NavigationLink { DCikeActionDestination(action: map(value["onTap"]), source: source) } label: { Text(textValue(value["name"])) }
                } else { Text(textValue(value["name"])).textSelection(.enabled) }
            }
        }
    }
    private func metadataTags(_ values: [[String: Any]]) -> some View {
        DCikeTagLayout(spacing: 8) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                if !map(value["onTap"]).isEmpty {
                    NavigationLink { DCikeActionDestination(action: map(value["onTap"]), source: source) } label: { tagLabel(value) }
                } else { tagLabel(value) }
            }
        }
    }
    private func tagLabel(_ value: [String: Any]) -> some View {
        Text(textValue(value["name"]))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.65)))
    }
    private func queueDownload() {
        model.perform {
            _ = try await model.request("download", ["source": source, "comicId": comicId, "chapters": selectedChapters.sorted().map { chapters[$0] }])
            selectedChapters = []; downloading = false; model.message = "已加入下载队列。"
        }
    }
}

@available(iOS 16.0, *)
private struct DCikeDetailHeroImage: View {
    @EnvironmentObject private var model: DCikeNativeModel
    let source: String
    let comicId: String
    let image: [String: Any]
    @State private var bitmap: UIImage?
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let bitmap { Image(uiImage: bitmap).resizable().scaledToFill() }
                else { Color(uiColor: .secondarySystemBackground) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: source + comicId + textValue(image["path"]) + textValue(image["url"])) {
            guard let path = try? await model.request("image", ["source": source, "comicId": comicId, "image": image]) as? String else { return }
            let loaded = await DCikeLoadImage(path: path)
            if !Task.isCancelled { bitmap = loaded }
        }
    }
}

@available(iOS 16.0, *)
private struct DCikeTagLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 0, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let limit = width.isFinite && width > 0 ? width : CGFloat.greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxWidth: CGFloat = 0
        var origins: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            if x > 0 && x + size.width > limit { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxWidth = max(maxWidth, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: min(limit, maxWidth), height: y + rowHeight), origins)
    }
}

@available(iOS 16.0, *)
struct DCikeActionButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}

struct DCikeReadingRoute: Identifiable { let id = UUID(); let index: Int }

@available(iOS 16.0, *)
struct DCikeReaderPage: View {
    @EnvironmentObject private var model: DCikeNativeModel
    @Environment(\.dismiss) private var dismiss
    let source: String
    let comicId: String
    let chapters: [[String: Any]]
    let initialIndex: Int
    @State private var chapterIndex = 0
    @State private var pages: [[String: Any]] = []
    @State private var pageIndex = 0
    @State private var chapterId = ""
    @State private var title = ""
    @State private var loading = true
    @State private var error: String?
    @State private var chrome = true
    @State private var showOptions = false
    @State private var zoom: CGFloat = 1
    @State private var scrollRequest = UUID()
    @State private var scrollAnchor: UnitPoint = .top
    @State private var pageFrames: [Int: CGRect] = [:]
    @State private var paused = false
    @State private var einkMask = false
    @State private var comicOverrides: [String: Any] = [:]
    @StateObject private var network = DCikeReaderNetwork()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    private var preferences: [String: Any] { map(model.settings["readSetting"]).merging(comicOverrides) { _, replacement in replacement } }
    private var mode: Int { preferences["readMode"] as? Int ?? 0 }
    private var reverse: Bool { mode == 2 }
    private var doublePage: Bool { preferences["doublePageMode"] as? Bool == true }
    private var spreads: [[Int]] {
        guard doublePage else { return pages.indices.map { [$0] } }
        var result: [[Int]] = []
        var start = 0
        if preferences["doublePageLeadingBlank"] as? Bool == true && !pages.isEmpty { result.append([-1, 0]); start = 1 }
        while start < pages.count { result.append([start, start + 1 < pages.count ? start + 1 : -1]); start += 2 }
        return result
    }
    private var slot: Binding<Int> {
        Binding(get: { spreads.firstIndex { $0.contains(pageIndex) } ?? 0 }, set: { value in
            if spreads.indices.contains(value), let page = spreads[value].first(where: { $0 >= 0 }) { pageIndex = page }
        })
    }
    private var animation: Animation? { preferences["noAnimation"] as? Bool == true ? nil : .easeInOut(duration: 0.26) }
    private var autoScroll: Bool { preferences["autoScroll"] as? Bool == true && !paused && !chrome && !loading && scenePhase == .active }
    private func number(_ key: String, _ fallback: Double) -> Double { (preferences[key] as? NSNumber)?.doubleValue ?? fallback }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background.ignoresSafeArea()
                if loading { ProgressView() }
                else if let error { VStack { Text(error); Button("重试") { Task { await load() } } }.padding() }
                else if mode == 0 { verticalReader(geometry: geometry) }
                else {
                    TabView(selection: slot) {
                        ForEach(Array(spreads.indices), id: \.self) { index in
                            readerSpread(spreads[index]).frame(width: geometry.size.width, height: geometry.size.height).tag(index)
                        }
                    }.tabViewStyle(.page(indexDisplayMode: .never))
                        .environment(\.layoutDirection, reverse ? .rightToLeft : .leftToRight)
                }
                if einkMask && mode != 0 { Color.white.allowsHitTesting(false) }
                if colorScheme == .dark && preferences["readFilterEnabled"] as? Bool == true {
                    Color.black.opacity(min(1, max(0, number("readFilterOpacityPercent", 50) / 100))).allowsHitTesting(false)
                }
                if !chrome { pageInformation }
                if preferences["autoScroll"] as? Bool == true && (paused || preferences["autoScrollHidePauseButton"] as? Bool != true) {
                    VStack { Spacer(); HStack { Spacer(); Button { paused.toggle() } label: { Image(systemName: paused ? "play.fill" : "pause.fill").padding(12) }.modifier(DCikeActionButtonStyle()).padding() } }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture(count: 1).onEnded { event in tap(event.location, size: geometry.size) })
            .task(id: autoScroll) {
                while autoScroll && !Task.isCancelled {
                    let milliseconds = max(100, number(mode == 0 ? "autoScrollColumnIntervalMs" : "autoScrollPageIntervalMs", mode == 0 ? 1600 : 3000))
                    do { try await Task.sleep(nanoseconds: UInt64(min(milliseconds, 600_000) * 1_000_000)) } catch { break }
                    if autoScroll { if mode == 0 { scrollBy(geometry.size.height * CGFloat(min(1, max(0.1, number("autoScrollColumnDistancePercent", 72) / 100))), viewport: geometry.size.height) } else { turn(1) } }
                }
            }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar(chrome ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭阅读器") }
            ToolbarItem(placement: .primaryAction) { Button { showOptions = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("阅读设置") }
        }
        .safeAreaInset(edge: .bottom) {
            if chrome {
                VStack(spacing: 6) {
                    HStack {
                        Button { changeChapter(-1) } label: { Image(systemName: "backward.end") }.disabled(chapterIndex == 0)
                        Slider(value: Binding(get: { Double(pageIndex) }, set: { jump(Int($0)) }), in: 0...Double(max(1, pages.count - 1)), step: 1).disabled(pages.count < 2)
                        Button { changeChapter(1) } label: { Image(systemName: "forward.end") }.disabled(chapterIndex + 1 >= chapters.count)
                    }
                    HStack {
                        Menu("章节") { ForEach(Array(chapters.indices), id: \.self) { index in Button(textValue(chapters[index]["name"])) { changeChapter(index - chapterIndex) } } }
                        Spacer()
                        Text("\(pages.isEmpty ? 0 : pageIndex + 1) / \(pages.count)").font(.caption).monospacedDigit()
                    }
                }.padding(.horizontal, 20).padding(.vertical, 10).background(.bar)
            }
        }
        .sheet(isPresented: $showOptions) { NavigationStack { DCikeReaderOptions(source: source, comicId: comicId, onUpdate: updateOverrides) }.environmentObject(model) }
        .task { UIDevice.current.isBatteryMonitoringEnabled = true; chapterIndex = min(max(0, initialIndex), max(0, chapters.count - 1)); if let result = try? await model.request("comicReadSettings", ["source": source, "comicId": comicId]) { updateOverrides(map(result)) }; await load() }
        .onChange(of: pageIndex) { value in
            zoom = 1
            guard !loading else { return }
            model.perform { _ = try await model.request("progress", ["page": value, "chapterId": chapterId]) }
        }
        .task(id: chapterId + ":" + String(pageIndex)) { await preload() }
        .task(id: "\(chapterId):\(pageIndex):\(mode):\(loading):\(preferences["einkOptimization"] as? Bool == true):\(number("einkDelayMs", 120))") {
            guard mode != 0 && preferences["einkOptimization"] as? Bool == true && !loading else { einkMask = false; return }
            einkMask = true
            do { try await Task.sleep(nanoseconds: UInt64(min(500, max(50, number("einkDelayMs", 120))) * 1_000_000)) }
            catch { return }
            einkMask = false
        }
        .onChange(of: scenePhase) { phase in if phase != .active { saveProgress() } }
        .onChange(of: preferences["landscapeReader"] as? Bool) { value in model.perform { _ = try await model.request("readerOrientation", ["landscape": value == true]) } }
        .onDisappear {
            let page = pageIndex; let chapter = chapterId
            model.perform { _ = try await model.request("endReading", ["page": page, "chapterId": chapter]) }
        }
    }
    private func updateOverrides(_ result: [String: Any]) {
        let effective = map(result["effective"])
        let keys = result["overrides"] as? [String] ?? []
        comicOverrides = effective.filter { keys.contains($0.key) }
    }
    private var background: Color {
        switch textValue(preferences["readerBackgroundMode"]) { case "black": return .black; case "white": return .white; case "grey": return Color(white: 0.18); default: return Color(uiColor: .systemBackground) }
    }
    private func readerImage(_ index: Int) -> some View {
        DCikeNativeImage(source: source, image: pages[index], comicId: comicId, chapterId: chapterId, page: true, index: index)
            .frame(maxWidth: .infinity).scaleEffect(zoom)
            .gesture(MagnificationGesture().onChanged { zoom = min(4, max(1, $0)) }.onEnded { _ in if zoom < 1.1 { zoom = 1 } })
            .onTapGesture(count: 2) {
                if preferences["doubleTapOpenMenu"] as? Bool == true { withAnimation { chrome.toggle() } }
                else if preferences["doubleTapZoom"] as? Bool == true { withAnimation { zoom = zoom > 1 ? 1 : 2.5 } }
            }
    }
    private func readerSpread(_ indices: [Int]) -> some View {
        HStack(spacing: preferences["doublePageSeamless"] as? Bool == true ? 0 : 8) {
            ForEach(Array(indices.enumerated()), id: \.offset) { _, index in
                if index >= 0 { readerImage(index).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Color.clear.frame(maxWidth: .infinity) }
            }
        }
        .padding(.horizontal, preferences["sidePaddingEnabled"] as? Bool == true ? CGFloat(min(200, max(0, number("sidePaddingPercent", 10))) * 2) : 0)
    }
    private func verticalReader(geometry: GeometryProxy) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(spreads.indices), id: \.self) { index in
                        readerSpread(spreads[index]).id(spreads[index].first(where: { $0 >= 0 }) ?? index)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: DCikeReaderPositionKey.self, value: [spreads[index].first(where: { $0 >= 0 }) ?? index: proxy.frame(in: .named("reader"))])
                            })
                    }
                    HStack { Button("上一章") { changeChapter(-1) }.disabled(chapterIndex == 0); Spacer(); Button("下一章") { changeChapter(1) }.disabled(chapterIndex + 1 >= chapters.count) }.padding(24)
                }
            }.coordinateSpace(name: "reader")
                .onPreferenceChange(DCikeReaderPositionKey.self) { positions in
                    pageFrames = positions
                    if let visible = positions.filter({ $0.value.minY <= geometry.size.height / 2 && $0.value.maxY > 0 }).max(by: { $0.value.minY < $1.value.minY }) { pageIndex = visible.key }
                }
                .onChange(of: scrollRequest) { _ in
                    withAnimation(preferences["autoScrollSmooth"] as? Bool == true ? .linear(duration: 0.4) : animation) { scroll.scrollTo(pageIndex, anchor: scrollAnchor) }
                }
                .onAppear { scroll.scrollTo(pageIndex, anchor: .top) }
        }
    }
    private func load() async {
        guard chapters.indices.contains(chapterIndex) else { loading = false; return }
        loading = true; error = nil; zoom = 1
        do {
            let result = map(try await model.request("chapter", ["source": source, "comicId": comicId, "chapter": chapters[chapterIndex]]))
            pages = rows(result["pages"]); chapterId = textValue(result["id"]); title = textValue(result["title"])
            pageIndex = min(max(0, result["pageIndex"] as? Int ?? 0), max(0, pages.count - 1))
            if pages.isEmpty { error = "该章节没有可阅读的图片。" }
        } catch { self.error = error.localizedDescription }
        loading = false
        scrollAnchor = .top; scrollRequest = UUID()
        model.perform { _ = try await model.request("readerOrientation", ["landscape": preferences["landscapeReader"] as? Bool == true]) }
    }
    private func changeChapter(_ delta: Int) {
        let next = chapterIndex + delta
        guard chapters.indices.contains(next) else { return }
        guard !loading else { return }
        Task {
            _ = try? await model.request("saveReading", ["page": pageIndex, "chapterId": chapterId])
            chapterIndex = next
            await load()
        }
    }
    private func saveProgress() { let page = pageIndex; let chapter = chapterId; model.perform { _ = try await model.request("saveReading", ["page": page, "chapterId": chapter]) } }
    private func jump(_ page: Int) { pageIndex = min(max(0, page), max(0, pages.count - 1)); scrollAnchor = .top; scrollRequest = UUID() }
    private func turn(_ delta: Int) {
        let currentSlot = spreads.firstIndex { $0.contains(pageIndex) } ?? 0
        let next = currentSlot + delta
        if spreads.indices.contains(next), let first = spreads[next].first(where: { $0 >= 0 }) { withAnimation(animation) { jump(first) } }
        else { changeChapter(delta) }
    }
    private func scrollBy(_ distance: CGFloat, viewport: CGFloat) {
        guard let frame = pageFrames[pageIndex], frame.height.isFinite, viewport.isFinite else { jump(pageIndex + (distance > 0 ? 1 : -1)); return }
        let target = -frame.minY + distance
        if target >= frame.height { if pageIndex + 1 < pages.count { jump(pageIndex + 1) } else { changeChapter(1) } }
        else if target < 0 { jump(pageIndex - 1) }
        else if abs(frame.height - viewport) > 1 {
            scrollAnchor = UnitPoint(x: 0.5, y: min(1, max(0, target / (frame.height - viewport)))); scrollRequest = UUID()
        } else { jump(pageIndex + (distance > 0 ? 1 : -1)) }
    }
    private func tap(_ point: CGPoint, size: CGSize) {
        guard zoom == 1 else { return }
        let center = point.x > size.width / 3 && point.x < size.width * 2 / 3 && point.y > size.height / 3 && point.y < size.height * 2 / 3
        if center || (mode == 0 && preferences["tapPageTurnInWebtoon"] as? Bool != true) {
            if preferences["doubleTapOpenMenu"] as? Bool != true || chrome { withAnimation { chrome.toggle() } }
            return
        }
        let tapMode = textValue(preferences["tapPageTurnMode"])
        let next = tapMode == "fullScreen" || (tapMode == "leftHand" ? (mode == 0 ? point.y < size.height / 2 : point.x < size.width / 2) : (mode == 0 ? point.y >= size.height / 2 : point.x >= size.width / 2))
        var delta = next ? 1 : -1
        if mode != 0 && preferences["reverseHorizontalPageTurn"] as? Bool == true { delta = -delta }
        if mode == 0 { scrollBy(CGFloat(delta) * size.height * 0.72, viewport: size.height) } else { turn(delta) }
    }
    private func preload() async {
        guard !pages.isEmpty, pageIndex < pages.count else { return }
        let count = min(20, max(0, Int(number("preloadImageCount", 3))))
        let chapter = chapterId
        for index in (pageIndex + 1)..<min(pages.count, pageIndex + 1 + count) {
            guard !Task.isCancelled, chapter == chapterId else { return }
            _ = try? await model.request("image", ["source": source, "comicId": comicId, "chapterId": chapter, "image": pages[index], "page": true, "index": index])
        }
        let chapterCount = min(3, max(0, Int(number("preloadChapterCount", 1))))
        let currentChapter = chapterIndex
        guard chapterCount > 0, currentChapter + 1 < chapters.count else { return }
        for index in (currentChapter + 1)..<min(chapters.count, currentChapter + 1 + chapterCount) {
            guard !Task.isCancelled, currentChapter == chapterIndex, chapter == chapterId else { return }
            _ = try? await model.request("prefetchChapter", ["source": source, "comicId": comicId, "chapter": chapters[index]])
        }
    }
    private var pageInformation: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack {
                if textValue(preferences["pageInfoVerticalPosition"]) != "top" { Spacer() }
                HStack {
                    if textValue(preferences["pageInfoHorizontalPosition"]) != "left" { Spacer() }
                    HStack(spacing: 10) {
                        if preferences["pageInfoShowPage"] as? Bool != false { Text("\(pageIndex + 1)/\(pages.count)") }
                        if preferences["pageInfoShowNetwork"] as? Bool != false { Image(systemName: network.symbol) }
                        if preferences["pageInfoShowBattery"] as? Bool == true && UIDevice.current.batteryLevel >= 0 { Text("\(Int(UIDevice.current.batteryLevel * 100))%") }
                        if preferences["pageInfoShowTime"] as? Bool != false { Text(context.date, style: .time) }
                    }.font(.system(size: CGFloat(min(32, max(8, number("pageInfoFontSize", 12)))))).monospacedDigit()
                    if textValue(preferences["pageInfoHorizontalPosition"]) != "right" { Spacer() }
                }.padding(CGFloat(min(80, max(0, number("pageInfoEdgePadding", 12))))).opacity(min(1, max(0, number("pageInfoOpacityPercent", 82) / 100)))
                if textValue(preferences["pageInfoVerticalPosition"]) == "top" { Spacer() }
            }
            .ignoresSafeArea(edges: textValue(preferences["pageInfoVerticalPosition"]) == "top" && preferences["pageInfoTopInStatusBar"] as? Bool == true ? .top : [])
            .allowsHitTesting(false)
        }
    }
}

private struct DCikeReaderPositionKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) { value.merge(nextValue()) { _, new in new } }
}

@available(iOS 16.0, *)
struct DCikeReaderOptions: View {
    @EnvironmentObject var model: DCikeNativeModel
    @Environment(\.dismiss) var dismiss
    let source: String
    let comicId: String
    let onUpdate: ([String: Any]) -> Void
    var body: some View {
        Form {
            NavigationLink { DCikePreferenceEditor(page: .reader) } label: { Label("通用设置、手势与信息条", systemImage: "slider.horizontal.3") }
            NavigationLink { DCikePreferenceEditor(page: .reader, comicSource: source, comicId: comicId, onComicUpdate: onUpdate) } label: { Label("本漫画设置", systemImage: "book") }
        }.navigationTitle("阅读设置").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}

@available(iOS 16.0, *)
private struct DCikePerComicReaderOptions: View {
    @EnvironmentObject private var model: DCikeNativeModel
    let source: String
    let comicId: String
    let onUpdate: ([String: Any]) -> Void
    @State private var values: [String: Any] = [:]
    @State private var changedKeys: Set<String> = []
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        Form {
            Section("阅读模式") {
                Picker("阅读方式", selection: integer("readMode", 0)) {
                    Text("上下滚动").tag(0); Text("从左向右翻页").tag(1); Text("从右向左翻页").tag(2)
                }
                Toggle("反向横向翻页", isOn: boolean("reverseHorizontalPageTurn"))
            }
            Section("自动阅读") {
                Toggle("自动滚动", isOn: boolean("autoScroll"))
                Toggle("平滑自动滚动", isOn: boolean("autoScrollSmooth"))
                Toggle("隐藏暂停按钮", isOn: boolean("autoScrollHidePauseButton"))
                numeric("滚动间隔（毫秒）", "autoScrollColumnIntervalMs", 1600)
                numeric("翻页间隔（毫秒）", "autoScrollPageIntervalMs", 3000)
                numeric("每次滚动距离（%）", "autoScrollColumnDistancePercent", 72)
            }
            Section("翻页模式") {
                Picker("点击翻页区域", selection: string("tapPageTurnMode", "rightHand")) {
                    Text("全屏").tag("fullScreen"); Text("左手").tag("leftHand"); Text("右手").tag("rightHand")
                }
                Toggle("连续阅读时点击翻页", isOn: boolean("tapPageTurnInWebtoon"))
            }
            Section { Button("恢复跟随全局设置", role: .destructive) { Task { await update(reset: true) } } }
        }
        .disabled(!loaded || saving)
        .navigationTitle("本漫画设置")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { Task { await update(reset: false) } }.disabled(!loaded || saving) } }
        .task { await fetch() }
        .alert("设置未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好", role: .cancel) {} } message: { Text(error ?? "") }
    }
    private func boolean(_ key: String) -> Binding<Bool> { Binding(get: { values[key] as? Bool ?? false }, set: { values[key] = $0; changedKeys.insert(key) }) }
    private func integer(_ key: String, _ fallback: Int) -> Binding<Int> { Binding(get: { values[key] as? Int ?? fallback }, set: { values[key] = $0; changedKeys.insert(key) }) }
    private func string(_ key: String, _ fallback: String) -> Binding<String> { Binding(get: { values[key] as? String ?? fallback }, set: { values[key] = $0; changedKeys.insert(key) }) }
    private func numeric(_ title: String, _ key: String, _ fallback: Int) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: integer(key, fallback), format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
    }
    private func fetch() async {
        do { let result = map(try await model.request("comicReadSettings", ["source": source, "comicId": comicId])); values = map(result["effective"]); onUpdate(result); loaded = true }
        catch { self.error = error.localizedDescription }
    }
    private func update(reset: Bool) async {
        saving = true
        defer { saving = false }
        do {
            let result = map(try await model.request("comicReadSettings", ["source": source, "comicId": comicId, "reset": reset, "patch": values.filter { changedKeys.contains($0.key) }]))
            values = map(result["effective"]); changedKeys = []; onUpdate(result)
        } catch { self.error = error.localizedDescription }
    }
}

@available(iOS 16.0, *)
struct DCikeLibraryPage: View {
    @EnvironmentObject var model: DCikeNativeModel
    @State private var kind = "favorite"
    @State private var items: [[String: Any]] = []
    @State private var query = ""
    @State private var initialized = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("书架内容", selection: $kind) { Text("收藏").tag("favorite"); Text("历史").tag("history"); Text("下载").tag("download"); Text("追更").tag("follow") }.pickerStyle(.segmented)
                if kind == "favorite" {
                    DCikeFavoriteFolderContent(path: "", query: query)
                } else {
                    if items.isEmpty { Label("这里还没有漫画", systemImage: "books.vertical").foregroundStyle(.secondary).padding(.top, 70) }
                    DCikeComicGrid(items: items.filter { query.isEmpty || textValue($0["title"]).localizedCaseInsensitiveContains(query) })
                }
            }.padding(20)
        }.navigationTitle("书架").searchable(text: $query, prompt: "查找书架中的漫画")
            .toolbar { NavigationLink { DCikeDownloadTasksPage() } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("下载任务") }
            .task(id: kind + String(model.revision)) {
                if !initialized {
                    let index = map(model.settings["bookshelfSetting"])["homePageIndex"] as? Int ?? 0
                    kind = ["favorite", "history", "download", "follow"][min(3, max(0, index))]
                    initialized = true
                }
                await load()
            }.refreshable { await load() }
    }
    private func load() async { do { items = rows(try await model.request("library", ["kind": kind])) } catch { model.message = error.localizedDescription } }
}

@available(iOS 16.0, *)
struct DCikeFavoriteFolderContent: View {
    @EnvironmentObject private var model: DCikeNativeModel
    let path: String
    var query = ""
    @State private var folders: [[String: Any]] = []
    @State private var items: [[String: Any]] = []
    @State private var destinations: [[String: Any]] = []
    @State private var folderName = ""
    @State private var creating = false
    @State private var movingKey: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if !path.isEmpty { Text(path.split(separator: "/").last.map(String.init) ?? "收藏").font(.headline) }
                Spacer()
                Button { folderName = ""; creating = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
            }
            ForEach(Array(folders.enumerated()), id: \.offset) { _, folder in
                let folderPath = textValue(folder["path"])
                NavigationLink {
                    ScrollView { DCikeFavoriteFolderContent(path: folderPath).padding(20) }
                        .navigationTitle(textValue(folder["name"])).navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label(textValue(folder["name"]), systemImage: "folder.fill")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.buttonStyle(.plain)
            }
            if items.isEmpty && folders.isEmpty { Label("这里还没有漫画", systemImage: "books.vertical").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 50) }
            DCikeComicGrid(items: items.filter { query.isEmpty || textValue($0["title"]).localizedCaseInsensitiveContains(query) }, moveToFolder: { item in movingKey = textValue(item["uniqueKey"]) })
        }
        .task(id: model.revision) { await load() }
        .alert("新建文件夹", isPresented: $creating) {
            TextField("文件夹名称", text: $folderName)
            Button("取消", role: .cancel) { }
            Button("创建") { model.perform { _ = try await model.request("createFavoriteFolder", ["path": path, "name": folderName]); await load() } }
        }
        .confirmationDialog("移动到文件夹", isPresented: Binding(get: { movingKey != nil }, set: { if !$0 { movingKey = nil } }), titleVisibility: .visible) {
            ForEach(Array(destinations.enumerated()), id: \.offset) { _, folder in
                let target = textValue(folder["path"])
                if target != path {
                    Button(textValue(folder["name"])) {
                        let key = movingKey ?? ""
                        movingKey = nil
                        model.perform { _ = try await model.request("moveFavorite", ["path": path, "target": target, "key": key]); await load() }
                    }
                }
            }
            Button("取消", role: .cancel) { movingKey = nil }
        }
    }
    private func load() async {
        do {
            let result = map(try await model.request("favoriteFolder", ["path": path]))
            folders = rows(result["folders"]); items = rows(result["items"]); destinations = rows(result["destinations"])
        } catch { model.message = error.localizedDescription }
    }
}

@available(iOS 16.0, *)
struct DCikeDownloadTasksPage: View {
    @EnvironmentObject var model: DCikeNativeModel
    @State private var items: [[String: Any]] = []
    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.offset) { _, task in
                VStack(alignment: .leading, spacing: 8) {
                    Text(textValue(task["title"]))
                    Text(textValue(task["status"])).font(.caption).foregroundStyle(.secondary)
                    if task["completed"] as? Bool != true {
                        Button("重试") { model.perform { _ = try await model.request("retryTask", ["id": task["id"] ?? 0]); await load() } }
                    }
                }
            }
            if items.isEmpty { Text("暂无下载任务").foregroundStyle(.secondary) }
        }.navigationTitle("下载任务").refreshable { await load() }
            .task { while !Task.isCancelled { await load(); try? await Task.sleep(nanoseconds: 2_000_000_000) } }
    }
    private func load() async { do { items = rows(try await model.request("tasks")) } catch { model.message = error.localizedDescription } }
}

@available(iOS 16.0, *)
struct DCikeCommentsPage: View {
    @EnvironmentObject var model: DCikeNativeModel
    let source: String
    let comicId: String
    var parentId: String = ""
    var parentExtern: [String: Any] = [:]
    var embedded: [[String: Any]]? = nil
    var replyAllowed = false
    @State private var items: [[String: Any]] = []
    @State private var page = 1
    @State private var reachedEnd = false
    @State private var content = ""
    @State private var canPost = false
    @State private var replyMode = "lazy"
    var body: some View {
        List {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(textValue(map(item["user"])["name"] ?? map(item["author"])["name"] ?? item["username"])).font(.headline); Spacer(); Text(textValue(item["createdAt"])).font(.caption).foregroundStyle(.secondary) }
                    Text(textValue(item["content"])).textSelection(.enabled)
                    if parentId.isEmpty {
                        NavigationLink("回复") {
                            DCikeCommentsPage(source: source, comicId: comicId, parentId: textValue(item["id"]), parentExtern: map(item["extern"]), embedded: replyMode == "embedded" ? rows(item["replies"]) : nil, replyAllowed: canPostReply)
                        }.font(.caption)
                    }
                }.padding(.vertical, 6)
            }
            if items.isEmpty { Text("暂无评论").foregroundStyle(.secondary) }
            if !reachedEnd { Button("加载更多") { model.perform { try await load(next: true) } } }
        }.navigationTitle(parentId.isEmpty ? "评论" : "回复")
            .safeAreaInset(edge: .bottom) {
                if canPost {
                    HStack { TextField("写评论", text: $content, axis: .vertical).lineLimit(1...4); Button("发送") { post() }.disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding().background(.bar)
                }
            }
            .task { do { try await load() } catch { model.message = error.localizedDescription } }
            .refreshable { do { try await load() } catch { model.message = error.localizedDescription } }
    }
    private func load(next: Bool = false) async throws {
        let target = next ? page + 1 : 1
        var core: [String: Any] = ["comicId": comicId, "page": target]
        if !parentId.isEmpty { core["commentId"] = parentId }
        if let embedded, !parentId.isEmpty {
            items = embedded; reachedEnd = true; canPost = replyAllowed; return
        }
        let response = try await model.plugin(source, parentId.isEmpty ? "getCommentFeed" : "loadCommentReplies", core, parentId.isEmpty ? [:] : parentExtern)
        let data = map(response["data"])
        let fetched = (next ? [] : rows(data["topItems"])) + rows(data["items"])
        if next { items += fetched } else { items = fetched }
        page = target; reachedEnd = map(data["paging"])["hasReachedMax"] as? Bool == true || fetched.isEmpty
        let permissions = map(data["canComment"])
        if parentId.isEmpty {
            canPost = permissions["comic"] as? Bool ?? false
            canPostReply = permissions["reply"] as? Bool ?? false
            replyMode = textValue(data["replyMode"])
        } else { canPost = replyAllowed }
    }
    private func post() {
        model.perform {
            var core: [String: Any] = ["comicId": comicId, "content": content]
            if !parentId.isEmpty { core["commentId"] = parentId }
            _ = try await model.plugin(source, parentId.isEmpty ? "postComment" : "postCommentReply", core, parentId.isEmpty ? [:] : parentExtern)
            content = ""; try await load()
        }
    }
    @State private var canPostReply = false
}
