import AppKit
import SwiftUI
import NotchBuddyCore

/// `NotchBuddy --render-sessions <dir>`: draws the session cards with fake sessions to PNGs (collapsed cards,
/// expanded cards, the open island with one card expanded, and a filmstrip of the expansion), checks the copy
/// catalog, then exits. Nothing else starts.
@MainActor
enum SessionsPreviewRenderer {
    nonisolated static let flag = "--render-sessions"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/sessions"
    }

    static let cardWidth: CGFloat = 472
    static let floating = IslandMetrics(style: .floating, notchWidth: 0,
                                        barHeight: IslandMetrics.floatingBarHeight(menuBar: 30), menuBarHeight: 30)
    static let notched = IslandMetrics(style: .notch, notchWidth: 188, barHeight: 37, menuBarHeight: 37)

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
        let fontOK = SessionFont.register()
        print("manrope: \(fontOK ? "registered" : "NOT FOUND, system font")")

        var failures = SessionStringsCheck.run()
        let data = FakeSessions(now: Date())
        let clock = IslandClock(frozenAt: data.now)
        let sessions = data.ordered

        // 1. Collapsed cards, every status; the second one hovered.
        let collapsed = VStack(spacing: IslandLayout.rowSpacing) {
            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                SessionCardView(session: session, expanded: false, hovering: index == 1)
            }
        }
        failures += write(panel(collapsed, title: "Карточки · свёрнуты (вторая — под курсором)", clock: clock),
                          to: directory.appendingPathComponent("cards-collapsed.png"))

        // 2. Expanded cards.
        for (name, key) in [("working", FakeSessions.claude), ("waiting", FakeSessions.codex),
                            ("finished", FakeSessions.kimi), ("error", FakeSessions.failed)] {
            guard let session = data.store.sessions[key] else { continue }
            let card = SessionCardView(session: session, expanded: true, hovering: name == "working")
            failures += write(panel(card, title: "Раскрытая карточка · \(SessionStrings.status(session.status))", clock: clock),
                              to: directory.appendingPathComponent("card-expanded-\(name).png"))
        }

        // 2b. The "done" sheen mid-sweep (it plays once when a card turns green).
        if let done = data.store.sessions[FakeSessions.kimi] {
            let frames = VStack(spacing: IslandLayout.rowSpacing) {
                ForEach([0.1, 0.45, 0.8], id: \.self) { x in
                    SessionCardView(session: done, expanded: false, hovering: false)
                        .overlay { DoneSweepBand(x: x, color: SessionStatus.finished.tint)
                            .clipShape(RoundedRectangle(cornerRadius: SessionCardView.cornerRadius, style: .continuous)) }
                        .frame(width: cardWidth)
                }
            }
            failures += write(panel(frames, title: "Готово: зелёный блик проходит по карточке один раз", clock: clock),
                              to: motion.appendingPathComponent("done-sheen.png"))
        }

        // 3. The open island with the list, one card expanded.
        for (suffix, metrics) in [("floating", floating), ("notch", notched)] {
            let pair = [FakeSessions.codex, FakeSessions.claude].compactMap { data.store.sessions[$0] }
            let island = IslandMock(sessions: pair, metrics: metrics, usage: data.usage, expanded: FakeSessions.claude,
                                    hovered: FakeSessions.claude)
            failures += write(stage(island, clock: clock), to: directory.appendingPathComponent("island-list-\(suffix).png"))
            let closed = IslandMock(sessions: Array(sessions.prefix(4)), metrics: metrics, usage: data.usage, expanded: nil,
                                    hovered: nil)
            failures += write(stage(closed, clock: clock),
                              to: directory.appendingPathComponent("island-list-collapsed-\(suffix).png"))
        }

        // 4. Filmstrips of the expansion.
        for (name, key) in [("expand-working", FakeSessions.claude), ("expand-finished", FakeSessions.kimi)] {
            guard let session = data.store.sessions[key] else { continue }
            failures += write(expansionFilm(session, clock: clock), to: motion.appendingPathComponent("\(name).png"))
        }
        // 5. The live list: an expansion reaches the island's content size in one layout pass.
        for set in [Array(sessions.prefix(3)), sessions] {
            let live = SessionsLiveCheck.run(sessions: set, expand: FakeSessions.claude, then: FakeSessions.codex,
                                             clock: clock)
            for line in live.report { print("live (\(set.count)): \(line)") }
            for problem in live.problems { FileHandle.standardError.write(Data("live (\(set.count)): \(problem)\n".utf8)) }
            failures += live.problems.count
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: Composition

    private static func environment<V: View>(_ view: V, clock: IslandClock, filmTime: Double? = nil) -> some View {
        view
            .environment(\.islandStaticRender, filmTime == nil)
            .environment(\.islandFilmTime, filmTime)
            .environment(clock)
            .environment(\.colorScheme, .dark)
    }

    /// A card (or cards) on a black island panel, titled.
    private static func panel<V: View>(_ content: V, title: String, clock: IslandClock) -> CGImage? {
        let view = VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(SessionFont.manrope(13, 600))
                .foregroundStyle(Color.white.opacity(0.55))
            content
                .frame(width: cardWidth)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black))
        }
        .padding(28)
        .background(Color(white: 0.13))
        return image(environment(view, clock: clock))
    }

    /// The island hanging from the top edge of a desktop.
    private static func stage<V: View>(_ island: V, clock: IslandClock) -> CGImage? {
        let view = island
            .padding(.horizontal, 60)
            .padding(.bottom, 50)
            .frame(maxWidth: .infinity, alignment: .top)
            .background(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.52), Color(red: 0.62, green: 0.5, blue: 0.56),
                                        Color(red: 0.86, green: 0.66, blue: 0.52)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        return image(environment(view, clock: clock))
    }

    private static func expansionFilm(_ session: AgentSession, clock: IslandClock) -> CGImage? {
        // The expanded card's full height, as laid out.
        let full = image(environment(SessionCardView(session: session, expanded: true, hovering: true).frame(width: cardWidth),
                                     clock: clock), scale: 1).map { CGFloat($0.height) } ?? 300
        let times: [Double] = [0, 0.03, 0.06, 0.09, 0.12, 0.16, 0.2, 0.26, 0.34, 0.5]
        let curve = SessionCardView.expandCurve
        let frames = times.map { t -> AnyView in
            let p = curve.progress(t)
            let card = SessionCardView(session: session, expanded: true, hovering: true, filmExpansion: p,
                                       filmExpandedHeight: full)
            return AnyView(VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "%.0f мс · %.0f%%", t * 1000, p * 100))
                    .font(SessionFont.manrope(11, 600))
                    .foregroundStyle(Color.white.opacity(0.55))
                card
                    .frame(width: cardWidth)
                    .padding(10)
                    .frame(height: full + 20, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black))
            })
        }
        let strip = Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 18) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<5, id: \.self) { column in
                        let index = row * 5 + column
                        frames[index].environment(\.islandFilmTime, times[index])
                    }
                }
            }
        }
        let view = VStack(alignment: .leading, spacing: 14) {
            Text("Раскрытие карточки · пружина \(IslandMotion.data.name) 0.38/0.90 (та же у силуэта острова) · секции проявляются каскадом, шеврон переворачивается")
                .font(SessionFont.manrope(13, 600))
                .foregroundStyle(Color.white.opacity(0.6))
            strip
        }
        .padding(28)
        .background(Color(white: 0.13))
        return image(view.environment(clock).environment(\.colorScheme, .dark).environment(\.islandStaticRender, false))
    }

    static func image<V: View>(_ view: V, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.cgImage.flatMap(sRGB)
    }

    /// The renderer may hand back an HDR (PQ) image on an HDR display; PNGs for review are plain sRGB.
    private static func sRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private static func write(_ image: CGImage?, to url: URL) -> Int {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to render \(url.lastPathComponent)\n".utf8))
            return 1
        }
        do {
            try png.write(to: url)
            print(url.path)
            return 0
        } catch {
            FileHandle.standardError.write(Data("failed to write \(url.path): \(error)\n".utf8))
            return 1
        }
    }
}

