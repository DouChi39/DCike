import SwiftUI
import Flutter

func map(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
func rows(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
func textValue(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    return String(describing: value)
}

func DCikeLoadImage(path: String) async -> UIImage? {
    await Task.detached(priority: .userInitiated) {
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        return image.preparingForDisplay() ?? image
    }.value
}

@MainActor
final class DCikeNativeModel: ObservableObject {
    let channel: FlutterMethodChannel
    @Published var settings: [String: Any] = [:] { didSet { onSettingsChanged?(settings) } }
    @Published var plugins: [[String: Any]] = []
    @Published var message: String?
    @Published var input: DCikeInputRequest?
    @Published var ready = false
    @Published var revision = 0
    @Published var bootstrapComplete = false
    @Published var lockRequired = false
    @Published var lockUnlocked = false
    private var inputReply: FlutterResult?
    @Published private(set) var inputPresented = false
    private var queuedInput: (DCikeInputRequest, FlutterResult)?
    var onUnlock: (() -> Void)?
    var onSettingsChanged: (([String: Any]) -> Void)?

    init(channel: FlutterMethodChannel) { self.channel = channel }

    func request(_ method: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            channel.invokeMethod(method, arguments: args) { response in
                if let error = response as? FlutterError {
                    continuation.resume(throwing: NSError(domain: error.code, code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error.message ?? "操作未完成，请重试。 "]))
                } else if (response as AnyObject?) === (FlutterMethodNotImplemented as AnyObject) {
                    continuation.resume(throwing: NSError(domain: "DCike", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "当前版本尚不支持此操作。 "]))
                } else { continuation.resume(returning: response) }
            }
        }
    }

    func plugin(_ source: String, _ fn: String, _ core: [String: Any] = [:],
                _ extern: [String: Any] = [:]) async throws -> [String: Any] {
        map(try await request("plugin", ["source": source, "fn": fn, "core": core, "extern": extern]))
    }

    func refresh() async {
        do {
            let value = map(try await request("bootstrap"))
            settings = map(value["settings"])
            plugins = rows(value["plugins"])
            ready = true
            revision += 1
        } catch { message = error.localizedDescription }
    }

    func perform(_ work: @escaping () async throws -> Void) {
        Task { do { try await work() } catch { message = error.localizedDescription } }
    }

    func ask(_ schema: [String: Any], reply: @escaping FlutterResult) {
        if inputPresented && input == nil {
            queuedInput = (DCikeInputRequest(schema: schema), reply)
            return
        }
        inputReply?(["cancelled": true])
        inputReply = reply
        input = DCikeInputRequest(schema: schema)
        inputPresented = true
    }

    func answer(_ value: [String: Any]) {
        let reply = inputReply
        inputReply = nil
        input = nil
        reply?(value)
    }

    func inputDismissed() {
        inputPresented = false
        if inputReply != nil { answer(["cancelled": true]) }
        if let pending = queuedInput {
            queuedInput = nil
            inputReply = pending.1
            input = pending.0
            inputPresented = true
        }
    }

    func unlockCompleted() {
        lockUnlocked = true
        lockRequired = false
        onUnlock?()
    }
}

struct DCikeInputRequest: Identifiable {
    let id = UUID()
    let schema: [String: Any]
}

