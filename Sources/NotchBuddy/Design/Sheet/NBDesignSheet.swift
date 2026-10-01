import AppKit
import SwiftUI

/// `NotchBuddy --render-design <dir>`: renders the design system to PNGs (type scale, colors, every
/// icon, icon motion filmstrips, components in every state, a settings panel built from them), runs
/// the design lint (`NBDesignLint`), and exits. Nothing else starts.
@MainActor
enum NBDesignSheet {
    nonisolated static let flag = "--render-design"

    nonisolated static func requestedDirectory(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return index + 1 < arguments.count ? arguments[index + 1] : "build/design"
    }

    /// Entry point for `main.swift` (top-level code runs on the main thread).
    nonisolated static func runFromMain(_ directory: String) -> Int32 {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            return run(outputDirectory: directory)
        }
    }

    static let pageWidth: CGFloat = 1180

    static func run(outputDirectory: String) -> Int32 {
        NBTypography.registerBundledFonts()
        let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }
        var failures = 0
        let pages: [(String, AnyView)] = [
            ("01-typography", AnyView(NBSheetTypography())),
            ("02-color", AnyView(NBSheetColor())),
            ("03-icons", AnyView(NBSheetIcons())),
            ("03b-icons-large", AnyView(NBSheetIconsLarge())),
            ("04-icon-motion", AnyView(NBSheetIconMotion())),
            ("05-components", AnyView(NBSheetComponents())),
            ("06-settings", AnyView(NBSheetSettingsMock())),
        ]
        let only = ProcessInfo.processInfo.environment["NOTCHBUDDY_DESIGN_PAGES"].map {
            Set($0.split(separator: ",").map(String.init))
        }
        for (name, page) in pages where only == nil || only!.contains(where: { name.contains($0) }) {
            let view = NBSheetPage { page }
            failures += write(image(view), to: directory.appendingPathComponent("\(name).png")) ? 0 : 1
        }
        let lint = NBDesignLint.run()
        for line in lint.report { print("design-lint: \(line)") }
        for problem in lint.problems {
            FileHandle.standardError.write(Data("design-lint FAILED: \(problem)\n".utf8))
        }
        failures += lint.problems.count
        if ProcessInfo.processInfo.environment["NOTCHBUDDY_DESIGN_LIVE"] != "0" {
            let live = NBDesignLiveCheck.run()
            for line in live.report { print("design-\(line)") }
            for problem in live.problems {
                FileHandle.standardError.write(Data("design-live FAILED: \(problem)\n".utf8))
            }
            failures += live.problems.count
        }
        return failures == 0 ? 0 : 1
    }

    static func image<V: View>(_ view: V, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: view
            .environment(\.colorScheme, .dark)
            .environment(\.islandStaticRender, true))
        renderer.scale = scale
        return renderer.cgImage
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
}

// MARK: - Page chrome

/// The page: a deep charcoal backdrop with a faint aurora, so the black island panels read as objects.
struct NBSheetPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            NBSheetMasthead()
            content()
            NBSheetFooter()
        }
        .padding(44)
        .frame(width: NBDesignSheet.pageWidth, alignment: .leading)
        .background {
            ZStack {
                Color(red: 0.045, green: 0.045, blue: 0.055)
                RadialGradient(colors: [NBAccent.brand.base.opacity(0.16), .clear],
                               center: UnitPoint(x: 0.08, y: 0.0), startRadius: 0, endRadius: 520)
                RadialGradient(colors: [NBAccent.magic.base.opacity(0.10), .clear],
                               center: UnitPoint(x: 0.95, y: 0.02), startRadius: 0, endRadius: 440)
            }
        }
    }
}

private struct NBSheetMasthead: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            NBIconTile(icon: .sparkle, accent: .magic, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("NotchBuddy · Дизайн-система")
                    .font(.manrope(22, weight: 780))
                    .tracking(-0.5)
                    .foregroundStyle(NBColor.ink)
                Text("Manrope · \(NBIcon.allCases.count) иконок с анимацией · токены цвета, света и движения · компоненты")
                    .nbText(.callout)
                    .foregroundStyle(NBColor.inkTertiary)
            }
            Spacer()
            NBChip(NBTypography.isManropeAvailable ? "Manrope подключён" : "Manrope не найден — системный шрифт",
                   icon: NBTypography.isManropeAvailable ? .done : .error,
                   accent: NBTypography.isManropeAvailable ? .done : .error)
        }
    }
}

private struct NBSheetFooter: View {
    var body: some View {
        Text("NotchBuddy --render-design · Sources/NotchBuddy/Design")
            .font(.manrope(10, weight: 600))
            .tracking(0.4)
            .foregroundStyle(NBColor.inkQuaternary)
    }
}

/// A section: number + title + note, then a black island panel.
struct NBSheetSection<Content: View>: View {
    var number: String
    var title: String
    var note: String?
    var padding: CGFloat = 24
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(number)
                    .font(.nbNumeric(11, weight: 800))
                    .foregroundStyle(NBAccent.brand.bright)
                Text(title)
                    .font(.manrope(15, weight: 740))
                    .tracking(-0.2)
                    .foregroundStyle(NBColor.ink)
                if let note {
                    Text(note)
                        .nbText(.callout)
                        .foregroundStyle(NBColor.inkTertiary)
                }
            }
            .padding(.leading, 4)
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
        }
    }
}

/// Small caption under a specimen.
struct NBSheetCaption: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.manrope(10, weight: 600))
            .tracking(0.2)
            .foregroundStyle(NBColor.inkTertiary)
    }
}
