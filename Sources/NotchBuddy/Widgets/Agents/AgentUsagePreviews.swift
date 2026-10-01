import AppKit
import SwiftUI
import NotchBuddyCore

/// `NotchBuddy --render-usage <dir>`: draws the multi-agent usage footer with fake data to PNGs and exits
/// (nothing else starts). `<dir>/usage-*.png` are stills of each state; `<dir>/motion/usage-*.png` are filmstrips
/// (one frame per row) sampled with `islandFilmTime`, so the cascade, fills, sweeps and breathing can be judged.
/// `NOTCHBUDDY_USAGE_REAL=1` adds `usage-real.png` from this Mac's newest Codex rollout (read-only).
@MainActor
enum AgentUsagePreviewRenderer {
    nonisolated static let flag = "--render-usage"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/usage-previews"
    }

    static let panelWidth: CGFloat = 492

    static func run(outputDirectory: String) -> Int32 {
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        let motion = directory.appendingPathComponent("motion", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: motion, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(motion.path): \(error)\n".utf8))
            return 1
        }
        NSApp.setActivationPolicy(.accessory)
        UsageType.ensureRegistered()
        let now = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        let clock = IslandClock(frozenAt: now)
        let scenes = Scenes(now: now)
        var failures = 0

        var stills: [(String, [AgentUsage])] = [
            ("calm", scenes.calm),
            ("hot", scenes.hot),
            ("states", scenes.states),
            ("stale", scenes.stale),
            ("claude-only", scenes.claudeOnly),
            ("three-windows", scenes.threeWindows),
        ]
        if ProcessInfo.processInfo.environment["NOTCHBUDDY_USAGE_REAL"] == "1" {
            stills.append(("real", scenes.real()))
            // The live reader service end to end (FSEvents, worker, tail read), read-only.
            let reader = CodexUsageReader()
            var seen: CodexRateLimits?
            reader.onChange = { seen = $0 }
            reader.start()
            let deadline = Date().addingTimeInterval(3)
            while seen == nil, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            reader.stop()
            print("codex reader: " + (seen.map { s in
                s.windows.map { "\($0.windowMinutes ?? 0) min \(Int($0.usedPercent))%" }.joined(separator: ", ")
                    + " at \(s.capturedAt), plan \(s.planType ?? "-")"
            } ?? "no data"))
        }
        var sheet: [CGImage] = []
        for (name, usages) in stills {
            guard let image = still(name, usages, clock: clock) else {
                failures += 1
                continue
            }
            sheet.append(image)
            failures += write(image, to: directory.appendingPathComponent("usage-\(name).png")) ? 0 : 1
        }
        if let all = IslandPreviewRenderer.stitch(sheet, columns: 2, header: nil) {
            failures += write(all, to: directory.appendingPathComponent("usage-sheet.png")) ? 0 : 1
        }

        let films: [(String, [AgentUsage], [Double])] = [
            ("open-calm", scenes.calm, stride(from: 0.0, through: 1.5, by: 0.1).map { $0 }),
            ("open-hot", scenes.hot, stride(from: 0.0, through: 1.5, by: 0.1).map { $0 }),
            ("breath-hot", scenes.hot, stride(from: 1.6, through: 3.2, by: 0.2).map { $0 }),
            ("loading", scenes.states, stride(from: 0.0, through: 1.3, by: 0.13).map { $0 }),
        ]
        for (name, usages, times) in films {
            let frames = times.compactMap { t in frame(usages, clock: clock, t: t) }
            let header = render(label("\(name) — t = \(times.first ?? 0)…\(times.last ?? 0) s"))
            guard frames.count == times.count, let strip = IslandPreviewRenderer.stitch(frames, columns: 1, header: header, spacing: 6) else {
                failures += 1
                continue
            }
            failures += write(strip, to: motion.appendingPathComponent("usage-\(name).png")) ? 0 : 1
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: Drawing

    private static func still(_ name: String, _ usages: [AgentUsage], clock: IslandClock) -> CGImage? {
        let view = VStack(alignment: .leading, spacing: 10) {
            label(name)
            panel(AgentUsageFooterView(usages: usages))
        }
        .environment(\.islandStaticRender, true)
        .environment(clock)
        return render(view)
    }

    private static func frame(_ usages: [AgentUsage], clock: IslandClock, t: Double) -> CGImage? {
        let view = HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%.2f s", t))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.5))
                .frame(width: 52, alignment: .trailing)
                .padding(.top, 14)
            panel(AgentUsageFooterView(usages: usages))
        }
        .environment(\.islandFilmTime, t)
        .environment(clock)
        return render(view)
    }

    /// SDR sRGB: the agents' app icons are HDR on recent macOS, which turns the whole image into PQ HDR (SDR white
    /// then shows at ~58 % in an ordinary viewer).
    private static func render<V: View>(_ view: V) -> CGImage? {
        guard let image = IslandPreviewRenderer.image(view.allowedDynamicRange(.standard)) else { return nil }
        guard image.colorSpace?.name != CGColorSpace.sRGB || image.bitsPerComponent != 8 else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// The bottom of the expanded island: black, with its rounded bottom corners, the hairline above the footer.
    private static func panel<V: View>(_ footer: V) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(IslandPalette.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, 10)
            footer
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .padding(.top, 10)
        .frame(width: panelWidth)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: IslandLayout.openBottom,
                                           bottomTrailingRadius: IslandLayout.openBottom, style: .continuous).fill(.black))
    }

    private static func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.6))
    }

    private static func write(_ image: CGImage?, to url: URL) -> Bool {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to render \(url.lastPathComponent)\n".utf8))
            return false
        }
        do {
            try png.write(to: url)
            print(url.path)
            return true
        } catch {
            FileHandle.standardError.write(Data("failed to write \(url.path): \(error)\n".utf8))
            return false
        }
    }

    // MARK: Fake data

    private struct Scenes {
        let now: Date

        private func w(_ id: String, _ used: Double, resetIn: TimeInterval?) -> AgentUsageWindow {
            AgentUsageWindow(id: id, used: used, resetsAt: resetIn.map { now.addingTimeInterval($0) })
        }

        var calm: [AgentUsage] {
            [
                AgentUsage(agent: .claude, windows: [w("5h", 42, resetIn: 2 * 3600 + 10 * 60), w("7d", 18, resetIn: 3 * 86400 + 4 * 3600)],
                           fetchedAt: now.addingTimeInterval(-120), staleAfter: 3600),
                AgentUsage(agent: .codex, windows: [w("7d", 14, resetIn: 5 * 86400 + 7 * 3600)], plan: "Plus",
                           fetchedAt: now.addingTimeInterval(-40 * 60), staleAfter: CodexRateLimits.staleAfter),
                AgentUsage(agent: .kimi, windows: [w("5h", 57, resetIn: 52 * 60), w("7d", 23, resetIn: 6 * 86400)],
                           fetchedAt: now.addingTimeInterval(-3 * 60), staleAfter: KimiUsageResponse.staleAfter),
            ]
        }

        var hot: [AgentUsage] {
            [
                AgentUsage(agent: .claude, windows: [w("5h", 78, resetIn: 52 * 60), w("7d", 64, resetIn: 86400)],
                           fetchedAt: now, staleAfter: 3600),
                AgentUsage(agent: .codex, windows: [w("5h", 100, resetIn: 38 * 60), w("7d", 71, resetIn: 2 * 86400)],
                           plan: "Pro", fetchedAt: now.addingTimeInterval(-60), staleAfter: CodexRateLimits.staleAfter,
                           limitReached: true),
                AgentUsage(agent: .kimi, windows: [w("5h", 93, resetIn: 12 * 60), w("7d", 88, resetIn: 3 * 86400)],
                           fetchedAt: now, staleAfter: KimiUsageResponse.staleAfter),
            ]
        }

        var states: [AgentUsage] {
            [
                AgentUsage.unavailable(.claude, AgentUsage.loadingNote),
                .unavailable(.codex, "лимиты появятся после ответа Codex"),
                .unavailable(.kimi, "откройте Kimi Code, чтобы обновить"),
            ]
        }

        var stale: [AgentUsage] {
            [
                AgentUsage(agent: .claude, windows: [w("5h", 8, resetIn: 4 * 3600 + 30 * 60), w("7d", 31, resetIn: 86400 * 2)],
                           fetchedAt: now.addingTimeInterval(-60), staleAfter: 3600),
                // Snapshot from 9 days ago: its week has reset since.
                AgentUsage(agent: .codex, windows: [w("7d", 14, resetIn: -3 * 86400)], plan: "Plus",
                           fetchedAt: now.addingTimeInterval(-9 * 86400), staleAfter: CodexRateLimits.staleAfter),
                AgentUsage(agent: .kimi, windows: [w("5h", 35, resetIn: 3 * 3600), w("7d", 12, resetIn: 4 * 86400)],
                           fetchedAt: now.addingTimeInterval(-2 * 3600 - 300), staleAfter: KimiUsageResponse.staleAfter),
            ]
        }

        var claudeOnly: [AgentUsage] {
            [AgentUsage(agent: .claude, windows: [w("5h", 42, resetIn: 2 * 3600 + 10 * 60), w("7d", 18, resetIn: 3 * 86400)],
                        fetchedAt: now, staleAfter: 3600)]
        }

        var threeWindows: [AgentUsage] {
            [
                AgentUsage(agent: .claude, windows: [w("5h", 22, resetIn: 3 * 3600), w("7d", 47, resetIn: 86400 * 4)],
                           fetchedAt: now, staleAfter: 3600),
                AgentUsage(agent: .kimi, windows: [w("5h", 64, resetIn: 50 * 60), w("7d", 72, resetIn: 86400 * 2),
                                                   w("month", 31, resetIn: 86400 * 17)],
                           fetchedAt: now, staleAfter: KimiUsageResponse.staleAfter),
            ]
        }

        /// This Mac's newest Codex rollout, read-only (no network, no credentials).
        func real() -> [AgentUsage] {
            let sessions = CodexHome.sessions(CodexHome.resolve())
            for file in CodexRollouts.newest(in: sessions, limit: 6) {
                if let snapshot = CodexRollouts.readTail(of: file.url)[CodexRateLimits.mainLimitID] {
                    return [snapshot.agentUsage(now: Date())]
                }
            }
            return [.unavailable(.codex, "лимиты появятся после ответа Codex")]
        }
    }
}
