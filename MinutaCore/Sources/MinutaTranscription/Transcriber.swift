import Foundation
import MinutaCore
import SpeakerKit
import WhisperKit

/// Turns a recording folder (me.caf, them.caf, meeting.json) into utterances.
///
/// Rules from the engine comparison (README, "Why WhisperKit"):
/// - language is detected per short chunk, never once per file, or Whisper translates
///   the minority language into the majority one;
/// - only speech found by VAD is transcribed, and phantom phrases are dropped;
/// - a vocabulary prompt (names, companies) fixes spelling of work terms.
public actor Transcriber {
    public static let whisperModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let sampleRate = 16_000.0
    /// Set MINUTA_DEBUG=1 to log every chunk's language and raw text.
    static let debug = ProcessInfo.processInfo.environment["MINUTA_DEBUG"] == "1"

    public struct Options: Sendable {
        /// Force one language ("es", "en"); nil = detect per chunk.
        public var language: String?
        /// Languages detection may choose from. Restricting it stops rare mis-detections (e.g. Russian on noise).
        public var allowedLanguages: [String]
        /// Names and terms to spell right; becomes Whisper's prompt.
        public var vocabulary: [String]
        /// Split the other side into Them 1, Them 2…
        public var diarizeThem: Bool

        public init(language: String? = nil, allowedLanguages: [String] = ["es", "en"], vocabulary: [String] = [], diarizeThem: Bool = true) {
            self.language = language
            self.allowedLanguages = allowedLanguages
            self.vocabulary = vocabulary
            self.diarizeThem = diarizeThem
        }
    }

    public struct Result: Sendable {
        public var utterances: [Utterance]
        public var manifest: RecordingManifest
        public var duration: Double
    }

    private let modelsBase: URL
    private var whisper: WhisperKit?
    private let progress: @Sendable (String) -> Void

    /// - Parameter modelsBase: where models are downloaded and cached (never inside iCloud Documents).
    public init(modelsBase: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.modelsBase = modelsBase
        self.progress = progress
    }

    // MARK: Whole recording

    public func transcribe(folder: URL, options: Options) async throws -> Result {
        let manifest = try RecordingManifest.read(from: folder)
        let meURL = folder.appending(path: manifest.me.file)
        let themURL = folder.appending(path: manifest.them.file)

        progress("Transcribing your side…")
        let (me, meDuration) = try await transcribeTrack(meURL, speaker: .me, options: options)
        progress("Transcribing the other side…")
        var (them, themDuration) = try await transcribeTrack(themURL, speaker: .them(nil), options: options)

        if options.diarizeThem, !them.isEmpty {
            progress("Separating speakers…")
            let turns = SpeakerAssigner.mergeMinorSpeakers(try await diarize(themURL))
            if Self.debug {
                progress("turns: " + turns.map { String(format: "%d@%.1f-%.1f", $0.speaker, $0.start, $0.end) }.joined(separator: " "))
            }
            // Only label people when there is more than one; a 1:1 call stays "Them".
            if Set(turns.map(\.speaker)).count > 1 {
                them = SpeakerAssigner.assign(them, turns: turns).compactMap {
                    var u = $0
                    u.text = PhantomFilter.collapseRepeats(PhantomFilter.stripSoundLabels(u.text))
                    return PhantomFilter.isPhantom(u.text) ? nil : u
                }
            }
        }

        let utterances = TranscriptMerger.merge(me: me, them: them, themOffset: manifest.themOffsetFromMe ?? 0)
        return Result(utterances: utterances, manifest: manifest, duration: max(meDuration, themDuration))
    }

    // MARK: One track

    public func transcribeTrack(_ url: URL, speaker: Speaker, options: Options) async throws -> (utterances: [Utterance], duration: Double) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], 0) }
        let whisper = try await loadWhisper()
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let duration = Double(audio.count) / Self.sampleRate
        guard !audio.isEmpty else { return ([], 0) }

        let speech = EnergyVAD().calculateActiveChunks(in: audio).map {
            ChunkPlanner.Span(start: Double($0.startIndex) / Self.sampleRate, end: Double($0.endIndex) / Self.sampleRate)
        }
        let chunks = ChunkPlanner.plan(speech: speech, duration: duration)
        // WhisperKit 1.1.1: a prompt plus word timestamps collapses word times and can drop the
        // first sentence, so the track that needs words (Them, for diarization) gets no prompt.
        let wantsWords = speaker != .me && options.diarizeThem
        let prompt = wantsWords ? nil : promptTokens(options.vocabulary, whisper: whisper)

        // 1. Language per short chunk (or the forced one).
        var labelled: [(span: ChunkPlanner.Span, language: String)] = []
        for chunk in chunks {
            let samples = Self.slice(audio, chunk)
            guard samples.count > Int(0.3 * Self.sampleRate) else { continue }
            let language: String
            if let forced = options.language {
                language = forced
            } else {
                language = try await detectLanguage(samples, allowed: options.allowedLanguages, whisper: whisper)
            }
            labelled.append((chunk, language))
        }

        // 2. Transcribe each same-language run in one pass with the language forced.
        var out: [Utterance] = []
        for run in LanguageRuns.join(labelled) {
            let samples = Self.slice(audio, run.span)
            let decode = DecodingOptions(
                task: .transcribe,
                language: run.language,
                usePrefillPrompt: true,
                detectLanguage: false,
                skipSpecialTokens: true,
                wordTimestamps: wantsWords,  // words let diarization split mixed segments
                promptTokens: prompt,
                chunkingStrategy: .vad
            )
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: decode)
            if Self.debug {
                let raw = results.flatMap(\.segments).map { String(format: "[%.1f-%.1f] %@", $0.start, $0.end, Self.clean($0.text)) }.joined(separator: " | ")
                progress(String(format: "run %.1f–%.1f %@: %@", run.span.start, run.span.end, run.language, raw))
            }
            if Self.debug {
                for seg in results.flatMap(\.segments) {
                    let ws = (seg.words ?? []).prefix(4).map { String(format: "%@@%.2f-%.2f", $0.word, $0.start, $0.end) }.joined(separator: " ")
                    progress(String(format: "  seg %.2f-%.2f words: %@ …", seg.start, seg.end, ws))
                }
            }
            for seg in results.flatMap(\.segments) {
                let text = PhantomFilter.collapseRepeats(PhantomFilter.stripSoundLabels(Self.clean(seg.text)))
                guard !PhantomFilter.isPhantom(text) else { continue }
                let offset = run.span.start
                let words = seg.words?.map {
                    Utterance.Word(text: Self.clean($0.word).isEmpty ? "" : $0.word, start: offset + Double($0.start), end: offset + Double($0.end))
                }.filter { !$0.text.isEmpty }
                // WhisperKit occasionally stamps a final segment past the end of the audio.
                out.append(Utterance(speaker: speaker,
                                     start: min(offset + Double(seg.start), run.span.end),
                                     end: min(offset + Double(seg.end), run.span.end),
                                     text: text,
                                     language: run.language,
                                     words: words))
            }
        }
        return (out, duration)
    }

    // MARK: Pieces

    func detectLanguage(_ samples: [Float], allowed: [String], whisper: WhisperKit) async throws -> String {
        let (detected, probs) = try await whisper.detectLangauge(audioArray: samples)
        guard !allowed.isEmpty else { return detected }
        if allowed.contains(detected) { return detected }
        return allowed.max { (probs[$0] ?? -.infinity) < (probs[$1] ?? -.infinity) } ?? allowed[0]
    }

    func promptTokens(_ vocabulary: [String], whisper: WhisperKit) -> [Int]? {
        guard !vocabulary.isEmpty, let tokenizer = whisper.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: " " + vocabulary.joined(separator: ", "))
            .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }

    func diarize(_ url: URL) async throws -> [SpeakerAssigner.Turn] {
        let config = PyannoteConfig(
            modelDownloadConfig: ModelDownloadConfig(downloadBase: modelsBase.path, modelRepo: "argmaxinc/speakerkit-coreml"),
            download: true, load: true, verbose: false)
        let kit = try await SpeakerKit(config)
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let result = try await kit.diarize(audioArray: audio, options: PyannoteDiarizationOptions())
        await kit.unloadModels()
        return result.segments.compactMap { s in
            s.speaker.speakerId.map { SpeakerAssigner.Turn(start: Double(s.startTime), end: Double(s.endTime), speaker: $0) }
        }
    }

    func loadWhisper() async throws -> WhisperKit {
        if let whisper { return whisper }
        progress("Loading speech model…")
        let config = WhisperKitConfig(
            model: Self.whisperModel,
            downloadBase: modelsBase,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        let kit = try await WhisperKit(config)
        whisper = kit
        return kit
    }

    /// Frees the model's memory between meetings.
    public func unload() async {
        await whisper?.unloadModels()
        whisper = nil
    }

    static func slice(_ audio: [Float], _ span: ChunkPlanner.Span) -> [Float] {
        let lo = max(0, Int(span.start * sampleRate)), hi = min(audio.count, Int(span.end * sampleRate))
        return hi > lo ? Array(audio[lo..<hi]) : []
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
