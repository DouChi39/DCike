import CryptoKit
import SwiftUI

/// Native app-lock settings and the non-dismissible gate shown before the app.
/// Hash formats intentionally match lib/widgets/gesture_lock.dart.
@available(iOS 16.0, *)
struct DCikeAppLockSettings: View {
    @EnvironmentObject private var model: DCikeNativeModel
    @State private var showingSetup = false
    @State private var showingPinSetup = false
    @State private var confirmingRemoval = false
    @State private var busy = false

    private var lock: [String: Any] { map(model.settings["appLockSetting"]) }
    private var enabled: Bool { lock["enabled"] as? Bool == true }
    private var gestureHash: String { textValue(lock["gesturePasswordHash"]) }
    private var pinHash: String { textValue(lock["resetPinHash"]) }
    private var isReady: Bool { !gestureHash.isEmpty && !pinHash.isEmpty }

    var body: some View {
        Form {
            Section {
                Toggle("启用应用锁", isOn: Binding(
                    get: { enabled },
                    set: { setEnabled($0) }
                ))
                .disabled(busy)
                Text("每次启动应用时需要验证手势密码。忘记手势时，可使用重置 PIN 清除应用锁。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("密码管理") {
                Button {
                    showingSetup = true
                } label: {
                    Label(isReady ? "修改手势密码" : "设置手势密码", systemImage: "hand.draw")
                }
                .disabled(busy)

                if isReady {
                    Button {
                        showingPinSetup = true
                    } label: {
                        Label("修改重置 PIN", systemImage: "number")
                    }
                    .disabled(busy)

                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Label("删除应用锁", systemImage: "trash")
                    }
                    .disabled(busy)
                }
            }
        }
        .navigationTitle("应用锁")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSetup) {
            NavigationStack { DCikeLockSetupFlow() }
                .environmentObject(model)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showingPinSetup) {
            NavigationStack { DCikePinSetupFlow() }
                .environmentObject(model)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("删除应用锁？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("删除应用锁", role: .destructive) { removeLock() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后，打开 DCike 时将不再要求手势验证。")
        }
    }

    private func setEnabled(_ value: Bool) {
        if value && !isReady {
            showingSetup = true
            return
        }
        busy = true
        model.perform {
            do {
                try await Self.save(model: model, enabled: value,
                                    gestureHash: gestureHash, pinHash: pinHash)
                busy = false
            } catch {
                model.message = error.localizedDescription
                busy = false
            }
        }
    }

    private func removeLock() {
        busy = true
        model.perform {
            do {
                try await Self.save(model: model, enabled: false, gestureHash: "", pinHash: "")
                busy = false
            } catch {
                model.message = error.localizedDescription
                busy = false
            }
        }
    }

    fileprivate static func save(model: DCikeNativeModel, enabled: Bool,
                                 gestureHash: String, pinHash: String) async throws {
        let lock: [String: Any] = [
            "enabled": enabled,
            "gesturePasswordHash": gestureHash,
            "resetPinHash": pinHash
        ]
        _ = try await model.request("settings", ["patch": ["appLockSetting": lock]])
        await model.refresh()
    }
}

