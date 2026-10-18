import Foundation

/// Who said something. `them(n)` is the n-th other person found by diarization (nil when unknown).
public enum Speaker: Hashable, Codable, Sendable {
    case me
    case them(Int?)
}

/// One stretch of speech by one speaker, in seconds on the meeting timeline (the `me` track's clock).
public struct Utterance: Hashable, Codable, Sendable {
    public struct Word: Hashable, Codable, Sendable {
        public var text: String
        public var start: Double
        public var end: Double
        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public var speaker: Speaker
    public var start: Double
    public var end: Double
    public var text: String
    /// Whisper language code ("es", "en").
    public var language: String?
    /// Word timings, when available; used to split an utterance where the speaker changes.
    public var words: [Word]?

    public init(speaker: Speaker, start: Double, end: Double, text: String, language: String? = nil, words: [Word]? = nil) {
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.language = language
        self.words = words
    }
}

public enum TranscriptMerger {
    /// Interleaves both tracks by start time and joins consecutive pieces from the same speaker
    /// when the pause between them is short.
    public static func merge(me: [Utterance], them: [Utterance], themOffset: Double = 0, joinGap: Double = 2.0) -> [Utterance] {
        let shifted = them.map { u in
            var u = u
            u.start += themOffset
            u.end += themOffset
            u.words = u.words?.map { Utterance.Word(text: $0.text, start: $0.start + themOffset, end: $0.end + themOffset) }
            return u
        }
        let sorted = (me + shifted)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var out: [Utterance] = []
        for u in sorted {
            if var last = out.last, last.speaker == u.speaker, u.start - last.end <= joinGap {
                last.text = last.text + " " + u.text.trimmingCharacters(in: .whitespaces)
                last.end = max(last.end, u.end)
                if let w = u.words { last.words = (last.words ?? []) + w }
                out[out.count - 1] = last
            } else {
                var u = u
                u.text = u.text.trimmingCharacters(in: .whitespaces)
                out.append(u)
            }
        }
        return out
    }
}

/// Phrases Whisper invents over silence or music, and runaway repetition.
public enum PhantomFilter {
    static let phantoms: [String] = [
        "thank you", "thank you.", "thanks for watching", "thanks for watching!", "thank you for watching",
        "gracias", "gracias.", "gracias por ver el video", "gracias por ver", "subtítulos realizados por la comunidad de amara.org",
        "subtitulado por la comunidad de amara.org", "suscríbete", "продолжение следует...", "продолжение следует",
        "you", "bye.", "bye", "...", "music", "[music]", "(music)", "[música]", "♪",
    ]

    /// True when the whole utterance is a known phantom phrase (or a few of them),
    /// or only sound labels like "*Gunas*", "[Music]", "(risas)".
    public static func isPhantom(_ text: String) -> Bool {
        let t = normalized(stripSoundLabels(text))
        if t.isEmpty { return true }
        if phantoms.contains(t) { return true }
        // "Продолжение следует... Thank you." → split into sentences, all phantom?
        let parts = t.split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return !parts.isEmpty && parts.allSatisfy { phantoms.contains($0) || phantoms.contains($0 + ".") }
    }

