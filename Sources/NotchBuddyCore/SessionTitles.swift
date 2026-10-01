import Darwin
import Foundation

// Chat titles per agent and the display rules around them.

/// Naming rules shared by the island and the menu: which cwd names a project and how a prompt becomes a title.
public enum SessionNaming {
    /// A prompt used as the title is cut to this many characters (the ellipsis included).
    public static let maxPromptTitleLength = 40
    /// What the UI shows instead of a scratch or temporary folder's name (`AgentSession.projectName` is nil).
    public static var noProjectLabel: String { L("без папки") }
    /// Whitespace runs (newlines included) collapsed into single spaces, trimmed; nil when nothing is left.
    public static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// A prompt as a title: one line, at most `limit` characters (cut ones end in "…").
    public static func promptTitle(_ prompt: String?, limit: Int = maxPromptTitleLength) -> String? {
        guard let line = oneLine(prompt) else { return nil }
        guard line.count > limit else { return line }
        let kept = String(line.prefix(max(limit - 1, 1))).trimmingCharacters(in: .whitespaces)
        return kept + "…"
    }

    /// Roots whose subfolders are never projects.
    static let tempRoots = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders", "/private/var/folders"]

    /// Whether `path` is a scratch or temporary folder whose name means nothing to the user: Claude Desktop's
    /// `…/Claude/scratch-workspaces/…/scratch-2026-01-02-a1b2c3`, `/tmp`, `/private/var/folders`, the app's own
    /// temporary directory.
    public static func isScratchOrTemp(_ path: String) -> Bool {
        let std = (path as NSString).standardizingPath
        if std.contains("/Claude/scratch-workspaces/") || std.hasSuffix("/Claude/scratch-workspaces") { return true }
        var roots = tempRoots
        let tmp = (NSTemporaryDirectory() as NSString).standardizingPath
        if tmp.count > 1 { roots.append(tmp) }
        for root in roots where std == root || std.hasPrefix(root + "/") || path == root || path.hasPrefix(root + "/") {
            return true
        }
        return isScratchName((std as NSString).lastPathComponent)
    }

