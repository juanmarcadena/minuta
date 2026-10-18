import AppKit
import MinutaCore
import SwiftUI

/// The transcript viewer: standard split view (sidebar of meetings, detail with the conversation),
/// so it picks up the system's Liquid Glass sidebar and toolbar without custom backgrounds.
struct TranscriptsWindow: View {
    let model: AppModel
    @Bindable var library: TranscriptLibrary
    @State private var query = ""

    var body: some View {
        let results = library.filtered(query)
        NavigationSplitView {
            TranscriptSidebar(documents: results, query: query, selection: $library.selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            if let doc = library.documents.first(where: { $0.url == library.selection }) {
                TranscriptDetail(document: doc, query: query)
                    .id(doc.url)
            } else if library.documents.isEmpty, !library.isLoading {
                ContentUnavailableView("No Transcripts Yet", systemImage: "waveform",
                                       description: Text("Transcripts of your calls appear here a few seconds after each call ends."))
            } else {
                ContentUnavailableView("Select a Transcript", systemImage: "text.bubble")
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search transcripts")
        .overlay {
            if !query.isEmpty, results.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .onAppear {
            library.open(folder: model.transcriptsFolder)
            if library.selection == nil { library.selection = library.documents.first?.url }
        }
        .onChange(of: library.documents) {
            if library.selection == nil { library.selection = library.documents.first?.url }
        }
        // Behave like a normal app (Dock icon, ⌘-Tab) while the viewer is open.
        .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Sidebar

struct TranscriptSidebar: View {
    let documents: [TranscriptDocument]
    let query: String
    @Binding var selection: URL?

    var body: some View {
        List(selection: $selection) {
            ForEach(Self.sections(documents), id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { doc in
                        TranscriptRow(document: doc, query: query)
                            .tag(doc.url)
                            .contextMenu { TranscriptActions(document: doc) }
                    }
                }
            }
        }
    }

    /// Today, Yesterday, This Week, then one section per month.
    static func sections(_ docs: [TranscriptDocument], now: Date = .now) -> [(title: String, items: [TranscriptDocument])] {
        let cal = Calendar.current
        func title(_ d: Date?) -> String {
            guard let d else { return String(localized: "Older") }
            if cal.isDateInToday(d) { return String(localized: "Today") }
            if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
            if let week = cal.dateInterval(of: .weekOfYear, for: now), week.contains(d) { return String(localized: "This Week") }
            return d.formatted(.dateTime.month(.wide).year())
        }
        var out: [(title: String, items: [TranscriptDocument])] = []
        for doc in docs {
            let t = title(doc.date)
            if out.last?.title == t { out[out.count - 1].items.append(doc) } else { out.append((t, [doc])) }
        }
        return out
    }
}

struct TranscriptRow: View {
    let document: TranscriptDocument
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(document.title)
                .font(.headline)
                .lineLimit(1)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = document.date {
            // The section already says the day for recent ones.
            let cal = Calendar.current
            if cal.isDateInToday(d) || cal.isDateInYesterday(d) {
                parts.append(d.formatted(date: .omitted, time: .shortened))
            } else if let week = cal.dateInterval(of: .weekOfYear, for: .now), week.contains(d) {
                parts.append(d.formatted(.dateTime.weekday(.wide).hour().minute()))
            } else {
                parts.append(d.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
            }
        }
        if let m = document.durationMinutes, m > 0 { parts.append("\(m) min") }
        if let app = document.app, app != "Manual" { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    /// The first line that matches the search, so you can see why it matched.
    private var snippet: String? {
        let words = TranscriptDocument.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return nil }
        return document.lines.first { TranscriptDocument.fold($0.text).contains(first) }.map { "\($0.speaker): \($0.text)" }
    }
}

// MARK: - Detail

struct TranscriptDetail: View {
    let document: TranscriptDocument
    let query: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                if document.lines.isEmpty {
                    Text("No speech was detected in this recording.")
                        .foregroundStyle(.secondary)
                }
                ForEach(document.lines) { line in
                    LineView(line: line, color: color(for: line.speaker), query: query)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
        .navigationTitle(document.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let link = document.meetingLink, let url = URL(string: link) {
                    Button("Open Meeting Link", systemImage: "video") { openURL(url) }
                }
                Button("Copy Transcript", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.plainText, forType: .string)
                }
                ShareLink(item: document.url)
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([document.url])
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document.title)
                .font(.largeTitle.bold())
            Text(details)
                .foregroundStyle(.secondary)
            if !document.attendees.isEmpty {
                Text("With \(document.attendees.formatted(.list(type: .and)))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if let d = document.date { parts.append(d.formatted(date: .complete, time: .shortened)) }
        if let m = document.durationMinutes, m > 0 { parts.append("\(m) min") }
        if let app = document.app, app != "Manual" { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    /// Me in the accent color; each other person gets their own system color.
    private func color(for speaker: String) -> Color {
        if speaker == "Me" { return .accentColor }
        let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .brown, .indigo]
        let others = document.speakers.filter { $0 != "Me" }
        return palette[(others.firstIndex(of: speaker) ?? 0) % palette.count]
    }
}

struct LineView: View {
    let line: TranscriptDocument.Line
    let color: Color
    let query: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(TranscriptDocument.clock(line.time))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.speaker)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                Text(highlighted)
                    .font(.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The text with search words marked, matching regardless of case and accents.
    private var highlighted: AttributedString {
        var attributed = AttributedString(line.text)
        let words = TranscriptDocument.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return attributed }
        let folded = TranscriptDocument.fold(line.text)
        // Folding keeps character counts for Latin text, so offsets line up with the original.
        guard folded.count == line.text.count else { return attributed }
        for word in words {
            var search = folded.startIndex..<folded.endIndex
            while let r = folded.range(of: word, range: search) {
                let lo = folded.distance(from: folded.startIndex, to: r.lowerBound)
                let len = folded.distance(from: r.lowerBound, to: r.upperBound)
                let a = attributed.index(attributed.startIndex, offsetByCharacters: lo)
                let b = attributed.index(a, offsetByCharacters: len)
                attributed[a..<b].backgroundColor = .yellow.opacity(0.35)
                search = r.upperBound..<folded.endIndex
            }
        }
        return attributed
    }
}

// MARK: - Shared actions

struct TranscriptActions: View {
    let document: TranscriptDocument

    var body: some View {
        Button("Copy Transcript", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(document.plainText, forType: .string)
        }
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([document.url])
        }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            NSWorkspace.shared.recycle([document.url])
        }
    }
}