    /// Removes `*…*`, `[…]` and `(…)` spans: Whisper's labels for noises, not speech.
    public static func stripSoundLabels(_ text: String) -> String {
        text.replacingOccurrences(of: #"\*[^*]{0,40}\*|\[[^\]]{0,40}\]|\([^)]{0,40}\)"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Collapses a word or short phrase repeated many times in a row ("momento momento momento…").
    public static func collapseRepeats(_ text: String, maxRepeats: Int = 2) -> String {
        var words = text.split(separator: " ").map(String.init)
        for n in 1...12 {  // phrase length in words
            var i = 0
            while i + n <= words.count {
                let phrase = words[i..<i + n].map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
                var j = i + n
                var count = 1
                while j + n <= words.count,
                      words[j..<j + n].map({ $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }) == phrase {
                    count += 1
                    j += n
                }
                if count > maxRepeats {
                    words.removeSubrange((i + n * maxRepeats)..<j)
                }
                i += 1
            }
        }
        return words.joined(separator: " ")
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum SpeakerAssigner {
    /// Diarization sometimes invents a second "person" from a few seconds of one voice.
    /// A speaker with under `minShare` of the speech and under `minSeconds` is merged into the main one.
    public static func mergeMinorSpeakers(_ turns: [Turn], minShare: Double = 0.15, minSeconds: Double = 20) -> [Turn] {
        var total: [Int: Double] = [:]
        for t in turns { total[t.speaker, default: 0] += t.end - t.start }
        let all = total.values.reduce(0, +)
        guard let main = total.max(by: { $0.value < $1.value })?.key, all > 0 else { return turns }
        let minor = Set(total.filter { $0.value / all < minShare && $0.value < minSeconds }.keys)
        return turns.map { t in minor.contains(t.speaker) ? Turn(start: t.start, end: t.end, speaker: main) : t }
    }

    public struct Turn: Sendable {
        public var start: Double
        public var end: Double
        public var speaker: Int
        public init(start: Double, end: Double, speaker: Int) {
            self.start = start
            self.end = end
            self.speaker = speaker
        }
    }

    /// Gives each piece of speech the diarized speaker it overlaps most. Utterances with word timings
    /// are split where the speaker changes mid-utterance. Speakers are renumbered 1, 2, … in order of
    /// first appearance so the transcript reads "Them 1" before "Them 2".
    public static func assign(_ utterances: [Utterance], turns: [Turn]) -> [Utterance] {
        var order: [Int: Int] = [:]
        func label(_ raw: Int?) -> Speaker {
            guard let raw else { return .them(nil) }
            let n = order[raw] ?? (order.count + 1)
            order[raw] = n
            return .them(n)
        }
        var out: [Utterance] = []
        for u in utterances {
            guard let words = u.words, !words.isEmpty else {
                var u = u
                u.speaker = label(best(u.start, u.end, turns))
                out.append(u)
                continue
            }
            // Speaker per word, then group consecutive words with the same speaker.
            var groups: [(raw: Int?, words: [Utterance.Word])] = []
            for w in words {
                let raw = best(w.start, w.end, turns) ?? groups.last?.raw
                if let last = groups.last, last.raw == raw {
                    groups[groups.count - 1].words.append(w)
                } else {
                    groups.append((raw, [w]))
                }
            }
            // A blip of one or two words is diarization noise: give it to the following group.
            var smoothed: [(raw: Int?, words: [Utterance.Word])] = []
            var carry: [Utterance.Word] = []
            for (i, g) in groups.enumerated() {
                let isBlip = g.words.count <= 2 && (g.words.last!.end - g.words.first!.start) < 0.8
                if isBlip, groups.count > 1, i < groups.count - 1 {
                    carry += g.words
                    continue
                }
                if isBlip, groups.count > 1, i == groups.count - 1, !smoothed.isEmpty {
                    smoothed[smoothed.count - 1].words += carry + g.words
                    carry = []
                    continue
                }
                smoothed.append((g.raw, carry + g.words))
                carry = []
            }
            if !carry.isEmpty { smoothed.append((groups.last?.raw, carry)) }
            for g in smoothed {
                guard let first = g.words.first, let last = g.words.last else { continue }
                out.append(Utterance(speaker: label(g.raw), start: first.start, end: last.end,
                                     text: g.words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                                     language: u.language, words: g.words))
            }
        }
        return out
    }

    /// The turn overlapping [start, end] most, or the nearest one for a word that falls in a gap.
    static func best(_ start: Double, _ end: Double, _ turns: [Turn]) -> Int? {
        var best: (speaker: Int, overlap: Double)?
        for t in turns {
            let o = min(end, t.end) - max(start, t.start)
            if o > 0, o > (best?.overlap ?? 0) { best = (t.speaker, o) }
        }
        if let best { return best.speaker }
        let mid = (start + end) / 2
        return turns.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }.flatMap {
            min(abs($0.start - mid), abs($0.end - mid)) < 1.0 ? $0.speaker : nil
        }
    }
}

/// Splits speech into chunks short enough that one chunk rarely holds two languages,
/// so language can be detected per chunk (otherwise Whisper translates the minority language).
public enum ChunkPlanner {
    public struct Span: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
        public var length: Double { end - start }
    }

    /// - Parameters:
    ///   - speech: speech regions from VAD, in seconds, sorted.
    ///   - maxLength: longest chunk; regions longer than this are cut into equal parts.
    ///   - pad: silence kept around each chunk so words at the edges are not clipped.
    public static func plan(speech: [Span], maxLength: Double = 15, pad: Double = 0.2, duration: Double) -> [Span] {
        var pieces: [Span] = []
        for r in speech where r.length > 0.15 {
            if r.length <= maxLength {
                pieces.append(r)
            } else {
                let n = Int((r.length / maxLength).rounded(.up))
                let step = r.length / Double(n)
                for k in 0..<n {
                    pieces.append(Span(start: r.start + Double(k) * step, end: r.start + Double(k + 1) * step))
                }
            }
        }
        var chunks: [Span] = []
        for p in pieces {
            if var last = chunks.last, p.end - last.start <= maxLength {
                last.end = p.end
                chunks[chunks.count - 1] = last
            } else {
                chunks.append(p)
            }
        }
        return chunks.map { Span(start: max(0, $0.start - pad), end: min(duration, $0.end + pad)) }
    }
}

/// Joins neighbouring chunks that got the same language into one run, so each run is transcribed
/// in one go (no sentences cut at chunk edges) while a language switch still starts a new run.
public enum LanguageRuns {
    public struct Run: Equatable, Sendable {
        public var span: ChunkPlanner.Span
        public var language: String
        public init(span: ChunkPlanner.Span, language: String) {
            self.span = span
            self.language = language
        }
    }

    public static func join(_ chunks: [(span: ChunkPlanner.Span, language: String)]) -> [Run] {
        var runs: [Run] = []
        for c in chunks {
            if var last = runs.last, last.language == c.language {
                last.span.end = max(last.span.end, c.span.end)
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(span: c.span, language: c.language))
            }
        }
        return runs
    }
}