    /// `scratch-YYYY-MM-DD-<hex>`: a Claude Desktop scratch folder, wherever it lives.
    static func isScratchName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "scratch" else { return false }
        let digits = [4, 2, 2]
        for (part, count) in zip(parts[1...3], digits) where part.count != count || !part.allSatisfy(\.isASCIIDigit) {
            return false
        }
        return parts[4].count >= 4 && parts[4].allSatisfy(\.isHexDigit)
    }

    /// The project folder's name for a session's cwd; nil for none, `/`, and scratch or temporary folders.
    public static func projectName(forCwd cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty, !isScratchOrTemp(cwd) else { return nil }
        let name = ((cwd as NSString).standardizingPath as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

// MARK: - Claude

/// Chat titles in a Claude Code transcript (`transcript_path`, JSONL). Claude re-appends them as the chat goes on,
/// so the newest record of each kind wins:
/// - `{"type":"custom-title","customTitle":…}`: the name the Claude app shows in its sidebar, or `/rename`;
/// - `{"type":"ai-title","aiTitle":…}`: the title Claude Code generated;
/// - `{"type":"summary","summary":…}`: older versions.
public enum ClaudeTranscriptTitle {
    public struct Titles: Equatable, Sendable {
        public var custom: String?
        public var ai: String?
        public var summary: String?

        public init(custom: String? = nil, ai: String? = nil, summary: String? = nil) {
            self.custom = custom
            self.ai = ai
            self.summary = summary
        }

        /// The title to show: the user's (or the app's) name first, then the generated one, then a summary.
        public var best: String? { custom ?? ai ?? summary }
        public var isEmpty: Bool { custom == nil && ai == nil && summary == nil }

        /// These titles with the kinds `newer` found replaced by its (later records win).
        public func updated(with newer: Titles) -> Titles {
            Titles(custom: newer.custom ?? custom, ai: newer.ai ?? ai, summary: newer.summary ?? summary)
        }
    }

    /// Title records are short; longer lines (tool output, messages) are not even parsed.
    public static let maxRecordLength = 16 * 1024

    /// The title to show from a chunk of the transcript (usually its tail): the last `custom-title`, else the
    /// last `ai-title`, else the last `summary`. `dropFirstLine`: the chunk starts mid-line (a tail read), so its
    /// first line is a fragment.
    public static func lastTitle(in tailData: Data, dropFirstLine: Bool = false) -> String? {
        titles(in: tailData, dropFirstLine: dropFirstLine).best
    }

    /// The newest title record of each kind in `data`. Unparsable lines (a fragment, a line still being written)
    /// are skipped.
    public static func titles(in data: Data, dropFirstLine: Bool = false) -> Titles {
        var found = Titles()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)[...]
        if dropFirstLine { lines = lines.dropFirst() }
        for line in lines.reversed() {
            guard !line.isEmpty, line.count <= maxRecordLength else { continue }
            let text = String(decoding: line, as: UTF8.self)
            guard text.contains("custom-title\"") || text.contains("ai-title\"") || text.contains("\"summary\"")
            else { continue }
            guard let record = try? JSONValue.parse(Data(line)) else { continue }
            switch strictString(record["type"]) {
            case "custom-title" where found.custom == nil:
                found.custom = SessionNaming.oneLine(strictString(record["customTitle"]))
            case "ai-title" where found.ai == nil:
                found.ai = SessionNaming.oneLine(strictString(record["aiTitle"]))
            case "summary" where found.summary == nil:
                found.summary = SessionNaming.oneLine(strictString(record["summary"]))
            default:
                break
            }
            if found.custom != nil { break }   // nothing older can beat it
        }
        return found
    }

    /// Follows one transcript cheaply: re-reads only when the file's size, mtime or identity changed, and then only
    /// what was appended since the last read, at most its last `tailBytes`. When the first read finds no title,
    /// the last `backscanBytes` are scanned once. Not thread-safe: use it from one queue.
    public struct Tracker: Sendable {
        public static let tailBytes: UInt64 = 64 * 1024
        public static let backscanBytes: UInt64 = 1024 * 1024

        public let path: String
        /// Everything found so far (newest of each kind).
        public private(set) var titles = Titles()
        /// How many times the file was actually read (tests, logging).
        public private(set) var reads = 0
        private var stamp: FileStamp?
        /// A line boundary up to which the file has been scanned.
        private var scannedTo: UInt64?
        private var backscanned = false

        public init(path: String) {
            self.path = path
        }

        /// Reads what changed; returns whether `titles` changed. A missing or unreadable file keeps what was found.
        @discardableResult
        public mutating func refresh() -> Bool {
            guard let now = FileStamp(path: path), now != stamp else { return false }
            if let old = stamp, !now.sameFile(as: old) || now.size < old.size {
                // Replaced or truncated: offsets mean nothing any more (the titles found stay until newer ones).
                scannedTo = nil
                backscanned = false
            }
            stamp = now
            let size = now.size
            var start = size > Self.tailBytes ? size - Self.tailBytes : 0
            var midLine = start > 0
            if let boundary = scannedTo, boundary >= start, boundary <= size {
                start = boundary
                midLine = false
            }
            guard start < size, let data = FileStamp.read(path, from: start, count: size - start) else { return false }
            reads += 1
            var found = ClaudeTranscriptTitle.titles(in: data, dropFirstLine: midLine)
            if let newline = data.lastIndex(of: 0x0A) {
                scannedTo = start + UInt64(data.distance(from: data.startIndex, to: newline) + 1)
            } else if midLine {
                scannedTo = nil
            }
            if titles.isEmpty, found.isEmpty, !backscanned, start > 0 {
                // A long transcript whose tail holds no title record yet: look further back, once.
                backscanned = true
                let from = size > Self.backscanBytes ? size - Self.backscanBytes : 0
                if from < start, let older = FileStamp.read(path, from: from, count: size - from) {
                    reads += 1
                    found = ClaudeTranscriptTitle.titles(in: older, dropFirstLine: from > 0)
                }
            }
            let updated = titles.updated(with: found)
            let changed = updated != titles
            titles = updated
            return changed
        }
    }
}

// MARK: - Codex

/// Codex thread names: `$CODEX_HOME/session_index.jsonl` lines
/// `{"id":"<thread id>","thread_name":"…","updated_at":"…"}`. A hook's `session_id` is the thread id.
public enum CodexSessionIndex {
    /// thread id → name; for an id listed more than once the latest line wins. Bad lines are skipped.
    public static func parse<S: Sequence>(lines: S) -> [String: String] where S.Element: StringProtocol {
        var names: [String: String] = [:]
        for line in lines {
            guard line.contains("thread_name"), let record = try? JSONValue.parse(Data(line.utf8)),
                  let id = strictString(record["id"]), !id.isEmpty,
                  let name = SessionNaming.oneLine(strictString(record["thread_name"])) else { continue }
            names[id] = name
        }
        return names
    }

    /// `parse(lines:)` over a chunk of the file.
    public static func parse(_ data: Data) -> [String: String] {
        parse(lines: String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline))
    }

    /// The index file under Codex's home (`CODEX_HOME`, else `~/.codex`).
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let home = environment["CODEX_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("session_index.jsonl")
        }
        return Paths.home.appendingPathComponent(".codex/session_index.jsonl").path
    }

    /// Follows the (append-only) index: re-reads only when its size, mtime or identity changed, then only the
    /// lines appended since; a replaced or truncated file is read again from the start. Not thread-safe.
    public struct Tracker: Sendable {
        /// A first read of a larger file takes only its tail.
        public static let maxRead: UInt64 = 8 * 1024 * 1024

        public let path: String
        public private(set) var names: [String: String] = [:]
        public private(set) var reads = 0
        private var stamp: FileStamp?
        /// Line boundary up to which the file has been parsed.
        private var parsedTo: UInt64 = 0

        public init(path: String = CodexSessionIndex.defaultPath()) {
            self.path = path
        }

        /// Reads what changed; returns whether `names` changed.
        @discardableResult
        public mutating func refresh() -> Bool {
            guard let now = FileStamp(path: path), now != stamp else { return false }
            var rebuilt = false
            if let old = stamp, !now.sameFile(as: old) || now.size < parsedTo {
                parsedTo = 0
                rebuilt = true
            }
            stamp = now
            var start = parsedTo
            var midLine = false
            if now.size - start > Self.maxRead {
                start = now.size - Self.maxRead
                midLine = true
            }
            guard start < now.size, let data = FileStamp.read(path, from: start, count: now.size - start) else {
                if rebuilt, !names.isEmpty { names = [:]; return true }
                return false
            }
            reads += 1
            // Only complete lines: the last one may still be being written.
            guard let newline = data.lastIndex(of: 0x0A) else {
                if rebuilt, !names.isEmpty { names = [:]; return true }
                return false
            }
            parsedTo = start + UInt64(data.distance(from: data.startIndex, to: newline) + 1)
            var complete = data[data.startIndex..<newline]
            if midLine {
                // The chunk starts inside a line: skip that fragment.
                complete = complete.firstIndex(of: 0x0A).map { complete[complete.index(after: $0)...] } ?? Data()
            }
            let parsed = CodexSessionIndex.parse(Data(complete))
            let updated = rebuilt ? parsed : names.merging(parsed) { _, latest in latest }
            let changed = updated != names
            names = updated
            return changed
        }
    }
}

/// A JSON string value only (`JSONValue.string` also renders numbers and booleans as text).
private func strictString(_ value: JSONValue?) -> String? {
    if case .string(let s)? = value { return s }
    return nil
}

// MARK: - Files

/// What says a file changed: size, mtime and identity (device + inode).
struct FileStamp: Equatable, Sendable {
    var size: UInt64
    var mtimeSeconds: Int
    var mtimeNanoseconds: Int
    var device: Int32
    var inode: UInt64

    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        size = UInt64(max(st.st_size, 0))
        mtimeSeconds = st.st_mtimespec.tv_sec
        mtimeNanoseconds = st.st_mtimespec.tv_nsec
        device = st.st_dev
        inode = UInt64(st.st_ino)
    }

    func sameFile(as other: FileStamp) -> Bool { device == other.device && inode == other.inode }

    /// Up to `count` bytes of `path` from `offset`; nil when it cannot be read.
    static func read(_ path: String, from offset: UInt64, count: UInt64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: Int(clamping: count)) ?? Data()
        } catch {
            return nil
        }
    }
}
