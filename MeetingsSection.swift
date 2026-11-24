// The meetings section: today's meetings, a click to join the call, and a
// notification shortly before each one starts.
//
// Events come from EventKit, so whatever the Calendar app syncs — Google, iCloud,
// Exchange — is what shows here, with nothing of its own to sign in to. All-day
// events, cancelled ones and ones you declined are left out.
//
// EventKit has no field for a video call. Google writes the Meet address into the
// event notes, and Zoom and Teams invitations put theirs in the notes or the
// location, so the event's URL, location and notes are searched in that order for
// the address of a known call service. Other links — documents, Google's own
// "learn more about Meet" page, a dial-in number — are never taken for a call.
//
// Reminders are local notifications. One that lies ahead is handed to the system
// in advance, so it arrives on the minute even while this app is napping; one
// whose moment has already passed — MacBar launched ten minutes before a meeting,
// or a meeting just added — is posted on the spot, once. Either way the
// notification's Join button opens the call.
//
//   defaults write local.macbar meetingReminderMinutes -int 10   # default 30; 0 turns them off
//
// Compiled two ways, from the same source — into MacBar alongside the other
// sections, or into MeetingsBar.app on its own. Both builds supply the host that
// defines BarSection; see build.sh. Either bundle needs a calendar usage string
// in its Info.plist, or macOS refuses access without asking.
//
// Everything lives inside the section type on purpose. Sections from different
// repositories are compiled into one module, so a top-level `Meeting` here would
// be free to collide with a top-level type in a sibling.

import AppKit
import EventKit
import Foundation
import UserNotifications

final class MeetingsSection: NSObject, BarSection, UNUserNotificationCenterDelegate {
    let name = "Meetings"
    let showKey = "showMeetings"

    /// Minutes before a meeting to remind, and how close a meeting has to be for
    /// the menu bar to colour it. 0 turns reminders off.
    static let leadKey = "meetingReminderMinutes"
    static let defaultLead = 30

    /// The occurrences whose reminder has been taken care of, either handed to
    /// the system or posted on the spot, mapped to their start time so that old
    /// entries can be dropped. Kept across launches: a rebuild in the half hour
    /// before a meeting must not remind a second time.
    private static let handledKey = "meetingRemindersHandled"

    private static let requestPrefix = "meeting-reminder:"
    private static let joinCategory = "meeting-join"
    private static let joinAction = "join"

    struct Meeting {
        /// One occurrence: a repeating event shares its identifier across all of
        /// them, so the start time is part of the key. A meeting that moves gets
        /// a new key, and with it a new reminder.
        let key: String
        let title: String
        let start: Date
        let end: Date
        let join: URL?
        let service: String?
    }

    enum Access { case undecided, granted, refused }

    private var store = EKEventStore()
    private var access = Access.undecided
    /// Today's, by start time.
    private var meetings: [Meeting] = []
    /// Nil until the system has said.
    private var notificationsAllowed: Bool?

