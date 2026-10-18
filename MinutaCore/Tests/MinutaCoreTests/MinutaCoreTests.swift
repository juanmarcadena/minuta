import Foundation
import Testing
@testable import MinutaCore

/// Fixed zone so expected local times don't depend on the machine running the tests.
let utcMinus6 = TimeZone(secondsFromGMT: -6 * 3600)!

@Suite struct TranscriptNamingTests {
    let start = ISO8601DateFormatter().date(from: "2026-10-16T21:00:00Z")!  // 15:00 in Mexico City

    @Test func usesMexicoCityTime() {
        #expect(TranscriptNaming.fileName(start: start, title: "Weekly sync", timeZone: utcMinus6) == "2026-10-16 1500 - Weekly sync.md")
    }

    @Test func stripsBadCharacters() {
        #expect(TranscriptNaming.fileName(start: start, title: "Acme / Nova: revisión?", timeZone: utcMinus6) == "2026-10-16 1500 - Acme Nova revisión.md")
    }

    @Test func emptyTitleFallsBack() {
        #expect(TranscriptNaming.fileName(start: start, title: "  ", timeZone: utcMinus6) == "2026-10-16 1500 - Meeting.md")
    }

    @Test func addsCounterWhenTaken() {
        let folder = URL(filePath: "/tmp/t")
        let taken: Set<String> = ["/tmp/t/a.md", "/tmp/t/a (2).md"]
        let url = TranscriptNaming.uniqueURL(in: folder, fileName: "a.md") { taken.contains($0.path) }
        #expect(url.lastPathComponent == "a (3).md")
    }
}

@Suite struct MeetingPhaseTests {
    @Test func statusLines() {
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(MeetingPhase.idle.statusLine() == "Idle")
        #expect(MeetingPhase.recording(app: "Zoom", since: t0).statusLine(now: t0.addingTimeInterval(751)) == "Recording Zoom — 12:31")
        #expect(MeetingPhase.recording(app: "Zoom", since: t0).statusLine(now: t0.addingTimeInterval(3725)) == "Recording Zoom — 1:02:05")
        #expect(MeetingPhase.transcribing(pending: 1).statusLine() == "Transcribing 1 meeting")
    }
}

@Suite struct RecordingManifestTests {
    @Test func roundTripsAndAligns() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var m = RecordingManifest(startedAt: Date(timeIntervalSince1970: 1_000_000), app: "Zoom", bundleID: "us.zoom.xos")
        #expect(m.themOffsetFromMe == nil)
        m.me.firstSampleHostSeconds = 100.0
        m.them.firstSampleHostSeconds = 100.25
        try m.write(to: folder)
        let back = try RecordingManifest.read(from: folder)
        #expect(back == m)
        #expect(abs(back.themOffsetFromMe! - 0.25) < 1e-9)
    }
}

@Suite struct TranscriptTests {
    @Test func mergeInterleavesAndJoins() {
        let me = [Utterance(speaker: .me, start: 0, end: 2, text: "Hola"), Utterance(speaker: .me, start: 2.5, end: 4, text: "¿cómo estás?")]
        let them = [Utterance(speaker: .them(nil), start: 4.5, end: 6, text: "Bien, ¿y tú?")]
        let out = TranscriptMerger.merge(me: me, them: them, themOffset: 0.5)
        #expect(out.count == 2)
        #expect(out[0].text == "Hola ¿cómo estás?")
        #expect(out[1].speaker == .them(nil))
        #expect(out[1].start == 5.0)
    }

    @Test func phantoms() {
        #expect(PhantomFilter.isPhantom("Продолжение следует... Thank you."))
        #expect(PhantomFilter.isPhantom(" Gracias por ver el video "))
        #expect(!PhantomFilter.isPhantom("Thank you for the update on the pricing."))
        #expect(PhantomFilter.collapseRepeats("en este momento momento momento momento lo transfiero") == "en este momento momento lo transfiero")
    }