@available(iOS 16.0, *)
private struct DCikeLockSetupFlow: View {
    @EnvironmentObject private var model: DCikeNativeModel
    @Environment(\.dismiss) private var dismiss
    @State private var firstPattern: [Int]?
    @State private var pattern: [Int] = []
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var stage = 0
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            Text(stage == 0 ? "设置手势密码" : stage == 1 ? "确认手势密码" : "设置重置 PIN")
                .font(.title2.weight(.semibold))
            Text(instruction)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 40)

            if stage < 2 {
                DCikePatternBoard { points in
                    guard points.count >= 4 else {
                        error = "至少连接 4 个点。"
                        return
                    }
                    if stage == 0 {
                        firstPattern = points
                        stage = 1
                        error = nil
                    } else if points == firstPattern {
                        pattern = points
                        stage = 2
                        error = nil
                    } else {
                        firstPattern = nil
                        stage = 0
                        error = "两次手势不一致，请重新设置。"
                    }
                }
                .frame(maxWidth: 300)
                .aspectRatio(1, contentMode: .fit)
            } else {
                VStack(spacing: 14) {
                    SecureField("至少 4 位数字", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: pin) { pin = String($0.filter { $0 >= "0" && $0 <= "9" }) }
                    SecureField("再次输入 PIN", text: $confirmation)
                        .keyboardType(.numberPad)
                        .textContentType(.newPassword)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: confirmation) { confirmation = String($0.filter { $0 >= "0" && $0 <= "9" }) }
                    Button("保存应用锁") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                }
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if busy { ProgressView() }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("应用锁")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .interactiveDismissDisabled(busy)
    }

    private var instruction: String {
        switch stage {
        case 0: return "在九宫格上按住并滑动，至少连接 4 个点。"
        case 1: return "请再次画出相同的手势。"
        default: return "设置 PIN 后，忘记手势时可验证 PIN 并清除应用锁。"
        }
    }

    private func save() {
        guard pin.count >= 4 else { error = "PIN 至少需要 4 位数字。"; return }
        guard pin == confirmation else { error = "两次 PIN 不一致，请重新输入。"; return }
        guard !pattern.isEmpty else { error = "请先完成手势密码设置。"; return }
        busy = true
        error = nil
        let gestureHash = DCikeLockHash.gesture(pattern)
        let resetPinHash = DCikeLockHash.pin(pin)
        model.perform {
            do {
                try await DCikeAppLockSettings.save(model: model, enabled: true,
                                                    gestureHash: gestureHash, pinHash: resetPinHash)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

@available(iOS 16.0, *)
private struct DCikePinSetupFlow: View {
    @EnvironmentObject private var model: DCikeNativeModel
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("重置 PIN") {
                SecureField("至少 4 位数字", text: $pin)
                    .keyboardType(.numberPad)
                    .onChange(of: pin) { pin = String($0.filter { $0 >= "0" && $0 <= "9" }) }
                SecureField("再次输入 PIN", text: $confirmation)
                    .keyboardType(.numberPad)
                    .onChange(of: confirmation) { confirmation = String($0.filter { $0 >= "0" && $0 <= "9" }) }
                Text("忘记手势密码时，需要输入此 PIN 才能清除应用锁。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            Section {
                Button("保存 PIN") { save() }
                    .disabled(busy)
            }
        }
        .navigationTitle("修改重置 PIN")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .interactiveDismissDisabled(busy)
    }

    private func save() {
        guard pin.count >= 4 else { error = "PIN 至少需要 4 位数字。"; return }
        guard pin == confirmation else { error = "两次 PIN 不一致，请重新输入。"; return }
        let current = map(model.settings["appLockSetting"])
        busy = true
        model.perform {
            do {
                try await DCikeAppLockSettings.save(
                    model: model,
                    enabled: current["enabled"] as? Bool == true,
                    gestureHash: textValue(current["gesturePasswordHash"]),
                    pinHash: DCikeLockHash.pin(pin)
                )
                dismiss()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

@available(iOS 16.0, *)
private struct DCikePatternBoard: View {
    let onCompleted: ([Int]) -> Void
    @State private var selected: [Int] = []

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Path { path in
                    for (position, index) in selected.enumerated() {
                        let point = center(for: index, in: size)
                        if position == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(Color.accentColor.opacity(0.72), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(0..<9, id: \.self) { index in
                    let point = center(for: index, in: size)
                    Circle()
                        .fill(selected.contains(index) ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground))
                        .overlay(Circle().stroke(selected.contains(index) ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: 2))
                        .frame(width: selected.contains(index) ? 24 : 18, height: selected.contains(index) ? 24 : 18)
                        .position(point)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { update($0.location, in: size) }
                .onEnded { _ in
                    let completed = selected
                    selected = []
                    if !completed.isEmpty { onCompleted(completed) }
                })
        }
        .accessibilityLabel("九宫格手势密码")
    }

    private func center(for index: Int, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * (CGFloat(index % 3) + 0.5) / 3,
                y: size.height * (CGFloat(index / 3) + 0.5) / 3)
    }

    private func update(_ point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let column = Int(point.x / (size.width / 3))
        let row = Int(point.y / (size.height / 3))
        guard (0..<3).contains(column), (0..<3).contains(row) else { return }
        let index = row * 3 + column
        if !selected.contains(index) { selected.append(index) }
    }
}

@available(iOS 16.0, *)
struct DCikeLockGate: View {
    @EnvironmentObject private var model: DCikeNativeModel
    @State private var mode: Mode = .gesture
    @State private var pin = ""
    @State private var error: String?
    @State private var busy = false

    private enum Mode { case gesture, pin }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.tint)
                .padding(20)
                .background(.thinMaterial, in: Circle())
            Text(mode == .gesture ? "DCike 已锁定" : "使用重置 PIN")
                .font(.title2.weight(.semibold))
            Text(mode == .gesture ? "画出手势密码以继续。" : "验证 PIN 后将清除应用锁。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if mode == .gesture {
                DCikePatternBoard { points in verifyGesture(points) }
                    .frame(maxWidth: 300)
                    .aspectRatio(1, contentMode: .fit)
            } else {
                VStack(spacing: 14) {
                    SecureField("输入重置 PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: pin) { pin = String($0.filter { $0 >= "0" && $0 <= "9" }) }
                    Button("验证并清除应用锁") { verifyPin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || pin.isEmpty)
                }
                .frame(maxWidth: 300)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center) }
            if busy { ProgressView() }
            if mode == .gesture {
                Button("忘记手势密码？") { mode = .pin; error = nil }
                    .disabled(busy)
                    .padding(.top, 4)
            } else {
                Button("返回手势验证") { mode = .gesture; pin = ""; error = nil }
                    .disabled(busy)
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .interactiveDismissDisabled(true)
        .onAppear { mode = .gesture }
    }

    private func verifyGesture(_ pattern: [Int]) {
        guard pattern.count >= 4 else { error = "至少连接 4 个点。"; return }
        guard !busy else { return }
        busy = true
        error = nil
        model.perform {
            do {
                let response = try await model.request("verifyGesture", ["pattern": pattern])
                if response as? Bool == true {
                    model.unlockCompleted()
                } else {
                    error = "手势密码错误，请重试。"
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func verifyPin() {
        guard !busy, !pin.isEmpty else { return }
        busy = true
        error = nil
        model.perform {
            do {
                let response = try await model.request("verifyPin", ["pin": pin])
                guard response as? Bool == true else {
                    error = "PIN 错误，请重试。"
                    busy = false
                    return
                }
                _ = try await model.request("clearLock")
                await model.refresh()
                model.unlockCompleted()
            } catch {
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

private enum DCikeLockHash {
    static func gesture(_ pattern: [Int]) -> String {
        digest(pattern.map { String($0) }.joined(separator: "-"))
    }

    static func pin(_ pin: String) -> String { digest("pin:\(pin)") }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