// MARK: - Island mock

/// The open island around the list: silhouette with ears, a header like the list's, the cards, the usage
/// footer (the real `ExpandedIslandView` wires `SessionCardList` the same way).
private struct IslandMock: View {
    let sessions: [AgentSession]
    let metrics: IslandMetrics
    let usage: UsageState
    let expanded: SessionKey?
    let hovered: SessionKey?

    var body: some View {
        let width = IslandLayout.listWidth(metrics)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(L("Сессии"))
                    .font(SessionFont.manrope(12, 650))
                    .foregroundStyle(IslandPalette.secondary)
                Text("\(sessions.count)")
                    .font(SessionFont.manrope(11, 700))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 19)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                Spacer(minLength: metrics.style == .notch ? metrics.notchWidth + 12 : 8)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(IslandPalette.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.09)))
                Image(systemName: "pin")
                    .font(.system(size: 10.5, weight: .bold))
                    .rotationEffect(.degrees(35))
                    .foregroundStyle(IslandPalette.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.09)))
            }
            .padding(.leading, 22)
            .padding(.trailing, 12)
            .frame(height: metrics.style == .notch ? metrics.barHeight : 46)
            .padding(.top, metrics.style == .notch ? 0 : 2)

            SessionCardList(sessions: sessions, metrics: metrics, hoveredKey: hovered, actions: IslandActions(),
                            expanded: expanded)

            VStack(spacing: 0) {
                Rectangle().fill(IslandPalette.hairline).frame(height: 0.5).padding(.horizontal, 10)
                UsageView(usage: usage, barDelay: 0)
                    .padding(.horizontal, 22)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
            }
        }
        .frame(width: width)
        .padding(.horizontal, IslandLayout.openEar)
        .background {
            IslandShape(earRadius: IslandLayout.openEar, bottomRadius: IslandLayout.openBottom)
                .fill(Color.black)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
        .overlay(alignment: .top) {
            if metrics.style == .notch {
                // The camera housing.
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(Color.black)
                    .frame(width: metrics.notchWidth, height: metrics.barHeight)
            }
        }
    }
}

