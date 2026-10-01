import XCTest
@testable import NotchBuddyCore

/// Record shapes as seen in real transcripts and the Codex index.
final class SessionTitleTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nb-titles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private func custom(_ title: String) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"s1"}"#
    }

    private func ai(_ title: String) -> String {
        #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"s1"}"#
    }

    private func user(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u1","sessionId":"s1"}"#
    }

    private func jsonl(_ lines: [String]) -> Data { Data(lines.map { $0 + "\n" }.joined().utf8) }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: ClaudeTranscriptTitle

    func testLastCustomTitleWins() {
        let data = jsonl([
            user("привет"), custom("Первое имя"), ai("Generated"),
            #"{"type":"assistant","message":{"content":"ok"}}"#, custom("Рефакторинг настроек"), user("ещё"),
        ])
        XCTAssertEqual(ClaudeTranscriptTitle.lastTitle(in: data), "Рефакторинг настроек")
    }

    func testFallsBackToAiTitleThenSummary() {
        XCTAssertEqual(ClaudeTranscriptTitle.lastTitle(in: jsonl([
            #"{"type":"summary","summary":"Старое резюме","leafUuid":"l1"}"#, ai("Review embedded SPA"), user("x"),
        ])), "Review embedded SPA")
        XCTAssertEqual(ClaudeTranscriptTitle.lastTitle(in: jsonl([
            #"{"type":"summary","summary":"Резюме 1","leafUuid":"l1"}"#,
            #"{"type":"summary","summary":"Резюме 2","leafUuid":"l2"}"#, user("x"),
        ])), "Резюме 2")
        XCTAssertNil(ClaudeTranscriptTitle.lastTitle(in: jsonl([user("x"), #"{"type":"last-prompt","lastPrompt":"x"}"#])))
        XCTAssertNil(ClaudeTranscriptTitle.lastTitle(in: Data()))
    }

    func testMentionsInMessagesAndBrokenLinesAreIgnored() {
        let data = jsonl([
            custom("Настоящее"),
            // A message that talks about the record type is not a record.
            user(#"найди \"type\":\"custom-title\" и \"customTitle\":\"Подделка\""#),
            #"{"type":"custom-title","customTitle":"#,          // cut line
            #"{"type":"custom-title","customTitle":"   "}"#,     // blank title
            #"{"type":"custom-title","customTitle":42}"#,
        ])
        XCTAssertEqual(ClaudeTranscriptTitle.lastTitle(in: data), "Настоящее")
    }

    func testTailFragmentIsDroppedAndLastLineMayBeUnterminated() {
        let full = custom("Фрагмент") + "\n" + custom("Целое")
        // A tail read starting inside the first record: that fragment must not count.
        let tail = Data(full.utf8).dropFirst(5)
        XCTAssertEqual(ClaudeTranscriptTitle.titles(in: Data(tail), dropFirstLine: true).custom, "Целое")
        let onlyFragment = Data(custom("Фрагмент").utf8)
        XCTAssertNil(ClaudeTranscriptTitle.lastTitle(in: onlyFragment, dropFirstLine: true))
        XCTAssertEqual(ClaudeTranscriptTitle.lastTitle(in: onlyFragment), "Фрагмент")
    }

    func testTitleIsOneLineAndHugeLinesAreSkipped() {
        let huge = #"{"type":"custom-title","customTitle":""# + String(repeating: "x", count: ClaudeTranscriptTitle.maxRecordLength) + #""}"#
        XCTAssertEqual(ClaudeTranscriptTitle.lastTitle(in: jsonl([custom(#"Две\nстроки"#), huge])), "Две строки")
    }

    func testTitlesMergeKindByKind() {
        let old = ClaudeTranscriptTitle.Titles(custom: "A", ai: "B", summary: "C")
        XCTAssertEqual(old.updated(with: .init(ai: "B2")), .init(custom: "A", ai: "B2", summary: "C"))
        XCTAssertEqual(old.updated(with: .init(ai: "B2")).best, "A")
        XCTAssertEqual(ClaudeTranscriptTitle.Titles(ai: "B", summary: "C").best, "B")
        XCTAssertTrue(ClaudeTranscriptTitle.Titles().isEmpty)
    }

    // MARK: ClaudeTranscriptTitle.Tracker

    func testTrackerReadsOnlyWhenTheFileChanges() throws {
        let url = dir.appendingPathComponent("s1.jsonl")
        var tracker = ClaudeTranscriptTitle.Tracker(path: url.path)
        XCTAssertFalse(tracker.refresh(), "missing file")
        XCTAssertEqual(tracker.reads, 0)

        try jsonl([user("привет")]).write(to: url)
        XCTAssertFalse(tracker.refresh())
        XCTAssertNil(tracker.titles.best)
        XCTAssertEqual(tracker.reads, 1)

        XCTAssertFalse(tracker.refresh(), "unchanged")
        XCTAssertEqual(tracker.reads, 1)

        try append(custom("Игра") + "\n", to: url)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.titles.best, "Игра")
        XCTAssertEqual(tracker.reads, 2)

        // Another title, then a record still being written: the complete one counts, the partial is read again.
        try append(custom("Игра в змейку") + "\n" + #"{"type":"custom-title","custom"#, to: url)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.titles.best, "Игра в змейку")
        try append(#"Title":"Финал","sessionId":"s1"}"# + "\n", to: url)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.titles.best, "Финал")

        // Appending lines without a title keeps the title.
        try append(user("дальше") + "\n", to: url)
        XCTAssertFalse(tracker.refresh())
        XCTAssertEqual(tracker.titles.best, "Финал")
    }

    func testTrackerReadsOnlyTheTailOfALongTranscript() throws {
        let url = dir.appendingPathComponent("long.jsonl")
        let filler = user(String(repeating: "ы", count: 2000))   // ~4 KB per line
        let lines = [custom("Старое")] + Array(repeating: filler, count: 40) + [custom("Новое")]
            + Array(repeating: filler, count: 10)
        try jsonl(lines).write(to: url)
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! UInt64,
                             ClaudeTranscriptTitle.Tracker.tailBytes)
        var tracker = ClaudeTranscriptTitle.Tracker(path: url.path)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.titles.best, "Новое")
        XCTAssertEqual(tracker.reads, 1, "the title was in the tail: no backscan")
    }

    func testTrackerLooksFurtherBackOnceWhenTheTailHasNoTitle() throws {
        let url = dir.appendingPathComponent("back.jsonl")
        let filler = user(String(repeating: "ы", count: 2000))
        try jsonl([custom("Давнее имя")] + Array(repeating: filler, count: 60)).write(to: url)
        var tracker = ClaudeTranscriptTitle.Tracker(path: url.path)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.titles.best, "Давнее имя")
        XCTAssertEqual(tracker.reads, 2)
    }

    func testTrackerStartsOverWhenTheFileIsReplaced() throws {
        let url = dir.appendingPathComponent("r.jsonl")
        try jsonl([user("a"), user("b"), custom("Один")]).write(to: url)
        var tracker = ClaudeTranscriptTitle.Tracker(path: url.path)
        tracker.refresh()
        XCTAssertEqual(tracker.titles.best, "Один")
        try FileManager.default.removeItem(at: url)
        try jsonl([custom("Два")]).write(to: url)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.titles.best, "Два")
    }

    // MARK: CodexSessionIndex

    func testCodexIndexLatestLineWins() {
        let names = CodexSessionIndex.parse(lines: [
            #"{"id":"019c7234","thread_name":"Создать игру","updated_at":"2026-03-25T13:31:08Z"}"#,
            #"{"id":"019c8694","thread_name":"Другой тред","updated_at":"2026-03-26T10:00:00Z"}"#,
            #"{"id":"019c7234","thread_name":"Создать игру в змейку","updated_at":"2026-03-27T09:00:00Z"}"#,
            #"{"id":"019c9999","thread_name":"","updated_at":"2026-03-27T09:00:00Z"}"#,
            #"{"id":"","thread_name":"Без id"}"#,
            #"{"id":"019c8694","thread_name":null}"#,
            "not json",
            #"{"id":"019caaaa","thread_na"#,
        ])
        XCTAssertEqual(names, ["019c7234": "Создать игру в змейку", "019c8694": "Другой тред"])
        XCTAssertEqual(CodexSessionIndex.parse(Data((#"{"id":"a","thread_name":"Имя"}"# + "\r\n").utf8)), ["a": "Имя"])
    }

    func testCodexIndexDefaultPath() {
        XCTAssertEqual(CodexSessionIndex.defaultPath(environment: ["CODEX_HOME": "/x/codex"]), "/x/codex/session_index.jsonl")
        XCTAssertTrue(CodexSessionIndex.defaultPath(environment: [:]).hasSuffix("/.codex/session_index.jsonl"))
    }

    func testCodexTrackerFollowsAppends() throws {
        let url = dir.appendingPathComponent("session_index.jsonl")
        var tracker = CodexSessionIndex.Tracker(path: url.path)
        XCTAssertFalse(tracker.refresh())
        try (#"{"id":"t1","thread_name":"Первый"}"# + "\n").write(to: url, atomically: false, encoding: .utf8)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.names, ["t1": "Первый"])
        XCTAssertFalse(tracker.refresh())
        XCTAssertEqual(tracker.reads, 1)

        // A half-written line waits for its newline.
        try append(#"{"id":"t2","thread_"#, to: url)
        XCTAssertFalse(tracker.refresh())
        try append(#"name":"Второй"}"# + "\n" + #"{"id":"t1","thread_name":"Переименован"}"# + "\n", to: url)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.names, ["t1": "Переименован", "t2": "Второй"])

        // Rewritten from scratch: names no longer listed are gone.
        try FileManager.default.removeItem(at: url)
        try (#"{"id":"t3","thread_name":"Третий"}"# + "\n").write(to: url, atomically: false, encoding: .utf8)
        XCTAssertTrue(tracker.refresh())
        XCTAssertEqual(tracker.names, ["t3": "Третий"])
    }
}
