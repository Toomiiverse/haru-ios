import EventKit
import Observation

/// Her list, in Apple Reminders.
///
/// A list called "Haru" that matches hers both ways. What you ask her to
/// remind you of (a task on `GET /api/agenda`) shows up there with its day
/// and, when she was told one, its time as an alarm; a reminder you add to
/// that list reaches her (`POST /api/agenda`), and ticking one off on either
/// side ticks it off on the other (`POST /api/agenda/done`). Events stay in
/// Calendar — hers come from Google already — so only tasks cross.
///
/// The phone is the only place this can happen: iCloud stopped exposing
/// reminder lists over CalDAV with the iOS 13 Reminders upgrade, so a server
/// cannot write to them. EventKit can, and the app is on the phone. It runs
/// when the app comes to the front, on a background refresh, after a
/// tick-off, and whenever Reminders itself reports a change — so a tick on
/// the lock screen reaches her within the minute while the app is open.
///
/// Which reminder is which item is kept on the phone (haru id → reminder
/// identifier). Lost mappings recover by title and day; a reminder deleted
/// from the phone counts as dealt with and is ticked off on her side.
@MainActor @Observable
final class Reminders {
    static let shared = Reminders()
    static let listName = "Haru"
    private static let enabledKey = "reminders.enabled"
    private static let listKey = "reminders.list"
    private static let mapKey = "reminders.map"

    var enabled: Bool
    var problem: String?
    var lastSync: Date?
    var mirrored = 0