    private var onUpdate: () -> Void = {}
    private var timer: Timer?
    /// Each with the center it was added to, which is where it has to be removed.
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var lead: Int {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: Self.leadKey) == nil ? Self.defaultLead : defaults.integer(forKey: Self.leadKey)
    }

    // MARK: - Lifecycle

    func activate(onUpdate: @escaping () -> Void) {
        self.onUpdate = onUpdate

        if Self.currentAccess() == .undecided {
            requestAccess { [weak self] in
                DispatchQueue.main.async { self?.reload() }
            }
        }
        setUpNotifications()

        // Any change to any calendar, including one synced in the background.
        reload(on: .EKEventStoreChanged, from: NotificationCenter.default)
        // A repeating timer does not catch up after sleep; reread at once.
        reload(on: NSWorkspace.didWakeNotification, from: NSWorkspace.shared.notificationCenter)

        // On the minute, so a countdown turns over when the clock does, and in
        // the common modes, so it keeps counting while the menu is open.
        let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0),
                                             matchingPolicy: .nextTime) ?? Date().addingTimeInterval(60)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in self?.reload() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        reload()
    }

    /// Switched off: no clock, no observers, and no reminder left pending with
    /// the system — those would otherwise still arrive. Also called at launch
    /// when the section is off, which is what clears reminders a previous run
    /// scheduled.
    func deactivate() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        meetings = []

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.removePendingNotificationRequests(withIdentifiers: pending.map { $0.identifier }
                .filter { $0.hasPrefix(Self.requestPrefix) })
        }
    }

    func refresh(force: Bool) { reload() }

    private func reload(on name: Notification.Name, from center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        observers.append((center, token))
    }

    private func reload() {
        let before = access
        access = Self.currentAccess()
        guard access == .granted else {
            meetings = []
            onUpdate()
            return
        }
        // Access granted since the last look, at the prompt or later in System
        // Settings: start from a fresh store rather than trusting one created
        // while it was still undecided or refused.
        if before != .granted { store = EKEventStore() }

        let now = Date()
        let (today, tomorrow) = Self.today(now)
        // Past midnight by the lead, so a 00:15 meeting is reminded at 23:45.
        let upcoming = fetch(from: today, to: tomorrow.addingTimeInterval(TimeInterval(max(lead, 0) * 60)))
        meetings = upcoming.filter { $0.start < tomorrow }
        remind(upcoming, now: now)
        readNotificationSettings()
        onUpdate()
    }

    // MARK: - Calendar

    /// Raw value 3 is .fullAccess, which was called .authorized before macOS 14.
    /// Compared by value so one line serves both, without the deprecated name.
    private static func currentAccess() -> Access {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined { return .undecided }
        return status.rawValue == 3 ? .granted : .refused
    }

    /// Calls back on whatever queue EventKit chooses: `--print` waits on the main
    /// thread, so hopping there would stall it.
    private func requestAccess(_ done: @escaping () -> Void) {
        let completion: (Bool, Error?) -> Void = { _, _ in done() }
        if #available(macOS 14, *) {
            store.requestFullAccessToEvents(completion: completion)
        } else {
            store.requestAccess(to: .event, completion: completion)
        }
    }

    private static func today(_ now: Date) -> (Date, Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    private func fetch(from start: Date, to end: Date) -> [Meeting] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && !Self.declined($0) }
            .map { event in
                let link = Self.joinLink(event)
                let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return Meeting(
                    key: "\(event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSince1970))",
                    title: title.isEmpty ? "(No title)" : title,
                    start: event.startDate,
                    end: event.endDate,
                    join: link?.url,
                    service: link?.service)
            }
            .sorted { $0.start < $1.start }
    }

    private static func declined(_ event: EKEvent) -> Bool {
        event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus == .declined
    }

    // MARK: - Join links

    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func joinLink(_ event: EKEvent) -> (url: URL, service: String)? {
        var candidates: [URL] = []
        if let url = event.url { candidates.append(url) }
        for text in [event.location, event.notes] {
            guard let text = text, !text.isEmpty else { continue }
            let range = NSRange(text.startIndex..., in: text)
            candidates += linkDetector.matches(in: text, range: range).compactMap { $0.url }
        }
        for url in candidates {
            if let service = service(of: url) { return (url, service) }
        }
        return nil
    }

    /// The call service a link joins, by its address. Only meeting addresses
    /// count: a bare meet.google.com, or a Zoom page that is not a meeting, is
    /// not something to join.
    private static func service(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path
        func under(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if host == "meet.google.com", path.count > 1 { return "Meet" }
        if under("zoom.us") || under("zoomgov.com"),
           ["/j/", "/my/", "/s/", "/w/"].contains(where: { path.hasPrefix($0) }) { return "Zoom" }
        if host == "teams.microsoft.com", path.contains("meetup-join") || path.hasPrefix("/meet/") { return "Teams" }
        if host == "teams.live.com", path.hasPrefix("/meet/") { return "Teams" }
        if under("webex.com"), path.count > 1 { return "Webex" }
        if host == "meet.jit.si", path.count > 1 { return "Jitsi" }
        if under("whereby.com"), path.count > 1 { return "Whereby" }
        if host == "facetime.apple.com", path.hasPrefix("/join") { return "FaceTime" }
        return nil
    }

    // MARK: - Reminders

    /// The app has one notification delegate and one set of categories. This
    /// section takes both; a second section wanting notifications would need
    /// them moved into the host.
    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.joinCategory, actions: [join], intentIdentifiers: [], options: []),
        ])
        guard lead > 0 else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.readNotificationSettings()
        }
    }

    private func readNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                guard let self = self, self.notificationsAllowed != allowed else { return }
                self.notificationsAllowed = allowed
                self.onUpdate()
            }
        }
    }

    private func remind(_ upcoming: [Meeting], now: Date) {
        let center = UNUserNotificationCenter.current()
        let leadSeconds = TimeInterval(lead * 60)
        let defaults = UserDefaults.standard
        var handled = (defaults.dictionary(forKey: Self.handledKey) as? [String: Double] ?? [:])
            .filter { $0.value > now.timeIntervalSince1970 - 86400 }

        var ahead: [String: UNNotificationRequest] = [:]
        if leadSeconds > 0 {
            for meeting in upcoming where meeting.start > now {
                let id = Self.requestPrefix + meeting.key
                let moment = meeting.start.addingTimeInterval(-leadSeconds)
                if moment > now.addingTimeInterval(5) {
                    let when = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second], from: moment)
                    ahead[id] = UNNotificationRequest(
                        identifier: id,
                        content: content(meeting, minutes: lead),
                        trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
                    handled[meeting.key] = meeting.start.timeIntervalSince1970
                } else if handled[meeting.key] == nil {
                    let minutes = Int((meeting.start.timeIntervalSince(now) / 60).rounded(.up))
                    center.add(UNNotificationRequest(identifier: id, content: content(meeting, minutes: minutes),
                                                     trigger: nil))
                    handled[meeting.key] = meeting.start.timeIntervalSince1970
                }
            }
        }
        defaults.set(handled, forKey: Self.handledKey)

        // Re-adding a request replaces the pending one with the same identifier,
        // which picks up a renamed meeting or a changed lead. Anything of ours
        // still pending but no longer wanted is for a meeting that moved, was
        // declined or deleted, or for reminders that were turned off.
        let wanted = ahead
        center.getPendingNotificationRequests { pending in
            let stale = pending.map { $0.identifier }
                .filter { $0.hasPrefix(Self.requestPrefix) && wanted[$0] == nil }
            center.removePendingNotificationRequests(withIdentifiers: stale)
            for request in wanted.values { center.add(request) }
        }
    }

    private func content(_ meeting: Meeting, minutes: Int) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        var body = "Starts at \(Fmt.clock(meeting.start)), in \(minutes) min"
        if let service = meeting.service, let join = meeting.join {
            body += " · Join on \(service)"
            content.categoryIdentifier = Self.joinCategory
            content.userInfo = ["join": join.absoluteString]
        }
        content.body = body
        content.sound = .default
        content.threadIdentifier = "meetings"
        return content
    }

    /// Shown even when MacBar counts as frontmost, which it does while its menu
    /// is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// The Join button, or a click on the notification itself: either way, the call.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard response.actionIdentifier == Self.joinAction
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let address = response.notification.request.content.userInfo["join"] as? String,
              let url = URL(string: address) else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    // MARK: - Menu bar

    /// How close a meeting has to be to turn the reading into a countdown: the
    /// reminder's lead, or the default when reminders are off.
    private var soonWindow: TimeInterval { TimeInterval((lead > 0 ? lead : Self.defaultLead) * 60) }

    /// The one meeting the menu bar speaks for: the next to start, once it is
    /// close; otherwise the one under way; otherwise the next one today. Nothing
    /// left today means nothing in the bar.
    func titleSegments(compact: Bool) -> [Segment] {
        switch access {
        case .undecided: return []
        case .refused: return [.value("○ no access", color: Palette.warning)]
        case .granted: break
        }

        let now = Date()
        let reading: Segment
        let subject: Meeting
        if let soon = meetings.first(where: { $0.start > now && $0.start.timeIntervalSince(now) <= soonWindow }) {
            reading = .value("○ \(Self.countdown(to: soon.start, from: now))", color: Palette.warning)
            subject = soon
        } else if let current = meetings.first(where: { $0.start <= now && $0.end > now }) {
            reading = .value("● until \(Fmt.clock(current.end))")
            subject = current
        } else if let next = meetings.first(where: { $0.start > now }) {
            reading = .value("○ \(Fmt.clock(next.start))")
            subject = next
        } else {
            return []
        }
        return compact ? [reading] : [reading, .label(" " + Self.clip(subject.title, to: 24))]
    }

    // MARK: - Dropdown

    func menuRows() -> [NSMenuItem] {
        switch access {
        case .undecided:
            return [MenuKit.note("Waiting for access to your calendars…")]
        case .refused:
            return [
                MenuKit.alert("No access to your calendars"),
                MenuKit.action("Allow in Privacy & Security…", #selector(openCalendarPrivacy), target: self),
            ]
        case .granted:
            break
        }

        let now = Date()
        let next = meetings.first { $0.start > now }
        var rows = meetings.map { row($0, now: now, isNext: $0.key == next?.key) }
        if meetings.isEmpty {
            rows.append(MenuKit.note("No meetings today"))
        } else if !meetings.contains(where: { $0.end > now }) {
            rows.append(MenuKit.note("No more meetings today"))
        }
        rows.append(reminderRow())
        rows.append(MenuKit.action("Open Calendar", #selector(openCalendar), target: self))
        return rows
    }

    /// Over: dimmed. Under way: a dot in the state column. A meeting with a call
    /// joins it on click; one without stays at full strength but does nothing.
    private func row(_ meeting: Meeting, now: Date, isNext: Bool) -> NSMenuItem {
        var text = "\(Fmt.clock(meeting.start))–\(Fmt.clock(meeting.end))  \(Self.clip(meeting.title, to: 40))"
        guard meeting.end > now else { return MenuKit.note(text) }

        if isNext { text += "  (\(Self.countdown(to: meeting.start, from: now)))" }

        let item: NSMenuItem
        if let join = meeting.join, let service = meeting.service {
            item = MenuKit.action("\(text)  —  Join \(service)", #selector(join(_:)), target: self, object: join)
            item.toolTip = join.absoluteString
        } else {
            item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = true
        }
        if meeting.start <= now {
            item.state = .on
            item.onStateImage = Self.underWay
        }
        return item
    }

    private static let underWay = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Under way")?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .regular))

    private func reminderRow() -> NSMenuItem {
        guard lead > 0 else { return MenuKit.note("Reminders off") }
        guard notificationsAllowed != false else {
            let item = MenuKit.alert("Reminders blocked: allow notifications…")
            item.action = #selector(openNotificationSettings)
            item.target = self
            return item
        }
        return MenuKit.note("Reminder \(lead) min before each meeting")
    }

    // MARK: - Terminal

    func snapshot(_ completion: @escaping ([String], Bool) -> Void) {
        let answer = { [self] in
            guard Self.currentAccess() == .granted else {
                completion(["no access to your calendars: System Settings > Privacy & Security > Calendars"], false)
                return
            }
            let now = Date()
            let (today, tomorrow) = Self.today(now)
            let list = fetch(from: today, to: tomorrow)
            let next = list.first { $0.start > now }

            var lines = list.map { meeting -> String in
                let mark = meeting.end <= now ? "✓" : meeting.start <= now ? "●" : " "
                var line = "\(mark) \(Fmt.clock(meeting.start))–\(Fmt.clock(meeting.end))  \(meeting.title)"
                if meeting.key == next?.key { line += "  (\(Self.countdown(to: meeting.start, from: now)))" }
                if let join = meeting.join, let service = meeting.service { line += "  \(service): \(join.absoluteString)" }
                return line
            }
            if list.isEmpty { lines.append("No meetings today") }
            lines.append(lead > 0 ? "Reminder \(lead) min before each meeting" : "Reminders off")
            completion(lines, true)
        }

        if Self.currentAccess() == .undecided {
            requestAccess { [self] in
                store = EKEventStore()   // as in reload(): not the one made before the answer
                answer()
            }
        } else {
            answer()
        }
    }

    // MARK: - Formatting

    /// "in 25m", rounded up so it never reads "in 0m" before the start.
    private static func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        return minutes < 60 ? "in \(minutes)m" : "in \(minutes / 60)h \(minutes % 60)m"
    }

    private static func clip(_ s: String, to n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    // MARK: - Actions

    @objc private func join(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openCalendar() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openCalendarPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    @objc private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
    }
}