    @Test func speakersNumberedByFirstAppearance() {
        let us = [Utterance(speaker: .them(nil), start: 0, end: 3, text: "a"),
                  Utterance(speaker: .them(nil), start: 4, end: 6, text: "b"),
                  Utterance(speaker: .them(nil), start: 7, end: 9, text: "c")]
        let turns = [SpeakerAssigner.Turn(start: 0, end: 3.5, speaker: 7),
                     SpeakerAssigner.Turn(start: 3.5, end: 6.5, speaker: 2),
                     SpeakerAssigner.Turn(start: 6.5, end: 10, speaker: 7)]
        #expect(SpeakerAssigner.assign(us, turns: turns).map(\.speaker) == [.them(1), .them(2), .them(1)])
    }

    @Test func chunksStayShort() {
        typealias S = ChunkPlanner.Span
        let speech = [S(start: 0, end: 4), S(start: 5, end: 9), S(start: 10, end: 14), S(start: 20, end: 52)]
        let chunks = ChunkPlanner.plan(speech: speech, maxLength: 15, pad: 0, duration: 60)
        #expect(chunks.first == S(start: 0, end: 14))
        #expect(chunks.allSatisfy { $0.length <= 15.0001 })
        #expect(chunks.count == 4)  // 0–14, then 32 s split into three
    }

    @Test func markdown() {
        let start = ISO8601DateFormatter().date(from: "2026-10-16T21:00:00Z")!
        let md = TranscriptMarkdown.render(
            [Utterance(speaker: .me, start: 4, end: 6, text: "Hola", language: "es"),
             Utterance(speaker: .them(1), start: 11, end: 12, text: "Hi", language: "en")],
            meta: .init(title: "Weekly: Product", startedAt: start, duration: 47 * 60, app: "Zoom"), timeZone: utcMinus6)
        #expect(md.contains("date: 2026-10-16T15:00:00-06:00"))
        #expect(md.contains("title: \"Weekly: Product\""))
        #expect(md.contains("languages: [en, es]"))
        #expect(md.contains("# Weekly: Product — 16 Oct 2026, 15:00"))
        #expect(md.contains("**[00:00:11] Them 1:** Hi"))
    }
}

@Suite struct LanguageRunTests {
    @Test func joinsSameLanguageNeighbours() {
        typealias S = ChunkPlanner.Span
        let runs = LanguageRuns.join([(S(start: 0, end: 10), "es"), (S(start: 11, end: 20), "es"), (S(start: 21, end: 30), "en"), (S(start: 31, end: 40), "es")])
        #expect(runs.map(\.language) == ["es", "en", "es"])
        #expect(runs[0].span == S(start: 0, end: 20))
    }

    @Test func collapsesLongRepeatedPhrase() {
        let t = "Y el mundo que está pasando en este video Y el mundo que está pasando en este video Y el mundo que está pasando en este video es el centro"
        #expect(PhantomFilter.collapseRepeats(t) == "Y el mundo que está pasando en este video Y el mundo que está pasando en este video es el centro")
    }
}

@Suite struct WordSplitTests {
    @Test func splitsUtteranceAtSpeakerChange() {
        typealias W = Utterance.Word
        let u = Utterance(speaker: .them(nil), start: 0, end: 6, text: "Hi everyone. No problem.",
                          words: [W(text: " Hi", start: 0, end: 0.5), W(text: " everyone.", start: 0.5, end: 1.5),
                                  W(text: " No", start: 3, end: 3.4), W(text: " problem.", start: 3.4, end: 4)])
        let turns = [SpeakerAssigner.Turn(start: 0, end: 2, speaker: 5), SpeakerAssigner.Turn(start: 2.8, end: 4.5, speaker: 9)]
        let out = SpeakerAssigner.assign([u], turns: turns)
        #expect(out.map(\.text) == ["Hi everyone.", "No problem."])
        #expect(out.map(\.speaker) == [.them(1), .them(2)])
    }
}

