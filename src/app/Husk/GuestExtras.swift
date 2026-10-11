// SPDX-License-Identifier: GPL-2.0-or-later
import GameController
import SwiftUI
import UIKit

// MARK: - Gamepad -> keyboard, for Android

/// Game controllers for apps inside Android.
///
/// The emulated machine has a USB keyboard and no gamepad, so a controller is turned into the keys Android games and
/// Android's own UI already understand: the D-pad and left stick are the arrow keys, A is Enter (select), B is Escape
/// (Back), X is Space, Y is Tab, the shoulders are Q and E, and the menu button is Android's Menu key. Polled, like
/// HuskGamepads, so it never takes a controller's handlers away from the native runtime; it only sends while Android
/// is running, and only changes.
@MainActor
final class GuestGamepad {
    static let shared = GuestGamepad()
    nonisolated static let enabledKey = "husk.guestGamepad"
    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var timer: Timer?
    private var down: Set<String> = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        guard QemuRunner.shared.isRunning, Self.enabled, QemuRunner.qemuReady else {
            release()
            return
        }
        var want: Set<String> = []
        for c in GCController.controllers() {
            guard let g = c.extendedGamepad else { continue }
            let x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value
            if g.dpad.up.isPressed || y > 0.5 { want.insert("up") }
            if g.dpad.down.isPressed || y < -0.5 { want.insert("down") }
            if g.dpad.left.isPressed || x < -0.5 { want.insert("left") }
            if g.dpad.right.isPressed || x > 0.5 { want.insert("right") }
            if g.buttonA.isPressed { want.insert("ret") }
            if g.buttonB.isPressed { want.insert("esc") }
            if g.buttonX.isPressed { want.insert("spc") }
            if g.buttonY.isPressed { want.insert("tab") }
            if g.leftShoulder.isPressed { want.insert("q") }
            if g.rightShoulder.isPressed { want.insert("e") }
            if g.buttonMenu.isPressed { want.insert("menu") }
        }
        guard want != down else { return }
        let released = down.subtracting(want), pressed = want.subtracting(down)
        down = want
        // Off the main thread: sending takes QEMU's big lock, which the guest may be holding.
        DispatchQueue.global(qos: .userInteractive).async {
            for k in released { _ = husk_display_send_key(k, false) }
            for k in pressed { _ = husk_display_send_key(k, true) }
        }
    }

    /// Let go of everything, so a key is never left held when Android stops or the setting is turned off.
    private func release() {
        guard !down.isEmpty else { return }
        let held = down
        down = []
        DispatchQueue.global(qos: .userInteractive).async {
            for k in held { _ = husk_display_send_key(k, false) }
        }
    }
}

// MARK: - Paste from iOS

/// Paste the iOS clipboard into Android by typing it.
///
/// Android has no shell route into its clipboard, and its emulator clipboard channel needs vsock, which QEMU cannot
/// offer on iOS. Typing works in any text field. It is paced because the emulated USB keyboard holds only sixteen
/// events and drops the rest; characters with no key on a US keyboard are skipped.
enum GuestPaste {
    static let maxCharacters = 2000

    @MainActor
    static func pasteFromIOS() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            HuskLog.log("kbd", "paste: the iOS clipboard has no text")
            return
        }
        let chars = Array(text.prefix(maxCharacters))
        // Read here: the map belongs to a view class, so it is main-actor state.
        let map = KeyCapturingView.characterMap
        HuskLog.log("kbd", "paste: typing \(chars.count) characters into Android")
        DispatchQueue.global(qos: .userInitiated).async {
            func tap(_ q: String) {
                _ = husk_display_send_key(q, true); Thread.sleep(forTimeInterval: 0.02)
                _ = husk_display_send_key(q, false); Thread.sleep(forTimeInterval: 0.02)
            }
            var skipped = 0
            for ch in chars {
                if ch == "\n" || ch == "\r" { tap("ret"); continue }
                if ch == " " { tap("spc"); continue }
                if ch == "\t" { tap("tab"); continue }
                guard let (q, shift) = map[ch] else { skipped += 1; continue }
                if shift { _ = husk_display_send_key("shift", true) }
                tap(q)
                if shift { _ = husk_display_send_key("shift", false) }
            }
            if skipped > 0 { HuskLog.log("kbd", "paste: skipped \(skipped) characters with no US key") }
        }
    }
}

// MARK: - Performance overlay and heat

/// What the overlay shows, sampled once a second.
@MainActor
final class GuestStats: ObservableObject {
    static let shared = GuestStats()
    nonisolated static let overlayKey = "husk.perfOverlay"

    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
    @Published private(set) var freeMiB = 0
    private var timer: Timer?

