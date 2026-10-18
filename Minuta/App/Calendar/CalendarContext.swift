import EventKit
import Foundation
import MinutaCore

/// Reads the Mac's calendars (read-only) to know which meeting a call is: its title, the other
/// people, and the meeting link. Also makes detection faster when a meeting is on.
@Observable
final class CalendarContext {
    struct EventInfo: Sendable, Equatable {
        var title: String
        var attendees: [String]
        var link: String?
        var start: Date
        var end: Date
    }

    enum Access: Equatable { case unknown, granted, denied }

    private(set) var access: Access = .unknown
    @ObservationIgnored private let store = EKEventStore()
    /// Calendars that never hold calls.
    @ObservationIgnored private let skippedCalendars: Set<String> = ["Scheduled Reminders", "Birthdays", "Cumpleaños", "Siri Suggestions"]

    func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    func requestAccess() async {
        do {
            access = try await store.requestFullAccessToEvents() ? .granted : .denied
        } catch {
            access = .denied
        }
    }

    /// The meeting on now that best fits a call in `app`: one with that app's link wins,
    /// then one with other people, then the one starting closest to now.
    func currentEvent(for app: CallApp?, now: Date = .now) -> EventInfo? {
        guard access == .granted else { return nil }
        let calendars = store.calendars(for: .event).filter {
            !skippedCalendars.contains($0.title) && $0.type != .birthday && $0.type != .subscription
        }
        guard !calendars.isEmpty else { return nil }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600),
                                                 end: now.addingTimeInterval(15 * 60), calendars: calendars)
        let candidates = store.events(matching: predicate).filter {
            !$0.isAllDay && $0.status != .canceled
                && $0.startDate <= now.addingTimeInterval(10 * 60)   // up to 10 min early
                && $0.endDate >= now.addingTimeInterval(-5 * 60)     // or a bit late
        }
        func score(_ e: EKEvent) -> Double {
            var s = 0.0
            let link = Self.link(in: e)
            if let app, let link, app.linkMarkers.contains(where: { link.contains($0) }) { s += 100 }
            else if link != nil { s += 20 }
            if (e.attendees?.count ?? 0) > 1 { s += 10 }
            s -= abs(e.startDate.timeIntervalSince(now)) / 600
            return s
        }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return nil }
        let attendees = (best.attendees ?? [])
            .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
            .compactMap { $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
        return EventInfo(title: best.title ?? "Meeting", attendees: attendees, link: Self.link(in: best),
                         start: best.startDate, end: best.endDate)
    }

    /// The next meeting starting within `window`: one with a call link or other people.
    func nextMeeting(now: Date = .now, within window: TimeInterval = 3600) -> EventInfo? {
        guard access == .granted else { return nil }
        let calendars = store.calendars(for: .event).filter {
            !skippedCalendars.contains($0.title) && $0.type != .birthday && $0.type != .subscription
        }
        guard !calendars.isEmpty else { return nil }
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(window), calendars: calendars))
            .filter { !$0.isAllDay && $0.status != .canceled && $0.startDate > now
                && (Self.link(in: $0) != nil || ($0.attendees?.count ?? 0) > 1) }
            .sorted { $0.startDate < $1.startDate }
        guard let e = events.first else { return nil }
        return EventInfo(title: e.title ?? "Meeting", attendees: [], link: Self.link(in: e), start: e.startDate, end: e.endDate)
    }

    func hasEvent(for app: CallApp?, now: Date = .now) -> Bool {
        guard let event = currentEvent(for: app, now: now) else { return false }
        guard let app, !app.linkMarkers.isEmpty, let link = event.link else { return true }
        return app.linkMarkers.contains { link.contains($0) }
    }

    /// The video-call link: the event URL, or the first link in its location or notes.
    static func link(in event: EKEvent) -> String? {
        if let url = event.url?.absoluteString, url.hasPrefix("http") { return url }
        let text = [event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        guard !text.isEmpty, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let links = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url?.absoluteString)
        let markers = CallApp.all.flatMap(\.linkMarkers)
        return links.first { l in markers.contains { l.contains($0) } } ?? links.first
    }
}