@MainActor
final class DCikeNativeCoordinator {
    private let model: DCikeNativeModel
    private var host: UIViewController?
    private var unlockReply: FlutterResult?
    init(messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(name: "dcike/swiftui", binaryMessenger: messenger)
        model = DCikeNativeModel(channel: channel)
        model.onUnlock = { [weak self] in self?.finishUnlock() }
        channel.setMethodCallHandler { [weak self] call, reply in
            guard let self else { reply(FlutterMethodNotImplemented); return }
            switch call.method {
            case "mount": self.mount(reply: reply)
            case "changed": Task { await self.model.refresh() }; reply(nil)
            case "input": self.model.ask(map(call.arguments), reply: reply)
            case "notice": self.model.message = textValue(map(call.arguments)["message"]); reply(nil)
            case "completeBootstrap":
                Task {
                    await self.model.refresh()
                    let lock = map(self.model.settings["appLockSetting"])
                    let enabled = lock["enabled"] as? Bool == true
                    let ready = !textValue(lock["gesturePasswordHash"]).isEmpty && !textValue(lock["resetPinHash"]).isEmpty
                    self.model.lockRequired = enabled && ready
                    self.model.bootstrapComplete = true
                    if self.model.lockRequired {
                        self.unlockReply = reply
                    } else {
                        reply(true)
                    }
                }
            default: reply(FlutterMethodNotImplemented)
            }
        }
    }

    private func finishUnlock() {
        unlockReply?(true)
        unlockReply = nil
    }

    private func mount(reply: @escaping FlutterResult) {
        if host != nil { reply(true); return }
        guard #available(iOS 16.0, *) else { reply(false); return }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
            let parent = window.rootViewController else {
            reply(FlutterError(code: "NO_WINDOW", message: "无法打开 iOS 界面，请重新启动。", details: nil)); return
        }
        let controller = UIHostingController(rootView: DCikeNativeRoot().environmentObject(model))
        model.onSettingsChanged = { [weak controller] settings in
            switch textValue(settings["themeMode"]) {
            case "light": controller?.overrideUserInterfaceStyle = .light
            case "dark": controller?.overrideUserInterfaceStyle = .dark
            default: controller?.overrideUserInterfaceStyle = .unspecified
            }
        }
        model.onSettingsChanged?(model.settings)
        parent.addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        parent.view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: parent.view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: parent.view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: parent.view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: parent.view.bottomAnchor)
        ])
        controller.didMove(toParent: parent)
        host = controller
        reply(true)
    }
}

@available(iOS 16.0, *)
struct DCikeNativeRoot: View {
    @EnvironmentObject private var model: DCikeNativeModel
    @State private var selected = 0
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if !model.ready || !model.bootstrapComplete {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在准备 DCike…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.lockRequired && !model.lockUnlocked {
                DCikeLockGate()
            } else {
                applicationTabs
            }
        }
        .tint(.blue)
        .preferredColorScheme(colorScheme)
        .onChange(of: model.bootstrapComplete) { complete in
            if complete { selected = min(4, max(0, model.settings["welcomePageNum"] as? Int ?? 0)) }
        }
        .onChange(of: scenePhase) { phase in if phase == .active && model.bootstrapComplete { Task { await model.refresh() } } }
        .alert("DCike", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
        .sheet(item: $model.input, onDismiss: { model.inputDismissed() }) { request in
            DCikeWorkflowInput(schema: request.schema).environmentObject(model)
        }
    }
    private var applicationTabs: some View {
        TabView(selection: $selected) {
            NavigationStack { DCikeHomePage() }.tabItem { Label("首页", systemImage: "house") }.tag(0)
            NavigationStack { DCikeHomePage(cloud: true) }.tabItem { Label("云收藏", systemImage: "cloud") }.tag(1)
            NavigationStack { DCikeLibraryPage() }.tabItem { Label("书架", systemImage: "books.vertical") }.tag(2)
            NavigationStack { DCikeDiscoverPage() }.tabItem { Label("发现", systemImage: "safari") }.tag(3)
            NavigationStack { DCikeSettingsPage() }.tabItem { Label("设置", systemImage: "gearshape") }.tag(4)
        }
        .modifier(DCikeScrollEdgeStyle())
    }
    private var colorScheme: ColorScheme? {
        switch textValue(model.settings["themeMode"]) { case "light": return .light; case "dark": return .dark; default: return nil }
    }
}

@available(iOS 16.0, *)
private struct DCikeScrollEdgeStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            content
        }
    }
}

