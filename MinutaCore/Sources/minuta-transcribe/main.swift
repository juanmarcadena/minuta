// Dev tool: transcribe a Minuta recording folder and print (or save) the Markdown.
// usage: minuta-transcribe <recording-folder> [--language es|en] [--no-diarize] [--vocab "A,B"] [--out file.md]
import Foundation
import MinutaCore
import MinutaTranscription

let args = Array(CommandLine.arguments.dropFirst(2))
guard let folderPath = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write("usage: minuta-transcribe <recording-folder> [--language es|en] [--no-diarize] [--vocab \"A,B\"] [--out file.md]\n".data(using: .utf8)!)
    exit(2)
}
@MainActor func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

var options = Transcriber.Options()
options.language = value("--language")
options.diarizeThem = !args.contains("--no-diarize")
options.vocabulary = value("--vocab")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []

let modelsBase = URL.applicationSupportDirectory.appending(path: "Minuta/Models", directoryHint: .isDirectory)
let transcriber = Transcriber(modelsBase: modelsBase) { FileHandle.standardError.write("\($0)\n".data(using: .utf8)!) }

let started = Date()
let result = try await transcriber.transcribe(folder: URL(filePath: folderPath), options: options)
let md = TranscriptMarkdown.render(result.utterances, meta: .init(
    title: result.manifest.app, startedAt: result.manifest.startedAt, duration: result.duration, app: result.manifest.app))
if let out = value("--out") {
    try md.write(toFile: out, atomically: true, encoding: .utf8)
} else {
    print(md)
}
FileHandle.standardError.write(String(format: "done in %.1f s for %.1f s of audio\n", Date().timeIntervalSince(started), result.duration).data(using: .utf8)!)
