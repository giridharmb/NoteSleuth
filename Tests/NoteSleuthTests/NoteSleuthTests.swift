import XCTest
@testable import NoteSleuth

final class NoteSleuthTests: XCTestCase {
    // MARK: Fixtures

    private func ld(_ field: Int, _ payload: [UInt8]) -> [UInt8] {
        var out = [UInt8(field << 3 | 2)]
        var n = payload.count
        repeat { var b = UInt8(n & 0x7f); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        return out + payload
    }

    /// NoteStoreProto(2) → Document(3) → Note(2) text, with a varint field in front to exercise skipping.
    private func noteBlob(_ text: String) throws -> Data {
        let proto = [0x08, 0x01] + ld(2, [0x08, 0x00] + ld(3, ld(2, Array(text.utf8))))
        return try gzip(Data(proto))
    }

    private func gzip(_ d: Data) throws -> Data {
        let p = Process(), inPipe = Pipe(), outPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c", "-n"]
        p.standardInput = inPipe
        p.standardOutput = outPipe
        try p.run()
        inPipe.fileHandleForWriting.write(d)
        try inPipe.fileHandleForWriting.close()
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return out
    }

    private func note(_ title: String, _ body: String, tags: [String] = [], daysAgo: Double = 1, folder: String = "Notes") -> Note {
        var n = Note(pk: Int64(title.hashValue & 0xffff), id: UUID().uuidString, title: title, text: title + "\n" + body,
                     folder: folder, modified: Date().addingTimeInterval(-daysAgo * 86400), locked: false)
        n.tags = tags
        return n
    }

    // MARK: Decoder

    func testDecodesGzippedProtobuf() throws {
        let text = "Grocery list\nmilk, eggs, café ☕️ \u{FFFC}"
        XCTAssertEqual(NoteDecoder.text(from: try noteBlob(text)), "Grocery list\nmilk, eggs, café ☕️ ") // placeholder dropped
        XCTAssertNil(NoteDecoder.text(from: Data([0x1f, 0x8b, 1, 2, 3])))
        XCTAssertNil(NoteDecoder.text(from: Data()))
        // Older notes are zlib-framed: 78 9c + raw deflate + adler32 (not checked).
        let proto = Data(ld(2, ld(3, ld(2, Array("Old note".utf8)))))
        let zlib = Data([0x78, 0x9c]) + (try (proto as NSData).compressed(using: .zlib) as Data) + Data([0, 0, 0, 0])
        XCTAssertEqual(NoteDecoder.text(from: zlib), "Old note")
    }

    private func vi(_ field: Int, _ v: Int) -> [UInt8] {
        var out = [UInt8(field << 3)], n = v
        repeat { var b = UInt8(n & 0x7f); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0
        return out
    }

    func testDecodesFormattingRuns() throws {
        // "Plan\nBuy \u{FFFC} milk\nDone\nStep\nPic \u{FFFC}" with title, bold, hashtag, checklist, numbered list, image.
        let text = "Plan\nBuy \u{FFFC} milk\nDone\nStep\nPic \u{FFFC}"
        func run(_ len: Int, para: Int? = nil, checked: Bool = false, weight: Int? = nil, attach: (String, String)? = nil) -> [UInt8] {
            var r = vi(1, len)
            if let para { r += ld(2, vi(1, para) + (checked ? ld(5, ld(1, [1]) + vi(2, 1)) : [])) }
            if let weight { r += vi(5, weight) }
            if let attach { r += ld(12, ld(1, Array(attach.0.utf8)) + ld(2, Array(attach.1.utf8))) }
            return ld(5, r)
        }
        let runs = run(5, para: 0) + run(4, weight: 1) + run(1, attach: ("TAG1", "com.apple.notes.inlinetextattachment.hashtag"))
            + run(6) + run(5, para: 103, checked: true) + run(5, para: 102) + run(4) + run(1, attach: ("IMG1", "public.jpeg"))
        let proto = ld(2, ld(3, ld(2, Array(text.utf8)) + runs))
        let spans = try XCTUnwrap(NoteDecoder.spans(from: try gzip(Data(proto)), altText: ["TAG1": "#groceries"]))
        XCTAssertEqual(spans.map(\.text).joined(), "Plan\nBuy #groceries milk\nDone\nStep\nPic [🖼 Image]")
        XCTAssertEqual(spans[0].style.paragraph, 0)
        XCTAssertTrue(spans[1].style.bold)
        XCTAssertTrue(spans[4].style.checked)
        XCTAssertEqual(spans[5].style.paragraph, 102)
        XCTAssertTrue(spans[7].style.attachment)

        // is:todo sees only unticked items; "Done" above is ticked.
        let done = Note(pk: 1, id: "a", title: nil, spans: spans, folder: "Notes", modified: Date(), locked: false)
        XCTAssertNil(done.openTodo)
        var open = spans
        open[4].style.checked = false
        XCTAssertEqual(Note(pk: 1, id: "a", title: nil, spans: open, folder: "Notes", modified: Date(), locked: false).openTodo, "Done")
        // Link targets are searchable even though only the link text is visible.
        var linked = Note(pk: 2, id: "b", title: nil, spans: [Span(text: "Repo\nsee here", style: TextStyle(link: "https://github.com/x/y"))],
                          folder: "Notes", modified: Date(), locked: false)
        linked.account = "iCloud"
        let idx = SearchIndex(notes: [done, linked])
        XCTAssertEqual(idx.search(.parse("github.com"), SearchOptions()).map(\.id), ["b"])
        XCTAssertEqual(idx.search(.parse("in:icl"), SearchOptions()).map(\.id), ["b"]) // in: also matches the account
        XCTAssertTrue(idx.multipleAccounts)

        XCTAssertEqual(NoteFormatter.markdown(spans), "# Plan\n**Buy** #groceries milk\n- [x] Done\n1. Step\nPic [🖼 Image]")
        let md = NoteFormatter.markdown([Span(text: "let x = 1\nprint(x)\n", style: TextStyle(paragraph: 4)),
                                         Span(text: "see ", style: TextStyle(quote: true)), Span(text: "docs", style: TextStyle(italic: true, link: "https://a.b"))])
        XCTAssertEqual(md, "```\nlet x = 1\nprint(x)\n```\n> see [*docs*](https://a.b)")

        let lines = NoteFormatter.renderLines(spans, highlight: ["milk"], skipTitle: "Plan")
        XCTAssertEqual(lines.map(\.hit), [true, false, false, false])

        let rendered = String(NoteFormatter.render(spans, highlight: ["milk"], skipTitle: "Plan").characters)
        XCTAssertEqual(rendered, "Buy #groceries milk\n◉  Done\n1.  Step\nPic [🖼 Image]")
    }

    // MARK: Query

    func testQueryParsing() {
        let q = Query.parse("  groc #Work|#home -#Archive #urgent Café ")
        XCTAssertEqual(q.terms, ["groc", "cafe"])
        XCTAssertEqual(q.tagGroups, [["work", "home"], ["urgent"]])
        XCTAssertEqual(q.excludedTags, ["archive"])
        XCTAssertTrue(Query.parse("  # ").isEmpty)
        XCTAssertEqual(Query.parse("IN:Wörk in: x").folders, ["work"])
        let p = Query.parse("milk \"Project Plan\" in:\"my folder\" is:todo \"open")
        XCTAssertEqual(p.terms, ["milk"])
        XCTAssertEqual(p.phrases, ["project plan", "open"]) // unclosed quote runs to the end
        XCTAssertEqual(p.folders, ["my folder"])
        XCTAssertTrue(p.todoOnly)
        XCTAssertEqual(p.highlights, ["milk", "project plan", "open"])

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let d = Query.parse("edited:2w before:2025-06 x", now: now)
        XCTAssertEqual(d.after, Calendar.current.date(byAdding: .weekOfYear, value: -2, to: now))
        XCTAssertEqual(d.before, Calendar.current.date(from: DateComponents(year: 2025, month: 6, day: 1)))
        XCTAssertEqual(d.terms, ["x"])
        XCTAssertEqual(Query.parse("after:2025-02-30 edited:soon before:99").terms, ["after:2025-02-30", "edited:soon", "before:99"]) // invalid dates stay words
    }

    func testEditDistance() {
        XCTAssertTrue(SearchIndex.withinOneEdit(Array("grocery".utf8), Array("grocrey".utf8))) // transposition
        XCTAssertTrue(SearchIndex.withinOneEdit(Array("grocery".utf8), Array("grocey".utf8)))  // deletion
        XCTAssertTrue(SearchIndex.withinOneEdit(Array("grocery".utf8), Array("grocary".utf8))) // substitution
        XCTAssertFalse(SearchIndex.withinOneEdit(Array("grocery".utf8), Array("gracary".utf8)))
    }

    // MARK: Search

    func testSearchRankingTagsAndTypos() {
        let idx = SearchIndex(notes: [
            note("Grocery list", "milk eggs bread", tags: ["home"]),
            note("Meeting notes", "discuss grocery budget", tags: ["work", "urgent"]),
            note("Trip plan", "flights hotel", tags: ["travel"], daysAgo: 300),
            note("Old work", "archive me", tags: ["work", "archive"], folder: "Archive"),
        ])
        let o = SearchOptions()
        XCTAssertEqual(idx.search(.parse("grocery"), o).map(\.title), ["Grocery list", "Meeting notes"]) // title beats body
        XCTAssertEqual(idx.search(.parse("grcry"), o).first?.title, "Grocery list")                     // fuzzy title
        XCTAssertEqual(idx.search(.parse("hotle"), o).map(\.title), ["Trip plan"])                       // typo in body
        XCTAssertEqual(idx.search(.parse("brea"), o).map(\.title), ["Grocery list"])                     // prefix
        XCTAssertEqual(Set(idx.search(.parse("#work"), o).map(\.title)), ["Meeting notes", "Old work"])
        XCTAssertEqual(idx.search(.parse("#work -#archive"), o).map(\.title), ["Meeting notes"])
        XCTAssertEqual(Set(idx.search(.parse("#home|#travel"), o).map(\.title)), ["Grocery list", "Trip plan"])
        XCTAssertEqual(idx.search(.parse("#work #urgent"), o).map(\.title), ["Meeting notes"])
        XCTAssertEqual(idx.search(.parse("#trav"), o).map(\.title), ["Trip plan"])                       // tag prefix
        XCTAssertTrue(idx.search(.parse("zzzz"), o).isEmpty)
        XCTAssertEqual(Set(idx.search(.parse("edited:1w"), o).map(\.title)), ["Grocery list", "Meeting notes", "Old work"]) // Trip plan is 300 days old
        XCTAssertEqual(idx.search(.parse("before:\(Calendar.current.component(.year, from: Date()) + 1) edited:2y -#work"), o).count, 2)
        XCTAssertTrue(idx.search(.parse("after:\(Calendar.current.component(.year, from: Date()) + 1)"), o).isEmpty)
        XCTAssertEqual(idx.search(.parse("#work in:arch"), o).map(\.title), ["Old work"])                // folder filter
        XCTAssertEqual(idx.search(.parse("in:notes in:arch"), o).count, 4)                               // folders ORed
        XCTAssertEqual(idx.search(.parse("\"eggs bread\""), o).map(\.title), ["Grocery list"])           // exact phrase
        XCTAssertTrue(idx.search(.parse("\"bread eggs\""), o).isEmpty)                                   // wrong order
        XCTAssertEqual(idx.search(.parse("grocery"), SearchOptions(sortByDate: true)).map(\.title),                    // newest first
                       idx.notes.map(\.title).filter { ["Grocery list", "Meeting notes"].contains($0) })
        XCTAssertEqual(idx.search(.parse("hotle"), SearchOptions(typoTolerance: false)).count, 0)
        XCTAssertEqual(idx.search(.parse("milk"), SearchOptions(searchBody: false)).count, 0)
    }

    func testSearchIsFastOnLargeLibrary() {
        let words = ["alpha", "beta", "gamma", "delta", "project", "meeting", "budget", "travel", "recipe", "code"]
        let notes = (0..<10_000).map { i in
            note("Note \(i) \(words[i % 10])", (0..<200).map { words[($0 * 7 + i) % 10] + "\($0 % 50)" }.joined(separator: " "),
                 tags: [words[i % 7]])
        }
        let idx = SearchIndex(notes: notes)
        measure { _ = idx.search(.parse("projet budg #gamma"), SearchOptions()) }
    }

    // MARK: Database

    func testReadsNotesDatabaseSchema() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("NoteStore.sqlite").path
        let blob = try noteBlob("Hello world\nsecond line").map { String(format: "%02x", $0) }.joined()
        // MergableDataProto(2) → object(3) → entries(3), two of which carry a cell Note(10).text(2).
        let cells = ld(3, ld(10, ld(2, Array("Price".utf8)))) + ld(3, [0x08, 0x01]) + ld(3, ld(10, ld(2, Array("42 EUR".utf8))))
        let table = try gzip(Data(ld(2, ld(3, cells)))).map { String(format: "%02x", $0) }.joined()
        let sql = """
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER, Z_NAME TEXT);
            INSERT INTO Z_PRIMARYKEY VALUES (12, 'ICNote'), (15, 'ICFolder');
            CREATE TABLE Z_METADATA (Z_UUID TEXT);
            INSERT INTO Z_METADATA VALUES ('1A2B3C4D-0000-1111-2222-333344445555');
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, ZTITLE1 TEXT, ZTITLE2 TEXT,
              ZIDENTIFIER TEXT, ZMODIFICATIONDATE1 REAL, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER, ZMARKEDFORDELETION INTEGER,
              ZISPASSWORDPROTECTED INTEGER, ZTYPEUTI1 TEXT, ZALTTEXT TEXT, ZNOTE1 INTEGER,
              ZTYPEUTI TEXT, ZMERGEABLEDATA1 BLOB, ZNAME TEXT, ZACCOUNT4 INTEGER, ZACCOUNT7 INTEGER, ZISPINNED INTEGER);
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZNAME) VALUES (5, 14, 'iCloud');
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZIDENTIFIER, ZTYPEUTI, ZMERGEABLEDATA1)
              VALUES (21, 31, 'TABLE-1', 'com.apple.notes.table', X'\(table)');
            CREATE TABLE ZICNOTEDATA (ZNOTE INTEGER, ZDATA BLOB);
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTITLE2, ZFOLDERTYPE) VALUES (1, 15, 'Work', 0), (2, 15, 'Recently Deleted', 1);
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTITLE1, ZIDENTIFIER, ZMODIFICATIONDATE1, ZFOLDER, ZMARKEDFORDELETION, ZISPASSWORDPROTECTED)
              VALUES (10, 12, 'Hello world', 'UUID-10', 700000000, 1, 0, 0),
                     (11, 12, 'Trashed', 'UUID-11', 700000000, 2, 0, 0),
                     (12, 12, 'Gone', 'UUID-12', 700000000, 1, 1, 0),
                     (13, 12, 'Secret', 'UUID-13', 700000000, 1, 0, 1);
            UPDATE ZICCLOUDSYNCINGOBJECT SET ZACCOUNT7 = 5, ZISPINNED = 1 WHERE Z_PK = 10;
            INSERT INTO ZICNOTEDATA VALUES (10, X'\(blob)'), (13, X'deadbeef');
            INSERT INTO ZICCLOUDSYNCINGOBJECT (Z_PK, Z_ENT, ZTYPEUTI1, ZALTTEXT, ZNOTE1)
              VALUES (20, 30, 'com.apple.notes.inlinetextattachment.hashtag', '#ProjectX', 10);
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [db, sql]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)

        let reader = try NotesReader(path: db)
        XCTAssertEqual(try reader.storeUUID(), "1A2B3C4D-0000-1111-2222-333344445555")
        let stamps = try reader.stamps()
        XCTAssertEqual(Set(stamps.keys), [10, 13]) // trash folder and deleted notes excluded
        XCTAssertEqual(stamps[10]?.folder, "Work")
        XCTAssertEqual(stamps[10]?.account, "iCloud")
        XCTAssertEqual([stamps[10]?.pinned, stamps[13]?.pinned], [true, false])
        XCTAssertEqual(try reader.tables(), ["TABLE-1": ["Price", "42 EUR"]])
        XCTAssertEqual(try reader.inlineAltText()["TABLE-1"], "▦ Price · 42 EUR")
        XCTAssertEqual(try reader.hashtags()[10], ["projectx"])
        let raws = try reader.notes([10, 13]).sorted { $0.pk < $1.pk }
        XCTAssertEqual(raws.map(\.identifier), ["UUID-10", "UUID-13"])
        XCTAssertEqual(raws[0].data.flatMap(NoteDecoder.text), "Hello world\nsecond line")
        XCTAssertTrue(raws[1].locked)
    }
}