    private init() {}

    func start() {
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func sample() {
        let t = ProcessInfo.processInfo.thermalState
        if t != thermal {
            HuskLog.log("perf", "thermal state: \(Self.name(t))")
            thermal = t
        }
        freeMiB = Int(husk_ios_available_memory() / (1024 * 1024))
    }

    static func name(_ t: ProcessInfo.ThermalState) -> String {
        switch t {
        case .nominal: return "Cool"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Very hot"
        @unknown default: return "?"
        }
    }

    static func color(_ t: ProcessInfo.ThermalState) -> Color {
        switch t {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        default: return .red
        }
    }
}

/// The corner readout: frame rate, heat, memory left before iOS ends Husk.
struct GuestPerfOverlay: View {
    @ObservedObject private var runner = QemuRunner.shared
    @ObservedObject private var stats = GuestStats.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(runner.fps > 0 ? String(format: "%.0f fps", runner.fps) : "— fps")
            Circle().fill(GuestStats.color(stats.thermal)).frame(width: 7, height: 7)
            Text(GuestStats.name(stats.thermal))
            Text("\(stats.freeMiB) MB free")
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .allowsHitTesting(false)
    }
}

/// Shown whatever the overlay setting, once the device is hot enough to slow down: otherwise throttling looks
/// exactly like Husk getting slower for no reason.
struct GuestHeatWarning: View {
    @ObservedObject private var stats = GuestStats.shared

    var body: some View {
        if stats.thermal == .serious || stats.thermal == .critical {
            Label(stats.thermal == .critical ? "Device is very hot: Android is being slowed down hard"
                                             : "Device is hot: Android will slow down",
                  systemImage: "thermometer.high")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(GuestStats.color(stats.thermal).opacity(0.85), in: Capsule())
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

// MARK: - Live quality

/// Render quality and the overlay, from the Android screen. Quality takes effect without a cold boot: Android draws
/// fewer pixels and scales them up (AndroidHost.setRenderScale).
struct GuestQualitySheet: View {
    @ObservedObject private var host = AndroidHost.shared
    @AppStorage(GuestStats.overlayKey) private var overlay = false
    @State private var scale = AndroidHost.renderScale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Render quality")
                            Spacer()
                            Text("\(Int((scale * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $scale, in: 0.5...1, step: 0.05, onEditingChanged: { editing in
                            if !editing { host.setRenderScale(scale) }
                        })
                        .disabled(!host.isReady || host.busy != nil)
                    }
                } footer: {
                    Text(host.isReady
                         ? "Lower draws fewer pixels and runs faster; the picture is softer. Applies straight away."
                         : "Available once Android has started.")
                }
                Section {
                    Toggle("Performance overlay", isOn: $overlay)
                } footer: {
                    Text("Frame rate, how hot the device is, and memory left. A warning appears by itself when the device "
                       + "gets hot enough to slow down.")
                }
            }
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Home Screen quick actions

/// Long-press Husk's icon: Start Android, and the Android apps used most recently.
///
/// Each item carries the same link as a Home Screen clip (AppClip.androidLink), so it goes through the same path.
@MainActor
enum QuickActions {
    static let type = "husk.android"

    static func refresh() {
        guard GuestImage.shared.state == .ready else {
            UIApplication.shared.shortcutItems = []
            return
        }
        var items = [UIApplicationShortcutItem(
            type: type, localizedTitle: "Android", localizedSubtitle: "Start Android",
            icon: UIApplicationShortcutIcon(systemImageName: "apps.iphone"),
            userInfo: ["url": AppClip.androidLink(package: nil).absoluteString as NSString])]
        let recent = AndroidHost.shared.packages
            .filter { $0.lastUsed != nil }
            .sorted { $0.lastUsed! > $1.lastUsed! }
            .prefix(3)
        for p in recent {
            items.append(UIApplicationShortcutItem(
                type: type, localizedTitle: p.label, localizedSubtitle: "Opens in Android",
                icon: UIApplicationShortcutIcon(systemImageName: "play.fill"),
                userInfo: ["url": AppClip.androidLink(package: p.name).absoluteString as NSString]))
        }
        UIApplication.shared.shortcutItems = items
    }

    /// Carry out a quick action. True when it was one of ours.
    @discardableResult
    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == type, let s = item.userInfo?["url"] as? String, let url = URL(string: s) else { return false }
        HuskLog.log("ui", "quick action: \(item.localizedTitle)")
        return AppClip.handle(url)
    }
}

/// Receives quick actions while Husk is running; a cold launch's arrives in HuskAppDelegate instead.
final class HuskSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { completionHandler(QuickActions.perform(shortcutItem)) }
    }
}
