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

/// CrossOver bottles that are fully set up.
func bottles() -> [URL] {
    let all = (try? fm.contentsOfDirectory(at: bottlesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    return all.filter { fm.fileExists(atPath: $0.appendingPathComponent("cxbottle.conf").path) }
        .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
}

/// The Steam library folders a bottle's Steam knows about, as Mac paths. Drive letters are resolved through dosdevices.
func steamLibraries(in bottle: URL) -> [URL] {
    let steam = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam")
    var libs = [steam]
    guard let vdf = try? String(contentsOf: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) else { return libs }
    for line in vdf.split(separator: "\n") where line.contains("\"path\"") {
        let parts = line.split(separator: "\"").map(String.init)
        guard parts.count >= 4 else { continue }
        let win = parts[3].replacingOccurrences(of: "\\\\", with: "\\")
        guard win.count >= 2, win.dropFirst().first == ":" else { continue }
        let drive = bottle.appendingPathComponent("dosdevices/\(win.prefix(2).lowercased())").resolvingSymlinksInPath()
        let rest = win.dropFirst(2).split(separator: "\\").joined(separator: "/")
        libs.append(rest.isEmpty ? drive : drive.appendingPathComponent(rest))
    }
    return libs
}

/// Ori in any Steam library of any bottle, with the bottle that runs it.
func installedGame() -> URL? {
    for b in bottles() {
        for lib in steamLibraries(in: b) {
            if let g = gameDir(from: lib.appendingPathComponent("steamapps/common/Ori and the Will of the Wisps")) { return g }
        }
    }
    return nil
}

/// Searches for the game: CrossOver's Steam libraries first, then the Mac Steam libraries, then Spotlight.
func findGame() -> URL? {
    if let g = installedGame() { return g }
    let steamApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam/steamapps")
    var libs = [steamApps.deletingLastPathComponent()]
    if let vdf = try? String(contentsOf: steamApps.appendingPathComponent("libraryfolders.vdf"), encoding: .utf8) {
        for line in vdf.split(separator: "\n") where line.contains("\"path\"") {
            let parts = line.split(separator: "\"").map(String.init)
            if parts.count >= 4 { libs.append(URL(fileURLWithPath: parts[3])) }
        }
    }
    for lib in libs {
        if let g = gameDir(from: lib.appendingPathComponent("steamapps/common/Ori and the Will of the Wisps")) { return g }
    }
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p.arguments = ["kMDItemFSName == 'oriwotw.exe'"]
    p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    return found.split(separator: "\n").lazy.compactMap { gameDir(from: URL(fileURLWithPath: String($0))) }.first
}

/// The bottle that runs the game: the one it is installed in, else one whose Steam library holds it, else the newest bottle.
func bottle(for game: URL) -> String? {
    let all = bottles()
    let path = game.resolvingSymlinksInPath().path
    if let b = all.first(where: { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }) { return b.lastPathComponent }
    if let b = all.first(where: { steamLibraries(in: $0).contains { path.hasPrefix($0.resolvingSymlinksInPath().path + "/") } }) { return b.lastPathComponent }
    return all.first?.lastPathComponent
}

/// A way the game can run on this Mac, and where it keeps its shader caches.
struct Runtime: Hashable {
    let name: String
    let wine: String                // the Wine the game runs with
    let bottle: String
    let metalCache: String          // folder in the user cache dir holding this runner's Metal cache
    let d3dmetal: String            // D3DMetal build; caches are only valid for the build that made them
}

/// Version of the D3DMetal a CrossOver tree uses: lib/apple_gptk, else lib64/apple_gptk.
func d3dmetalVersion(_ root: String) -> String? {
    for dir in ["lib", "lib64"] {
        let fw = "\(root)/\(dir)/apple_gptk/external/D3DMetal.framework"
        guard let bin = try? fm.attributesOfItem(atPath: URL(fileURLWithPath: "\(fw)/D3DMetal").resolvingSymlinksInPath().path)[.size] as? Int else { continue }
        let info = NSDictionary(contentsOfFile: "\(fw)/Resources/Info.plist")
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?")-\(bin)"
    }
    return nil
}

func crossOverRuntimes(for game: URL) -> [Runtime] {
    guard let bottle = bottle(for: game) else { return [] }
    let dirs = ["/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
    return dirs.flatMap { dir in
        ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("CrossOver") && $0.hasSuffix(".app") }.sorted().compactMap { app in
            let root = "\(dir)/\(app)/Contents/SharedSupport/CrossOver"
            guard fm.isExecutableFile(atPath: "\(root)/bin/wine"), let v = d3dmetalVersion(root) else { return nil }
            return Runtime(name: String(app.dropLast(4)), wine: "\(root)/bin/wine", bottle: bottle,
                           metalCache: "com.codeweavers.CrossOver.wineloader", d3dmetal: v)
        }
    }
}

func runtimes(for game: URL) -> [Runtime] { crossOverRuntimes(for: game) }

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

enum Stage: Equatable { case idle, choose(URL, [Runtime]), running, done(String), failed(String) }

final class Warmer: ObservableObject {
    static let shared = Warmer()
    @Published var stage = Stage.idle
    @Published var label = ""
    @Published var fraction = 0.0
    @Published var remaining = ""
    private(set) var process: Process?
    private var retry: (() -> Void)?       // reruns the last attempt with the same game and setup
    private var phase = 1, phaseStart = Date(), buffer = ""
    // share of the bar per phase: reading shaders, compiling, installing
    private let span: [Int: (Double, Double)] = [1: (0, 0.04), 2: (0.04, 0.98), 3: (0.98, 1)]

    func start(_ dropped: URL) {
        retry = nil
        guard let game = gameDir(from: dropped) else { stage = .failed("That isn't the game folder. Choose the Ori and the Will of the Wisps folder in your Steam library, the one with oriwotw.exe in it."); return }
        let all = runtimes(for: game)
        guard !all.isEmpty else { stage = .failed("CrossOver wasn't found, or no bottle is set up yet."); return }
        // One build serves every runner on the same D3DMetal. Only ask when they differ.
        if Set(all.map(\.d3dmetal)).count > 1 { stage = .choose(game, all) } else { run(game, all) }
    }

    func choose(_ game: URL, _ picked: Runtime, from all: [Runtime]) { run(game, all.filter { $0.d3dmetal == picked.d3dmetal }, preferred: picked) }

    func tryAgain() { if let retry { retry() } else { stage = .idle } }

    private func run(_ game: URL, _ group: [Runtime], preferred: Runtime? = nil) {
        retry = { [unowned self] in run(game, group, preferred: preferred) }
        guard let script = Bundle.main.path(forResource: "warm", ofType: "sh") else { stage = .failed("The app is incomplete."); return }
        let rt = preferred ?? group[0]
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script, game.path, rt.wine]
        var env = ProcessInfo.processInfo.environment
        env["BOTTLE"] = rt.bottle
        env["METAL_CACHES"] = Array(Set(group.map(\.metalCache))).sorted().joined(separator: "\n")
        p.environment = env
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async { if p === self.process { self.read(s) } }
        }
        p.terminationHandler = { p in
            // The script can exit before its last lines have been read, so drain the pipe before judging the result.
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                guard p === self.process else { return }
                self.read(rest)
                if self.stage == .running { self.stage = p.terminationReason == .uncaughtSignal || p.terminationStatus == 2 ? .idle : .failed("Something went wrong. Try again.") }
            }
        }
        stage = .running; label = "Starting"; fraction = 0; remaining = ""; buffer = ""; phase = 1
        process = p
        do { try p.run() } catch { process = nil; stage = .failed("Couldn't start.") }
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
    @ObservedObject private var warmer = Warmer.shared
    @State private var hovering = false
    private let found = installedGame()

    var body: some View {
        VStack(spacing: 0) {
            switch warmer.stage {
            case .idle: idle
            case .choose(let game, let all): chooser(game, all)
            case .running: running
            case .done: result("checkmark.circle.fill", .green, "Shaders are warm", "Launch Ori and play.", "Done") { NSApp.terminate(nil) }
            case .failed(let m): result("exclamationmark.triangle.fill", .orange, "Couldn't finish", m, "Try Again") { warmer.tryAgain() }
            }
        }
        .frame(width: 440, height: 300)
        .padding(28)
        .animation(.easeInOut(duration: 0.2), value: warmer.stage)
    }

    private var idle: some View {
        VStack(spacing: 14) {
            Text("Drop the Ori and the Will of the Wisps folder here").font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("Takes 10 to 30 minutes, and you only need to do it once.\nRun it again only after a macOS, CrossOver or game update.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Find Game") {
                    if let game = findGame() { warmer.start(game) }
                    else { warmer.stage = .failed("Couldn't find the game. Drag its folder onto this window, or use Choose.") }
                }.keyboardShortcut(.defaultAction)
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

    private func chooser(_ game: URL, _ all: [Runtime]) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Text("How do you play Ori?").font(.title3.weight(.semibold))
            Text("These use different versions of D3DMetal, so the shaders can only be warmed for one.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                // setups on the same D3DMetal share one cache, so they share a button
                ForEach(Array(Dictionary(grouping: all, by: \.d3dmetal).values).sorted { $0[0].name < $1[0].name }, id: \.self) { group in
                    Button { warmer.choose(game, group[0], from: all) } label: {
                        Text(group.map(\.name).joined(separator: " / ")).frame(maxWidth: 300)
                    }
                }
            }.controlSize(.large).padding(.top, 4)
            Spacer()
            Button("Cancel") { warmer.stage = .idle }.buttonStyle(.link)
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
        if let p = Warmer.shared.process, p.isRunning {
            p.terminate()
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning && Date() < deadline { usleep(100_000) }
        }
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-9", "-f", "oriwarm_t.exe"]
        try? k.run(); k.waitUntilExit()
    }
}