    private let store = EKEventStore()
    private var syncing = false
    private var lastRun = Date.distantPast
    /// Our own saves come straight back as a change; not worth a second pass.
    private var quietUntil = Date.distantPast
    private var client: HaruClient { Session.savedClient() }

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, Date() > self.quietUntil else { return }
                await self.sync(force: true)
            }
        }
    }

    static var access: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }

    /// The settings page opening: nothing to fetch, but a switch left on
    /// after access was taken away in Settings should say so.
    func load() async {
        if enabled, Self.access != .fullAccess {
            problem = "Reminders access has gone. It can be given back under Settings → Privacy & Security → Reminders → Haru."
        }
    }

    func setEnabled(_ on: Bool) async {
        if on {
            guard await authorise() else {
                problem = "Reminders access was not allowed. It can be changed under Settings → Privacy & Security → Reminders → Haru."
                return
            }
        }
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { await sync(force: true) }
    }

    /// The app is back in front: mirror soon.
    func wake() {
        guard enabled else { return }
        Task { await sync(force: true) }
    }

    var lastSyncLine: String {
        guard let lastSync else { return "Not yet" }
        let when = RelativeDateTimeFormatter().localizedString(for: lastSync, relativeTo: Date())
        return "\(mirrored) on the list · \(when)"
    }

    private func authorise() async -> Bool {
        if Self.access == .fullAccess { return true }
        return (try? await store.requestFullAccessToReminders()) ?? false
    }

    // MARK: The pass

    private struct Written: Decodable {
        struct Item: Decodable { let id: String }
        let item: Item
    }

    /// One pass, both ways. `force` skips the minute's spacing that keeps a
    /// burst of foreground/refresh/change calls from running it four times.
    func sync(force: Bool) async {
        guard enabled, !syncing else { return }
        if !force, Date().timeIntervalSince(lastRun) < 60 { return }
        guard Self.access == .fullAccess else {
            problem = "Reminders access has gone. It can be given back under Settings → Privacy & Security → Reminders → Haru."
            return
        }
        syncing = true
        defer { syncing = false }
        lastRun = Date()
        do {
            let page: AgendaPage = try await client.get("/api/agenda")
            let list = try haruList()
            let existing = await reminders(in: list)
            var map = mapping()
            var byId: [String: EKReminder] = [:]
            for reminder in existing { byId[reminder.calendarItemIdentifier] = reminder }
            var claimed = Set<String>()
            var toTick: [String] = []
            var created: [(id: String, reminder: EKReminder)] = []
            var count = 0

            // Hers → the phone.
            for item in page.items where item.kind == "task" {
                let done = item.done ?? false
                if let rid = map[item.id] {
                    if let reminder = byId[rid] {
                        claimed.insert(rid)
                        if reminder.isCompleted, !done {
                            // Ticked on the phone: hers follows, and shows as done next pass.
                            toTick.append(item.id)
                            count += 1
                            continue
                        }
                        if apply(item, to: reminder) { try store.save(reminder, commit: false) }
                        if !done { count += 1 }
                    } else {
                        // Gone from the phone: he dealt with it, as far as she is concerned.
                        map[item.id] = nil
                        if !done { toTick.append(item.id) }
                    }
                    continue
                }
                if done { continue }
                // Same words, same day, made on the phone before we knew each other: adopt it.
                if let mate = existing.first(where: { candidate in
                    !claimed.contains(candidate.calendarItemIdentifier)
                        && !map.values.contains(candidate.calendarItemIdentifier)
                        && candidate.title == item.title
                        && Self.dayKey(candidate.dueDateComponents) == item.date
                }) {
                    claimed.insert(mate.calendarItemIdentifier)
                    map[item.id] = mate.calendarItemIdentifier
                    if apply(item, to: mate) { try store.save(mate, commit: false) }
                    count += 1
                    continue
                }
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = list
                _ = apply(item, to: reminder)
                try store.save(reminder, commit: false)
                created.append((item.id, reminder))
                count += 1
            }

            quietUntil = Date(timeIntervalSinceNow: 3)
            try store.commit()
            for (id, reminder) in created { map[id] = reminder.calendarItemIdentifier }

            // The phone → hers: a reminder added to her list by hand.
            for reminder in existing
            where !claimed.contains(reminder.calendarItemIdentifier)
                && !map.values.contains(reminder.calendarItemIdentifier)
                && !reminder.isCompleted
                && !(reminder.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                var body: [String: JSONValue] = [
                    "title": .string(reminder.title),
                    "date": .string(Self.dayKey(reminder.dueDateComponents) ?? Self.dayKey(Date())),
                ]
                if let clock = Self.clock(reminder.dueDateComponents) { body["time"] = .string(clock) }
                let written: Written = try await client.post("/api/agenda", body)
                map[written.item.id] = reminder.calendarItemIdentifier
                count += 1
            }

            for id in toTick {
                let _: Ignored? = try? await client.post("/api/agenda/done", ["id": .string(id)])
            }

            save(mapping: map)
            mirrored = count
            lastSync = Date()
            problem = nil
        } catch HaruError.signedOut {
            // Signed out: nothing to mirror until they are back.
        } catch {
            problem = "Reminders: \(error.localizedDescription)"
        }
    }

    /// Her item onto a reminder. True when something had to change, so an
    /// unchanged list costs no saves — iCloud would otherwise re-sync every
    /// reminder on every pass.
    private func apply(_ item: AgendaItem, to reminder: EKReminder) -> Bool {
        var changed = false
        if reminder.title != item.title { reminder.title = item.title; changed = true }
        let due = Self.components(item.date, item.time)
        if !Self.same(reminder.dueDateComponents, due) { reminder.dueDateComponents = due; changed = true }
        let done = item.done ?? false
        if reminder.isCompleted != done { reminder.isCompleted = done; changed = true }
        // One alarm at the time she was told; none for a bare day, which
        // Reminders already surfaces in Today on the morning.
        if let time = item.time, let when = Self.date(item.date, time) {
            if (reminder.alarms ?? []).first?.absoluteDate != when { reminder.alarms = [EKAlarm(absoluteDate: when)]; changed = true }
        } else if !(reminder.alarms ?? []).isEmpty {
            reminder.alarms = nil
            changed = true
        }
        return changed
    }

    private func reminders(in list: EKCalendar) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: store.predicateForReminders(in: [list])) { found in
                continuation.resume(returning: found ?? [])
            }
        }
    }

    /// The Haru list: the one we made, else one of that name, else a new one
    /// on iCloud so it shows on every device — or wherever the default list
    /// lives when there is no iCloud.
    private func haruList() throws -> EKCalendar {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.listKey), let list = store.calendar(withIdentifier: id), list.allowsContentModifications {
            return list
        }
        if let list = store.calendars(for: .reminder).first(where: { $0.title == Self.listName && $0.allowsContentModifications }) {
            defaults.set(list.calendarIdentifier, forKey: Self.listKey)
            return list
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.listName
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first(where: { $0.sourceType == .local }) else {
            throw HaruError.server(0, "There is nowhere on this phone to keep a list.")
        }
        list.source = source
        try store.saveCalendar(list, commit: true)
        defaults.set(list.calendarIdentifier, forKey: Self.listKey)
        return list
    }

    // MARK: The mapping, and dates

    private func mapping() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: Self.mapKey) as? [String: String]) ?? [:]
    }

    private func save(mapping: [String: String]) {
        UserDefaults.standard.set(mapping, forKey: Self.mapKey)
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let clockIn: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    static func dayKey(_ date: Date) -> String { day.string(from: date) }

    static func dayKey(_ components: DateComponents?) -> String? {
        guard let c = components, let y = c.year, let m = c.month, let d = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// "09:00" from a reminder that has a time of day; nil for a bare day.
    static func clock(_ components: DateComponents?) -> String? {
        guard let c = components, let h = c.hour, let m = c.minute else { return nil }
        return String(format: "%02d:%02d", h, m)
    }

    /// Her "9:00 AM" as hour and minute.
    static func hourMinute(_ time: String) -> (Int, Int)? {
        guard let when = clockIn.date(from: time.uppercased()) else { return nil }
        let parts = Calendar(identifier: .gregorian).dateComponents([.hour, .minute], from: when)
        guard let h = parts.hour, let m = parts.minute else { return nil }
        return (h, m)
    }

    static func components(_ date: String, _ time: String?) -> DateComponents? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents(calendar: .current, timeZone: .current, year: parts[0], month: parts[1], day: parts[2])
        if let time, let (h, m) = hourMinute(time) { c.hour = h; c.minute = m }
        return c
    }

    static func date(_ date: String, _ time: String) -> Date? {
        components(date, time)?.date
    }

    /// Year, month, day, hour and minute — the parts that mean anything; what
    /// EventKit stores alongside them is its own business.
    static func same(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        (a?.year, a?.month, a?.day, a?.hour, a?.minute) == (b?.year, b?.month, b?.day, b?.hour, b?.minute)
    }
}