// MARK: - Fake data

@MainActor
private struct FakeSessions {
    let now: Date
    let store: SessionStore
    let usage: UsageState

    static let claude = SessionKey(source: .claude, sessionId: "claude-1")
    static let codex = SessionKey(source: .codex, sessionId: "codex-1")
    static let kimi = SessionKey(source: .kimi, sessionId: "kimi-1")
    static let failed = SessionKey(source: .claude, sessionId: "claude-2")
    static let scratch = SessionKey(source: .claude, sessionId: "claude-3")
    static let mcp = SessionKey(source: .codex, sessionId: "codex-2")

    var ordered: [AgentSession] { store.ordered }

    init(now: Date) {
        self.now = now
        var store = SessionStore(staleAfter: .greatestFiniteMagnitude, workingTimeout: .greatestFiniteMagnitude)
        let home = NSHomeDirectory()
        var n = 0
        func e(_ key: SessionKey, _ kind: EventKind, ago: TimeInterval, cwd: String, tool: String? = nil,
               summary: String? = nil, message: String? = nil, id: String? = nil, agent: String? = nil,
               host: HostContext = HostContext(), title: String? = nil) {
            n += 1
            var raw: [String: JSONValue] = [:]
            if let id { raw["tool_use_id"] = .string(id) }
            store.apply(AgentEvent(source: key.source, hookEventName: "\(kind)", kind: kind, sessionId: key.sessionId,
                                   cwd: cwd, toolName: tool, toolSummary: summary, message: message,
                                   timestamp: now.addingTimeInterval(-ago), host: host,
                                   raw: raw.isEmpty ? .null : .object(raw), agentId: agent, sessionTitle: title))
        }
        func call(_ key: SessionKey, _ tool: String, _ summary: String, from: TimeInterval, to: TimeInterval?,
                  cwd: String, fail: String? = nil, agent: String? = nil) {
            n += 1
            let id = "call-\(n)"
            e(key, .toolWillRun, ago: from, cwd: cwd, tool: tool, summary: summary, id: id, agent: agent)
            guard let to else { return }
            if let fail {
                e(key, .toolFailed, ago: to, cwd: cwd, tool: tool, summary: summary, message: fail, id: id, agent: agent)
            } else {
                e(key, .toolDidRun, ago: to, cwd: cwd, tool: tool, summary: summary, id: id, agent: agent)
            }
        }

        // Claude, working, in iTerm2: a long prompt, a failed build, a running test and a subagent.
        let app = "\(home)/code/weather-app"
        let iterm = HostContext(termProgram: "iTerm.app", bundleIdentifier: "com.googlecode.iterm2", tty: "/dev/ttys003")
        e(Self.claude, .sessionStart, ago: 3 * 3600 + 1200, cwd: app, host: iterm)
        e(Self.claude, .promptSubmitted, ago: 134, cwd: app, message: sample("""
            Сделай карточки прогноза раскрывающимися: почасовой график, осадки и ветер. \
            Анимация — одной пружиной, контент проявляется с размытием.
            И проверь, что всё идёт в 60 fps.
            """, """
            Make the forecast cards expandable: the hourly chart, rain and wind. \
            Animate it with one spring, and let the content come in out of a blur.
            And check that everything runs at 60 fps.
            """), host: iterm)
        call(Self.claude, "Read", "Sources/WeatherCore/ForecastStore.swift", from: 128, to: 127.9, cwd: app)
        call(Self.claude, "Grep", "hourlyPoints", from: 120, to: 119.7, cwd: app)
        call(Self.claude, "Edit", "Sources/Weather/Forecast/ForecastCardView.swift", from: 96, to: 95.8, cwd: app)
        call(Self.claude, "Bash", "swift build 2>&1 | tail -20", from: 80, to: 47, cwd: app,
             fail: "error: cannot find 'ForecastFont' in scope")
        call(Self.claude, "Edit", "Sources/Weather/Forecast/ForecastTypography.swift", from: 40, to: 39.7, cwd: app)
        call(Self.claude, "Task", sample("Проверить анимации на 120 Гц", "Check the animations at 120 Hz"), from: 30, to: nil, cwd: app, agent: nil)
        call(Self.claude, "Bash", "swift test --filter ForecastStoreTests", from: 14, to: nil, cwd: app)

        // Codex, waiting for a permission, in its desktop app.
        let api = "\(home)/code/api-gateway"
        let codexApp = HostContext(bundleIdentifier: "com.openai.codex")
        e(Self.codex, .promptSubmitted, ago: 400, cwd: api, message: sample("Почини падающие тесты авторизации", "Fix the failing auth tests"), host: codexApp)
        call(Self.codex, "exec_command", "npm test -- --watch=false", from: 380, to: 352, cwd: api,
             fail: "exit code 1: 3 failing (auth.spec.ts)")
        call(Self.codex, "apply_patch", "*** Update File: src/routes/auth.ts", from: 300, to: 299.6, cwd: api)
        call(Self.codex, "exec_command", "npm test -- auth", from: 240, to: 226, cwd: api)
        e(Self.codex, .permissionRequest, ago: 45, cwd: api, tool: "Bash", summary: "rm -rf node_modules && npm ci")

        // Kimi, finished, in VS Code, with a Markdown answer.
        let landing = "\(home)/code/landing-page"
        var vscode = HostContext(termProgram: "vscode")
        vscode.extra[KimiAdapter.clientTypeKey] = "kimi_code_vscode"
        e(Self.kimi, .promptSubmitted, ago: 900, cwd: landing, message: sample("Обнови hero-блок под новый бренд", "Update the hero section for the new brand"), host: vscode,
          title: sample("Hero-блок под новый бренд", "Hero section for the new brand"))
        call(Self.kimi, "ReadMediaFile", "design/hero@2x.png", from: 880, to: 879, cwd: landing)
        call(Self.kimi, "Edit", "src/components/Hero.tsx", from: 820, to: 819.5, cwd: landing)
        call(Self.kimi, "Write", "src/components/Hero.module.css", from: 760, to: 759.8, cwd: landing)
        call(Self.kimi, "Bash", "npm run build", from: 700, to: 652, cwd: landing)
        e(Self.kimi, .stop, ago: 420, cwd: landing, message: sample("""
            ## Готово
            Обновил **hero-блок** под новый бренд:
            - новый заголовок и подзаголовок
            - адаптив для экранов уже 640 px
            - кнопка появляется с лёгкой анимацией

            Проверь локально: `npm run dev`.
            """, """
            ## Done
            Updated the **hero section** for the new brand:
            - a new headline and subheadline
            - layout for screens narrower than 640 px
            - the button comes in with a light animation

            Check it locally: `npm run dev`.
            """), host: vscode)

        // Claude, the turn failed on an API error.
        let ml = "\(home)/code/ml-pipeline"
        e(Self.failed, .promptSubmitted, ago: 1500, cwd: ml, message: sample("""
            Перезапусти обучение с новым learning rate 3e-4 и batch 64. Если снова упадёт по памяти — уменьши batch \
            до 32, включи gradient checkpointing и пришли график loss за первые 500 шагов.
            Логи прошлого запуска лежат в runs/2026-09-30/train.log, посмотри, где именно он падал, и сравни \
            с конфигом из configs/base.yaml.
            """, """
            Restart the training with learning rate 3e-4 and batch 64. If it runs out of memory again, drop the batch \
            to 32, turn on gradient checkpointing and send me the loss curve for the first 500 steps.
            The last run's logs are in runs/2026-09-30/train.log: find where exactly it crashed and compare \
            with the config in configs/base.yaml.
            """))
        call(Self.failed, "Bash", "python train.py --lr 3e-4", from: 1480, to: nil, cwd: ml)
        e(Self.failed, .stopFailed, ago: 1210, cwd: ml, message: L("API перегружен") + " — 529 Overloaded")

        // Claude Desktop in a scratch folder: no project.
        let scratch = "\(home)/Library/Application Support/Claude/scratch-workspaces/0f3a/scratch-2026-09-30-a1b2c3"
        var desktop = HostContext()
        desktop.extra["CLAUDE_CODE_ENTRYPOINT"] = "claude-desktop"
        e(Self.scratch, .sessionStart, ago: 2400, cwd: scratch, host: desktop)
        e(Self.scratch, .promptSubmitted, ago: 2300, cwd: scratch, message: sample("Набросай план статьи про островки", "Sketch an outline for a post about the widgets"), host: desktop)
        e(Self.scratch, .interrupted, ago: 2200, cwd: scratch, host: desktop)

        // Codex working on an MCP call, in Ghostty inside tmux.
        let rel = "\(home)/code/release-bot"
        let ghostty = HostContext(termProgram: "ghostty", tmuxPane: "%3")
        e(Self.mcp, .promptSubmitted, ago: 70, cwd: rel, message: sample("Заведи задачи на релиз 0.4", "File the issues for release 0.4"), host: ghostty)
        call(Self.mcp, "mcp__github__create_issue", sample("Релиз 0.4: карточки сессий", "Release 0.4: session cards"), from: 8, to: nil, cwd: rel)

        store.setChatTitle(sample("Анимации карточек сессий", "Session card animations"), for: Self.claude)
        store.setChatTitle(sample("Тесты авторизации в gateway", "Auth tests in the gateway"), for: Self.codex)
        self.store = store

        usage = .loaded(UsageSnapshot(
            fiveHour: UsageWindow(utilization: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60)),
            sevenDay: UsageWindow(utilization: 18, resetsAt: now.addingTimeInterval(3 * 86400 + 4 * 3600)),
            fetchedAt: now))
    }
}