@Suite struct BlipTests {
    @Test func shortBlipJoinsNextGroup() {
        typealias W = Utterance.Word
        let u = Utterance(speaker: .them(nil), start: 30, end: 36, text: "That works for me. Let's add a clause.",
                          words: [W(text: " That", start: 31.0, end: 31.3), W(text: " works", start: 31.3, end: 31.7),
                                  W(text: " for", start: 32.1, end: 32.3), W(text: " me.", start: 32.3, end: 32.6),
                                  W(text: " Let's", start: 33, end: 33.3), W(text: " add", start: 33.3, end: 33.6)])
        let turns = [SpeakerAssigner.Turn(start: 22.8, end: 30.9, speaker: 1), SpeakerAssigner.Turn(start: 31.0, end: 32.0, speaker: 1),
                     SpeakerAssigner.Turn(start: 32.0, end: 37.8, speaker: 2)]
        let out = SpeakerAssigner.assign([u], turns: turns)
        #expect(out.count == 1)
        #expect(out[0].text == "That works for me. Let's add")
    }
}

@Suite struct MeetingDetectorTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    let noEvent: (String) -> Bool = { _ in false }

    @Test func startsWhenMicOpensAndStopsAfterQuiet() {
        var d = MeetingDetector()
        #expect(d.update(now: at(0), micApps: ["zoom"], hasEvent: noEvent) == .start(appID: "zoom"))
        #expect(d.update(now: at(19), micApps: ["zoom"], hasEvent: noEvent) == nil)
        #expect(d.update(now: at(20), micApps: ["zoom"], hasEvent: noEvent) == nil)
        #expect(d.state == .recording(appID: "zoom", since: at(0), automatic: true, quietSince: nil))
        #expect(d.update(now: at(600), micApps: [], hasEvent: noEvent) == nil)
        #expect(d.update(now: at(620), micApps: ["zoom"], hasEvent: noEvent) == nil)  // back before 30 s: keeps going
        #expect(d.update(now: at(700), micApps: [], hasEvent: noEvent) == nil)
        #expect(d.update(now: at(730), micApps: [], hasEvent: noEvent) == .stop(discard: false))
        #expect(d.state == .idle)
    }

    @Test func shortMicUseIsThrownAwayAtOnce() {
        var d = MeetingDetector()
        #expect(d.update(now: at(0), micApps: ["safari"], hasEvent: noEvent) == .start(appID: "safari"))
        #expect(d.update(now: at(8), micApps: [], hasEvent: noEvent) == .stop(discard: true))
        #expect(d.state == .idle)
    }

    @Test func shortAutomaticRecordingIsDiscardedUnlessOnCalendar() {
        var d = MeetingDetector()
        _ = d.update(now: at(0), micApps: ["whatsapp"], hasEvent: noEvent)
        _ = d.update(now: at(25), micApps: ["whatsapp"], hasEvent: noEvent)
        _ = d.update(now: at(40), micApps: [], hasEvent: noEvent)
        #expect(d.update(now: at(70), micApps: [], hasEvent: noEvent) == .stop(discard: true))

        var e = MeetingDetector()
        _ = e.update(now: at(0), micApps: ["safari"], hasEvent: { _ in true })
        _ = e.update(now: at(25), micApps: ["safari"], hasEvent: { _ in true })
        _ = e.update(now: at(40), micApps: [], hasEvent: { _ in true })
        #expect(e.update(now: at(70), micApps: [], hasEvent: { _ in true }) == .stop(discard: false))
    }

    @Test func manualStopSuppressesUntilMicReleased() {
        var d = MeetingDetector()
        _ = d.update(now: at(0), micApps: ["zoom"], hasEvent: noEvent)
        _ = d.update(now: at(20), micApps: ["zoom"], hasEvent: noEvent)
        d.manualStop(micApps: ["zoom"])
        #expect(d.update(now: at(200), micApps: ["zoom"], hasEvent: noEvent) == nil)
        #expect(d.state == .suppressed(appID: "zoom"))
        _ = d.update(now: at(300), micApps: [], hasEvent: noEvent)
        #expect(d.state == .idle)
    }

    @Test func manualWithoutCallAppOnlyStopsByHand() {
        var d = MeetingDetector()
        d.manualStart(appID: nil, now: at(0))
        #expect(d.update(now: at(500), micApps: [], hasEvent: noEvent) == nil)
        #expect(d.state.isRecordingForTests)
    }

    @Test func helperBundleIDsMapToTheirApp() {
        let all = Set(CallApp.all.map(\.id))
        #expect(CallApp.owner(of: "com.apple.WebKit.GPU", enabled: all)?.id == "safari")
        #expect(CallApp.owner(of: "com.google.Chrome.helper", enabled: all)?.id == "chrome")
        #expect(CallApp.owner(of: "us.zoom.xos", enabled: all)?.id == "zoom")
        #expect(CallApp.owner(of: "com.spotify.client", enabled: all) == nil)
        #expect(CallApp.owner(of: "us.zoom.xos", enabled: ["teams"]) == nil)
        #expect(CallApp.app(id: "safari")!.displayName(meetingLink: "https://meet.google.com/abc-defg-hij") == "Google Meet")
    }
}

