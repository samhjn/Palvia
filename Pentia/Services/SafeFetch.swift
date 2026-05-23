import Foundation
import SwiftData

/// Wrapper around `ModelContext.fetch` that also catches Objective-C
/// `NSException`s raised from Core Data beneath SwiftData. Swift's `try?` only
/// catches `Swift.Error`; an NSException escapes and aborts the process.
///
/// Returns `nil` on either a Swift error or an NSException. On NSException,
/// the exception name/reason is persisted via `CrashDiagnostics` so the next
/// launch can log the specific trigger.
///
/// Callers typically fall back to an empty array: `SafeFetch.perform(...) ?? []`.
enum SafeFetch {
    static func perform<T>(
        _ context: ModelContext,
        _ descriptor: FetchDescriptor<T>,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> [T]? {
        var result: [T]?
        var swiftError: Error?
        let nsException = ObjCExceptionCatcher.catching {
            do {
                result = try context.fetch(descriptor)
            } catch {
                swiftError = error
            }
        }
        if let nsException {
            CrashDiagnostics.record(
                source: "SafeFetch \(file):\(line)",
                name: nsException.name.rawValue,
                reason: nsException.reason ?? "nil"
            )
            return nil
        }
        if let swiftError {
            print("[SafeFetch] Swift.Error at \(file):\(line): \(swiftError)")
            return nil
        }
        return result
    }
}