// Older iOS versions use native SwiftUI controls without Liquid Glass.
private struct DCikeLegacyRoot: View {
    @EnvironmentObject var model: DCikeNativeModel
    var body: some View {
        NavigationView {
            List {
                Text("DCike 的完整原生界面需要 iOS 16 或更高版本。")
                Text("系统液态玻璃效果需要 iOS 26 或更高版本。")
            }.navigationTitle("DCike")
        }
    }
}

@available(iOS 16.0, *)
struct DCikeNativeImage: View {
    @EnvironmentObject private var model: DCikeNativeModel
    let source: String
    let image: [String: Any]
    var comicId: String = ""
    var chapterId: String = ""
    var page: Bool = false
    var index: Int = 0
    @State private var bitmap: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let bitmap { Image(uiImage: bitmap).resizable().aspectRatio(contentMode: .fit) }
            else if failed { Image(systemName: "photo").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80) }
            else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .task(id: source + comicId + chapterId + textValue(image["path"]) + textValue(image["url"])) {
            do {
                let path = textValue(try await model.request("image", ["source": source, "image": image,
                    "comicId": comicId, "chapterId": chapterId, "page": page, "index": index]))
                if Task.isCancelled { return }
                let loaded = await DCikeLoadImage(path: path)
                if Task.isCancelled { return }
                bitmap = loaded
                failed = bitmap == nil
            } catch { failed = true }
        }
        .accessibilityLabel(page ? "漫画第 \(index + 1) 页" : "漫画封面")
    }
}

@available(iOS 16.0, *)
struct DCikeWorkflowInput: View {
    @EnvironmentObject var model: DCikeNativeModel
    let schema: [String: Any]
    @State private var selected: Set<String> = []
    @State private var value = ""
    @State private var values: [String: String] = [:]
    private var kind: String { textValue(schema["type"]) }
    var body: some View {
        NavigationStack {
            Form {
                if !textValue(schema["description"]).isEmpty { Text(textValue(schema["description"])) }
                if kind == "select" {
                    ForEach(Array(rows(schema["options"]).enumerated()), id: \.offset) { _, option in
                        Button {
                            let id = textValue(option["id"])
                            if textValue(schema["selection"]) != "multiple" { selected = [id] }
                            else if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(textValue(option["label"]))
                                    if !textValue(option["description"]).isEmpty { Text(textValue(option["description"])).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if selected.contains(textValue(option["id"])) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    if schema["allowCreate"] as? Bool == true { TextField("新建收藏夹", text: $value) }
                } else if kind == "form" {
                    ForEach(Array(rows(schema["fields"]).enumerated()), id: \.offset) { _, field in
                        TextField(textValue(field["label"] ?? field["title"]), text: Binding(get: { values[textValue(field["key"])] ?? "" }, set: { values[textValue(field["key"])] = $0 }))
                    }
                } else if kind != "confirm" { TextField(textValue(schema["title"]), text: $value) }
            }
            .navigationTitle(textValue(schema["title"]).isEmpty ? "云收藏" : textValue(schema["title"]))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { model.answer(["cancelled": true]) } }
                ToolbarItem(placement: .confirmationAction) { Button("确定") { submit() }.disabled(invalid) }
            }
        }
        .onAppear { selected = Set(rows(schema["options"]).filter { $0["selected"] as? Bool == true }.map { textValue($0["id"]) }) }
        .interactiveDismissDisabled()
    }
    private var invalid: Bool {
        schema["required"] as? Bool == true && ((kind == "select" && selected.isEmpty && value.isEmpty) || (kind == "text" && value.isEmpty))
    }
    private func submit() {
        var result: [String: Any] = ["key": textValue(schema["key"])]
        if kind == "select" {
            result["value"] = textValue(schema["selection"]) == "multiple" ? Array(selected).sorted() : selected.first ?? ""
            if !value.isEmpty { result["created"] = value }
        } else if kind == "confirm" { result["value"] = true }
        else if kind == "form" { result["value"] = values; result["values"] = values }
        else { result["value"] = value }
        model.answer(result)
    }
}