// MARK: - Copy checks

/// The copy catalog's rules, checked on every render (the app target has no unit tests).
@MainActor
enum SessionStringsCheck {
    static func run() -> Int {
        // The catalog's Russian copy, whatever language the render draws in.
        L10n.shared.override(.ru)
        defer { L10n.shared.override(nil) }
        var failures = 0
        func expect(_ got: String?, _ want: String?, _ what: String) {
            guard got != want else { return }
            failures += 1
            FileHandle.standardError.write(Data("strings: \(what): got \(got ?? "nil"), want \(want ?? "nil")\n".utf8))
        }
        let s = SessionStrings.nbsp
        expect(SessionStrings.toolName("Bash"), "Терминал", "Bash")
        expect(SessionStrings.toolName("exec_command"), "Терминал", "exec_command")
        expect(SessionStrings.toolName("Edit"), "Правка файла", "Edit")
        expect(SessionStrings.toolName("apply_patch"), "Правка файлов", "apply_patch")
        expect(SessionStrings.toolName("Read"), "Чтение", "Read")
        expect(SessionStrings.toolName("Grep"), "Поиск", "Grep")
        expect(SessionStrings.toolName("Glob"), "Поиск", "Glob")
        expect(SessionStrings.toolName("WebFetch"), "Веб", "WebFetch")
        expect(SessionStrings.toolName("FetchURL"), "Веб", "FetchURL")
        expect(SessionStrings.toolName("Task"), "Субагент", "Task")
        expect(SessionStrings.toolName("Agent"), "Субагент", "Agent")
        expect(SessionStrings.toolName("mcp__github__create_issue"), "MCP · github", "mcp")
        expect(SessionStrings.mcpTool("mcp__github__create_issue"), "create issue", "mcp tool")
        expect(SessionStrings.toolName("ReadMediaFile"), "Просмотр картинки", "ReadMediaFile")
        expect(SessionStrings.toolName("js_repl"), "Js repl", "unknown snake_case")
        expect(SessionStrings.toolName("FancyTool"), "FancyTool", "unknown CamelCase")
        expect(SessionStrings.duration(12), "12\(s)с", "12 s")
        expect(SessionStrings.duration(125), "2\(s)мин", "2 min")
        expect(SessionStrings.duration(2 * 3600 + 600), "2\(s)ч 10\(s)мин", "2 h 10 min")
        expect(SessionStrings.clock(134), "2:14", "clock")
        expect(SessionStrings.clock(3723), "1:02:03", "clock h")
        expect(SessionStrings.ago(30), "только что", "ago now")
        expect(SessionStrings.ago(300), "5\(s)мин назад", "ago 5 min")
        expect(SessionStrings.ago(7300), "2\(s)ч назад", "ago 2 h")
        expect(SessionStrings.toolDuration(0.44), "0,4\(s)с", "0.4 s")
        expect(SessionStrings.toolDuration(12.2), "12\(s)с", "12 s")
        expect(SessionStrings.toolDuration(65), "1:05", "1:05")
        expect(SessionStrings.toolDuration(.nan), "0,0\(s)с", "nan")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        expect(SessionStrings.statusWithTime(.working, since: t, now: t.addingTimeInterval(134)), "работает 2:14", "working")
        expect(SessionStrings.statusWithTime(.finished, since: t, now: t.addingTimeInterval(300)),
               "готово 5\(s)мин назад", "finished")
        expect(SessionStrings.count(3, "вызов", "вызова", "вызовов"), "3\(s)вызова", "plural few")
        expect(SessionStrings.count(11, "вызов", "вызова", "вызовов"), "11\(s)вызовов", "plural 11")
        expect(SessionStrings.count(21, "вызов", "вызова", "вызовов"), "21\(s)вызов", "plural 21")
        expect(SessionStrings.path("/Users/u/code/x", home: "/Users/u"), "~/code/x", "path")
        expect(SessionStrings.path("/Users/uu/x", home: "/Users/u"), "/Users/uu/x", "path prefix")
        expect(SessionStrings.hostApp(HostContext(termProgram: "iTerm.app")), "iTerm2", "iTerm")
        expect(SessionStrings.hostApp(HostContext(bundleIdentifier: "com.apple.Terminal", tmuxPane: "%1")),
               "Терминал · tmux", "tmux")
        expect(SessionStrings.hostApp(HostContext()), nil, "unknown host")
        expect(SessionStrings.markdownStripped("## Готово\n- раз\n\n**два** `x`"), "Готово\n• раз\nдва x", "markdown")
        expect(SessionStrings.replyLine("## Готово ⏎ Сделал: ⏎ - раз; ⏎ - два ⏎ ⏎ Проверь."),
               "Готово. Сделал: раз, два. Проверь.", "reply line")
        expect(SessionStrings.toolSummary("apply_patch", "*** Begin Patch ⏎ *** Update File: src/a.ts ⏎ @@ ⏎ *** Add File: b.ts"),
               "src/a.ts +1", "patch files")
        expect(SessionStrings.toolSummary("mcp__github__create_issue", "Релиз"), "create issue · Релиз", "mcp summary")
        print("strings: \(failures == 0 ? "ok" : "\(failures) failed")")
        return failures
    }
}

