import Foundation
import MetricKit

/// Persists the most recent NSException `name`/`reason` to UserDefaults so the
/// next launch can log it. Crash-safe — UserDefaults writes are flushed by the
/// OS even when the process terminates abnormally.
///
/// Also exposes a MetricKit-backed channel for crashes that bypass the
/// `NSSetUncaughtExceptionHandler` path (Swift runtime traps, signals, hangs).
/// MetricKit delivers these one launch later as `MXCrashDiagnostic`s; we
/// project them into a small Codable record and queue them on disk.
///
/// Intentionally does NOT alter, reset, or delete the SwiftData store. This
/// type is diagnostic-only: it captures what went wrong so we can identify the
/// trigger of future occurrences, without changing any user data.
enum CrashDiagnostics {
    private static let key = "iClaw.lastNSException"
    private static let metricsKey = "iClaw.metricKitCrashQueue"
    private static let metricsQueueLimit = 10

    struct Record: Codable {
        let source: String
        let name: String
        let reason: String
        let timestamp: Date
    }

    /// MetricKit-derived crash diagnostic. Captures the small slice of fields
    /// that fit in UserDefaults; the full call-stack tree is logged but not
    /// persisted (it can be 100s of KB).
    struct MetricRecord: Codable {
        let timestamp: Date
        let appVersion: String
        let osVersion: String
        let signal: Int?
        let exceptionType: Int?
        let exceptionCode: Int?
        let terminationReason: String?
    }

    static func record(source: String, name: String, reason: String) {
        let record = Record(source: source, name: name, reason: reason, timestamp: Date())
        if let data = try? JSONEncoder().encode(record) {
            UserDefaults.standard.set(data, forKey: key)
        }
        print("[CrashDiagnostics] \(source): \(name) — \(reason)")
    }

    static func consume() -> Record? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return record
    }

    static func recordMetric(_ rec: MetricRecord) {
        var queue = loadMetricQueue()
        queue.append(rec)
        // Keep the queue bounded — old reports past the limit are dropped
        // newest-wins so we don't lose info from a fresh crash storm.
        if queue.count > metricsQueueLimit {
            queue = Array(queue.suffix(metricsQueueLimit))
        }
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: metricsKey)
        }
    }

    static func consumeMetrics() -> [MetricRecord] {
        let queue = loadMetricQueue()
        if !queue.isEmpty {
            UserDefaults.standard.removeObject(forKey: metricsKey)
        }
        return queue
    }

    private static func loadMetricQueue() -> [MetricRecord] {
        guard let data = UserDefaults.standard.data(forKey: metricsKey),
              let queue = try? JSONDecoder().decode([MetricRecord].self, from: data)
        else { return [] }
        return queue
    }
}

/// Subscribes to `MXMetricManager` so Swift runtime traps and signal-based
/// crashes (which `NSSetUncaughtExceptionHandler` cannot see) get persisted
/// for next-launch logging. MetricKit delivers diagnostic payloads roughly
/// 24h after the crash, and on the next foreground launch following any
/// pending payloads.
///
/// Register once at app launch; `MXMetricManager.add(_:)` is idempotent for
/// the same subscriber.
final class CrashMetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashMetricsSubscriber()

    private override init() { super.init() }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            guard let crashes = payload.crashDiagnostics else { continue }
            for crash in crashes {
                let meta = crash.metaData
                let record = CrashDiagnostics.MetricRecord(
                    timestamp: payload.timeStampEnd,
                    appVersion: meta.applicationBuildVersion,
                    osVersion: meta.osVersion,
                    signal: crash.signal?.intValue,
                    exceptionType: crash.exceptionType?.intValue,
                    exceptionCode: crash.exceptionCode?.intValue,
                    terminationReason: crash.terminationReason
                )
                CrashDiagnostics.recordMetric(record)

                // Log full call-stack tree to the console for the developer
                // to grep in Console.app — we don't persist it (too large).
                let tree = crash.callStackTree.jsonRepresentation()
                if let s = String(data: tree, encoding: .utf8) {
                    print("[CrashMetrics] payload \(payload.timeStampEnd): "
                          + "signal=\(record.signal ?? -1) "
                          + "exceptionType=\(record.exceptionType ?? -1) "
                          + "callStackTree=\(s.prefix(8000))")
                }
            }
        }
    }

    /// MetricKit also delivers `MXMetricPayload` (daily metrics). We don't
    /// consume those, but the protocol requires the method.
    func didReceive(_ payloads: [MXMetricPayload]) {}
}