extension MeetingDetector.State {
    var isRecordingForTests: Bool {
        if case .recording = self { return true }
        return false
    }
}

@Suite struct ArtifactAndSpeakerTests {
    @Test func soundLabelsAreNotSpeech() {
        #expect(PhantomFilter.isPhantom("*Gunas* *Gunas*"))
        #expect(PhantomFilter.isPhantom("[Music]"))
        #expect(PhantomFilter.stripSoundLabels("Eh, sí, me interesaría. *Gunas*") == "Eh, sí, me interesaría.")
    }

    @Test func minorSpeakerMergesIntoMain() {
        typealias T = SpeakerAssigner.Turn
        let turns = [T(start: 0, end: 60, speaker: 0), T(start: 61, end: 65, speaker: 1), T(start: 66, end: 90, speaker: 0)]
        #expect(Set(SpeakerAssigner.mergeMinorSpeakers(turns).map(\.speaker)) == [0])
        let real = [T(start: 0, end: 40, speaker: 0), T(start: 41, end: 80, speaker: 1)]
        #expect(Set(SpeakerAssigner.mergeMinorSpeakers(real).map(\.speaker)) == [0, 1])
    }
}

@Suite struct DisplayTitleTests {
    @Test func titles() {
        var m = RecordingManifest(startedAt: .now, app: "Safari")
        #expect(m.displayTitle == "Safari call")
        m.app = "Google Meet"
        #expect(m.displayTitle == "Google Meet")
        m.app = "Manual"
        #expect(m.displayTitle == "Recording")
        m.title = "Weekly sync"
        #expect(m.displayTitle == "Weekly sync")
    }

    @Test func silentThem() {
        var m = RecordingManifest(startedAt: .now, app: "Zoom")
        #expect(!m.themLooksSilent(duration: 300))  // unknown peak: no warning
        m.them.peak = 0.0001
        #expect(m.themLooksSilent(duration: 300))
        #expect(!m.themLooksSilent(duration: 10))
        m.them.peak = 0.3
        #expect(!m.themLooksSilent(duration: 300))
    }
}

@Suite struct TranscriptDocumentTests {
    @Test func roundTripsWhatTheWriterProduces() {
        let start = ISO8601DateFormatter().date(from: "2026-10-16T21:00:00Z")!
        let md = TranscriptMarkdown.render(
            [Utterance(speaker: .me, start: 4, end: 6, text: "Hola, ¿cómo estás?", language: "es"),
             Utterance(speaker: .them(2), start: 3725, end: 3730, text: "Hi: all good", language: "en")],
            meta: .init(title: "Weekly: Product", startedAt: start, duration: 47 * 60, app: "Zoom",
                        attendees: ["Dana Pérez", "Ana, Ltd"], meetingLink: "https://zoom.us/j/123"), timeZone: utcMinus6)
        let doc = TranscriptDocument.parse(md, url: URL(filePath: "/tmp/x.md"))
        #expect(doc.title == "Weekly: Product")
        #expect(doc.date == start)
        #expect(doc.durationMinutes == 47)
        #expect(doc.app == "Zoom")
        #expect(doc.attendees == ["Dana Pérez", "Ana, Ltd"])
        #expect(doc.meetingLink == "https://zoom.us/j/123")
        #expect(doc.lines.map(\.speaker) == ["Me", "Them 2"])
        #expect(doc.lines[1].time == 3725)
        #expect(doc.lines[1].text == "Hi: all good")
        #expect(doc.speakers == ["Me", "Them 2"])
        #expect(doc.searchableText.contains("como estas"))
        #expect(doc.plainText.contains("Them 2 (1:02:05): Hi: all good"))
    }