// MARK: - Live check

/// The live list (scroll view, transitions, animations; not an image) in a window that is never shown: after an
/// expansion or a collapse, how many layout passes the content's reported size takes to reach its new value. One
/// is the goal: the island's silhouette then retargets in the pass the card starts moving, on the same spring.
@MainActor
enum SessionsLiveCheck {
    final class Box: ObservableObject {
        @Published var expanded: SessionKey?
        var heights: [CGFloat] = []
    }

    private struct Host: View {
        @ObservedObject var box: Box
        let sessions: [AgentSession]

        var body: some View {
            VStack(spacing: 0) {
                Color.clear.frame(height: 46)
                SessionCardList(sessions: sessions, metrics: SessionsPreviewRenderer.floating, actions: IslandActions(),
                                expansion: $box.expanded)
                Color.clear.frame(height: 80)
            }
            .frame(width: IslandLayout.listWidth(SessionsPreviewRenderer.floating))
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [box] in box.heights.append($0) }
        }
    }

    static func run(sessions: [AgentSession], expand key: SessionKey, then other: SessionKey,
                    clock: IslandClock) -> (report: [String], problems: [String]) {
        let box = Box()
        let host = NSHostingView(rootView: Host(box: box, sessions: sessions).environment(clock)
            .environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 600, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        spin(0.5)
        var report: [String] = []
        var problems: [String] = []
        var before = box.heights.last ?? 0
        func probe(_ name: String, _ change: () -> Void) {
            box.heights.removeAll()
            withAnimation(SessionCardView.expandAnimation) { change() }
            spin(0.6)
            let distinct = box.heights.reduce(into: [CGFloat]()) { if $0.last != $1 { $0.append($1) } }
            let summary = ([before] + distinct).map { String(Int($0.rounded())) }.joined(separator: " → ")
            report.append("\(name): высота контента \(summary) (\(distinct.count) \(SessionStrings.plural(distinct.count, "шаг", "шага", "шагов")))")
            // At most one step (none when the height stays, e.g. at the cap).
            if distinct.count > 1 { problems.append("\(name): content height took \(distinct.count) steps (\(summary))") }
            before = distinct.last ?? before
        }
        probe("раскрытие") { box.expanded = key }
        probe("другая карточка") { box.expanded = other }
        probe("сворачивание") { box.expanded = nil }
        return (report, problems)
    }

    private static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002)) }
    }
}
