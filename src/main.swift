// Ori Shader Warmer: drop the game in, watch one progress bar, play without first-visit stutter.
// The work is done by Resources/warm.sh; this file is only the window.
import SwiftUI
import UniformTypeIdentifiers

let fm = FileManager.default
let bottlesDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver/Bottles")

/// The game folder (the one holding oriwotw_Data) for whatever was dropped: the folder, the exe, or the data folder.
func gameDir(from url: URL) -> URL? {
    var u = url
    for _ in 0..<3 {
        if fm.fileExists(atPath: u.appendingPathComponent("oriwotw_Data").path) { return u }
        u = u.deletingLastPathComponent()
    }
    return nil
}

/// Ori in its default Steam location inside any CrossOver bottle.
func installedGame() -> URL? {
    let bottles = (try? fm.contentsOfDirectory(at: bottlesDir, includingPropertiesForKeys: nil)) ?? []
    return bottles.lazy.compactMap {
        gameDir(from: $0.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/Ori and the Will of the Wisps"))
    }.first
}

/// The bottle the game lives in; any bottle works when the game is elsewhere, since the caches belong to the Mac user.
func bottle(for game: URL) -> String? {
    let p = game.pathComponents
    if let i = p.firstIndex(of: "Bottles"), i + 1 < p.count { return p[i + 1] }
    return (try? fm.contentsOfDirectory(atPath: bottlesDir.path))?.filter { !$0.hasPrefix(".") }.sorted().first
}

func wineBinary() -> String? {
    let apps = (try? fm.contentsOfDirectory(atPath: "/Applications"))?.filter { $0.hasPrefix("CrossOver") && $0.hasSuffix(".app") } ?? []
    // Ori needs the D3DMetal that ships in CrossOver Preview, so prefer it when present
    let ordered = apps.sorted { ($0.contains("Preview") ? 0 : 1, $0) < ($1.contains("Preview") ? 0 : 1, $1) }
    return ordered.map { "/Applications/\($0)/Contents/SharedSupport/CrossOver/bin/wine" }.first { fm.isExecutableFile(atPath: $0) }
}

/// The running-Ori animation (an animated PNG in Resources), looped while the shaders compile.
struct RunningOri: View {
    private static let frames: [(image: CGImage, end: Double)] = {
        guard let url = Bundle.main.url(forResource: "run", withExtension: "png"), let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        var t = 0.0
        return (0..<CGImageSourceGetCount(src)).compactMap { i in
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
            let png = (CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any])?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            t += (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? 0.035
            return (img, t)
        }
    }()
    var body: some View {
        TimelineView(.animation) { context in
            let frames = Self.frames
            if let total = frames.last?.end, total > 0 {
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
                Image(decorative: (frames.first { $0.end > t } ?? frames[0]).image, scale: 1).resizable().interpolation(.high).scaledToFit()
            }
        }
    }
}

enum Stage: Equatable { case idle, running, done(String), failed(String) }

final class Warmer: ObservableObject {
    @Published var stage = Stage.idle
    @Published var label = ""
    @Published var fraction = 0.0
    @Published var remaining = ""
    private var process: Process?
    private var phase = 1, phaseStart = Date(), buffer = ""
    // share of the bar per phase: reading shaders, compiling, installing
    private let span: [Int: (Double, Double)] = [1: (0, 0.04), 2: (0.04, 0.98), 3: (0.98, 1)]

    func start(_ dropped: URL) {
        guard let game = gameDir(from: dropped) else { stage = .failed("That doesn't look like Ori and the Will of the Wisps."); return }
        guard let wine = wineBinary() else { stage = .failed("CrossOver wasn't found in Applications."); return }
        guard let bottle = bottle(for: game) else { stage = .failed("No CrossOver bottle was found."); return }
        guard let script = Bundle.main.path(forResource: "warm", ofType: "sh") else { stage = .failed("The app is incomplete."); return }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script, game.path, wine, bottle]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async { self.read(s) }
        }
        p.terminationHandler = { p in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                if self.stage == .running { self.stage = p.terminationReason == .uncaughtSignal || p.terminationStatus == 2 ? .idle : .failed("Something went wrong. Try again.") }
            }
        }
        stage = .running; label = "Starting"; fraction = 0; remaining = ""; buffer = ""
        do { try p.run(); process = p } catch { stage = .failed("Couldn't start.") }
    }

    func cancel() { process?.terminate() }

    private func read(_ s: String) {
        buffer += s
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]); buffer.removeSubrange(...nl)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "PHASE":
                let f = parts[1].split(separator: " ", maxSplits: 1).map(String.init)
                phase = Int(f[0]) ?? phase; label = f.count > 1 ? f[1] : ""; phaseStart = Date(); remaining = ""
                fraction = span[phase]?.0 ?? fraction
            case "PROGRESS":
                let n = parts[1].split(separator: " ").compactMap { Double($0) }
                guard n.count == 2, n[1] > 0, let (a, b) = span[phase] else { continue }
                let f = min(n[0] / n[1], 1)
                fraction = max(fraction, a + (b - a) * f)
                let t = Date().timeIntervalSince(phaseStart)
                if phase == 2, f > 0.03, t > 20 {   // estimate only once it's steady
                    let m = Int((t / f * (1 - f) / 60).rounded(.up))
                    remaining = m <= 1 ? "About a minute left" : "About \(m) minutes left"
                }
            case "ERROR": stage = .failed(parts[1])
            case "DONE": fraction = 1; stage = .done(parts[1])
            default: break
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var warmer = Warmer()
    @State private var hovering = false
    private let found = installedGame()

    var body: some View {
        VStack(spacing: 0) {
            switch warmer.stage {
            case .idle: idle
            case .running: running
            case .done: result("checkmark.circle.fill", .green, "Shaders are warm", "Launch Ori and play.", "Done") { NSApp.terminate(nil) }
            case .failed(let m): result("exclamationmark.triangle.fill", .orange, "Couldn't finish", m, "Try Again") { warmer.stage = .idle }
            }
        }
        .frame(width: 440, height: 300)
        .padding(28)
        .animation(.easeInOut(duration: 0.2), value: warmer.stage)
    }

    private var idle: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 40, weight: .light)).foregroundStyle(hovering ? Color.accentColor : .secondary)
            Text("Drop Ori and the Will of the Wisps here").font(.title3.weight(.semibold))
            Text("Takes about 12 minutes, and you only need to do it once.\nRun it again only after a macOS, CrossOver or game update.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if let found { Button("Use Installed Game") { warmer.start(found) }.keyboardShortcut(.defaultAction) }
                Button("Choose…", action: choose)
            }.controlSize(.large).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(hovering ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [7, 6])))
        .background(RoundedRectangle(cornerRadius: 16).fill(hovering ? Color.accentColor.opacity(0.08) : .clear))
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { warmer.start(url) } } }
            return true
        }
    }

    private var running: some View {
        VStack(spacing: 14) {
            RunningOri().frame(height: 130).padding(.vertical, -18)   // the artwork has wide empty margins
            Text(warmer.label).font(.title3.weight(.semibold))
            // start-up has no countable progress, so the bar animates instead of sitting still
            if warmer.label.hasPrefix("Starting") { ProgressView().progressViewStyle(.linear).controlSize(.large) }
            else { ProgressView(value: warmer.fraction).progressViewStyle(.linear).controlSize(.large) }
            HStack {
                Text("\(Int(warmer.fraction * 100))%").monospacedDigit()
                Spacer()
                Text(warmer.remaining)
            }.font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text("Keep Ori closed until this finishes.").font(.callout).foregroundStyle(.secondary)
            Button("Cancel") { warmer.cancel() }.controlSize(.large)
        }
    }

    private func result(_ icon: String, _ color: Color, _ title: String, _ detail: String, _ button: String, _ action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(color)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(button, action: action).controlSize(.large).keyboardShortcut(.defaultAction)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "Choose the Ori and the Will of the Wisps folder or oriwotw.exe"
        panel.directoryURL = found?.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { warmer.start(url) }
    }
}

@main
struct OriShaderWarmer: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        WindowGroup("Ori Shader Warmer") { ContentView() }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {   // don't leave the compiler running behind a closed window
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); p.arguments = ["-9", "-f", "oriwarm_t.exe"]; try? p.run()
    }
}