    @Test func toleratesFilesWithoutFrontMatter() {
        let doc = TranscriptDocument.parse("# Notes\n\nhello", url: URL(filePath: "/tmp/2026-10-16 1500 - Call.md"))
        #expect(doc.title == "2026-10-16 1500 - Call")
        #expect(doc.lines.isEmpty)
    }
}

@Suite struct TimelineGapTests {
    @Test func fillsOnlyRealGaps() {
        #expect(TimelineGap.silence(elapsed: 10.1, written: 10.0) == 0)         // normal jitter
        #expect(abs(TimelineGap.silence(elapsed: 14.0, written: 10.0) - 4.0) < 1e-9)  // 4 s device switch
        #expect(TimelineGap.silence(elapsed: 9.0, written: 10.0) == 0)          // never negative
    }
}

@Suite struct TranscriptQueryTests {
    func doc(_ name: String, _ iso: String, attendees: [String] = [], app: String = "Zoom", lines: [(Double, String, String)]) -> TranscriptDocument {
        TranscriptDocument(url: URL(filePath: "/t/\(name).md"), title: name, date: ISO8601DateFormatter().date(from: iso),
                           durationMinutes: 30, app: app, languages: [], attendees: attendees, meetingLink: nil,
                           lines: lines.enumerated().map { .init(id: $0.offset, time: $0.element.0, speaker: $0.element.1, text: $0.element.2) })
    }

    var q: TranscriptQuery {
        TranscriptQuery(documents: [
            doc("2026-10-14 1000 - Pricing review", "2026-10-14T16:00:00Z", attendees: ["Dana Pérez"], lines: [
                (0, "Me", "Hola, empezamos"), (10, "Them", "El precio por minuto baja a doce centavos"), (20, "Me", "Perfecto")]),
            doc("2026-10-16 1500 - Weekly sync", "2026-10-16T21:00:00Z", app: "Google Meet", lines: [
                (5, "Them 1", "Pricing is final"), (65, "Me", "Great, send the proposal")]),
        ], timeZone: utcMinus6)
    }

    @Test func listsNewestFirstAndFilters() {
        #expect(q.listMeetings().items.map(\.title) == ["2026-10-16 1500 - Weekly sync", "2026-10-14 1000 - Pricing review"])
        #expect(q.listMeetings(query: "perez").items.map(\.title) == ["2026-10-14 1000 - Pricing review"])
        #expect(q.listMeetings(app: "meet").total == 1)
        #expect(q.listMeetings(from: q.parseDate("2026-10-15")).total == 1)
        #expect(q.listMeetings(to: q.parseDate("2026-10-14", endOfDay: true)).total == 1)
        let page = q.listMeetings(limit: 1)
        #expect(page.next_cursor == "1")
        #expect(q.listMeetings(limit: 1, cursor: page.next_cursor).items.first?.title == "2026-10-14 1000 - Pricing review")
    }

    @Test func searchIgnoresAccentsAndGivesContext() {
        let hits = q.search("PRECIO minuto")
        #expect(hits.total == 1)
        #expect(hits.items[0].time == "0:10")
        #expect(hits.items[0].context_before == "Me: Hola, empezamos")
        #expect(hits.items[0].context_after == "Me: Perfecto")
        #expect(q.search("pricing", speaker: "them 1").total == 1)
        #expect(q.search("   ").total == 0)
    }

    @Test func transcriptRangesAndTruncation() {
        let d = q.document(id: "2026-10-16 1500 - Weekly sync")!
        #expect(q.transcript(d).text == "[0:05] Them 1: Pricing is final\n[1:05] Me: Great, send the proposal\n")
        #expect(q.transcript(d, start: 60).text == "[1:05] Me: Great, send the proposal\n")
        let cut = q.transcript(d, maxCharacters: 40)
        #expect(cut.truncated && cut.next_start_time == "1:05")
        #expect(q.transcript(d, detailed: true).text.hasPrefix("# 2026-10-16 1500 - Weekly sync\nFri 2026-10-16 15:00"))
        #expect(TranscriptQuery.parseClock("1:02:05") == 3725)
        #expect(q.document(id: "nope") == nil)
    }
}
