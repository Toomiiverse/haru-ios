import HealthKit
import Observation

/// How they slept and how far they have walked, from Apple Health, for her —
/// only while the switch on the server says so. One report at a time: last
/// night's sleep and today's steps, to POST /api/body; she gets one background
/// sentence out of it. Health wakes the app when new samples land (background
/// delivery), so the figures keep coming with the app closed. One shared
/// instance, because the app delegate has to re-arm the watch on a cold
/// launch before any view exists.
@MainActor @Observable
final class Health {
    static let shared = Health()
    private static let enabledKey = "health.enabled"

    var state: BodyState?
    var problem: String?

    private let store = HKHealthStore()
    private var observing = false
    private var lastSent = Date.distantPast

    static var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private var sleepType: HKCategoryType { HKCategoryType(.sleepAnalysis) }
    private var stepType: HKQuantityType { HKQuantityType(.stepCount) }
    private var client: HaruClient { Session.savedClient() }

    /// Whether the switch was on last time we heard from the server, kept on
    /// the phone so a cold launch in the background can re-arm without asking.
    private var enabledLocally: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func load() async {
        do {
            state = try await client.get("/api/body")
            enabledLocally = state?.enabled == true
            if state?.enabled == true { await start(andReport: true) }
        } catch {
            problem = error.localizedDescription
        }
    }

    func setEnabled(_ on: Bool) async {
        if on {
            guard Self.available else { problem = "This phone has no Health data to read."; return }
            guard await authorise() else {
                problem = "Health access was not allowed. It can be changed under Settings → Health → Data Access & Devices → Haru."
                return
            }
        }
        do {
            state = try await client.post("/api/body/prefs", ["enabled": .bool(on)])
            enabledLocally = state?.enabled == true
        } catch {
            problem = error.localizedDescription
            return
        }
        if on { await start(andReport: true) }
    }

    /// A cold launch, possibly by Health in the background: re-arm the watch
    /// if the switch was on, and let the observer decide whether to send.
    func resume() {
        guard enabledLocally, Self.available else { return }
        Task { await start(andReport: false) }
    }

    /// The app is back in front: send today's figures soon.
    func wake() {
        guard enabledLocally else { return }
        Task { await report(force: true) }
    }

    private func authorise() async -> Bool {
        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType, stepType])
            return true
        } catch {
            return false
        }
    }

    /// Ask Health to call when new sleep or steps land, and to wake the app
    /// for it; then send now if asked.
    private func start(andReport: Bool) async {
        if !observing {
            observing = true
            for type in [sleepType as HKSampleType, stepType as HKSampleType] {
                let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, done, _ in
                    Task { @MainActor in
                        await self?.report(force: false)
                        done()
                    }
                }
                store.execute(query)
                try? await store.enableBackgroundDelivery(for: type, frequency: .hourly)
            }
        }
        if andReport { await report(force: true) }
    }

    /// Last night's sleep and today's steps, to the server. Spaced, because
    /// Health calls several times for one night.
    func report(force: Bool) async {
        guard enabledLocally, Self.available else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastSent) < 15 * 60 { return }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        // Last night: from six in the evening to noon, whatever was asleep.
        guard let nightFrom = calendar.date(byAdding: .hour, value: -6, to: startOfToday),
              let nightTo = calendar.date(byAdding: .hour, value: 12, to: startOfToday) else { return }
        async let night = sleep(from: nightFrom, to: min(nightTo, now))
        async let walked = steps(from: startOfToday, to: now)
        let (slept, stepCount) = await (night, walked)
        guard slept != nil || stepCount != nil else { return }
        var body: [String: JSONValue] = ["day": .string(Self.dayKey(now))]
        body["sleepMinutes"] = slept.map { .number(Double($0.minutes)) } ?? .null
        body["sleepStart"] = slept.map { .string(Self.iso($0.start)) } ?? .null
        body["sleepEnd"] = slept.map { .string(Self.iso($0.end)) } ?? .null
        body["steps"] = stepCount.map { .number(Double($0)) } ?? .null
        do {
            state = try await client.post("/api/body", body)
            lastSent = now
        } catch HaruError.server(let code, _) where code == 409 {
            // Switched off on the server side since we last looked.
            enabledLocally = false
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Minutes asleep between two instants, with the span they cover. Several
    /// sources can record the same night, so overlapping stretches are merged.
    private func sleep(from: Date, to: Date) async -> (minutes: Int, start: Date, end: Date)? {
        let within = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleepType, predicate: within)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        guard let samples = try? await descriptor.result(for: store), !samples.isEmpty else { return nil }
        let asleep: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]
        var stretches: [(Date, Date)] = samples.filter { asleep.contains($0.value) }.map { ($0.startDate, $0.endDate) }
        guard !stretches.isEmpty else { return nil }
        stretches.sort { $0.0 < $1.0 }
        var merged: [(Date, Date)] = []
        for stretch in stretches {
            if let last = merged.last, stretch.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, stretch.1)
            } else {
                merged.append(stretch)
            }
        }
        let seconds = merged.reduce(0.0) { $0 + $1.1.timeIntervalSince($1.0) }
        guard let first = merged.first, let last = merged.last else { return nil }
        return (Int(seconds / 60), first.0, last.1)
    }

    private func steps(from: Date, to: Date) async -> Int? {
        let within = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let descriptor = HKStatisticsQueryDescriptor(predicate: .quantitySample(type: stepType, predicate: within), options: .cumulativeSum)
        guard let stats = try? await descriptor.result(for: store), let sum = stats.sumQuantity() else { return nil }
        return Int(sum.doubleValue(for: .count()))
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
