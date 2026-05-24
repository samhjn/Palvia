import Foundation
import EventKit
import Contacts
import CoreLocation
import UserNotifications
import HealthKit

/// Centralized permission manager for Apple ecosystem APIs.
final class ApplePermissionManager {
    static let shared = ApplePermissionManager()
    private init() {}

    // Shared stores
    let eventStore = EKEventStore()
    let contactStore = CNContactStore()
    let healthStore = HKHealthStore()

    // MARK: - Calendar

    func requestCalendarAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    var calendarAuthorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func ensureCalendarAccess() async -> String? {
        switch calendarAuthorizationStatus {
        case .fullAccess:
            return nil
        case .notDetermined:
            let granted = await requestCalendarAccess()
            return granted ? nil : L10n.PermissionError.calendarDeniedByUser
        case .denied, .restricted:
            return L10n.PermissionError.calendarDenied
        case .writeOnly:
            return L10n.PermissionError.calendarWriteOnly
        @unknown default:
            return L10n.PermissionError.calendarUnknown
        }
    }

    // MARK: - Reminders

    func requestRemindersAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    var remindersAuthorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func ensureRemindersAccess() async -> String? {
        switch remindersAuthorizationStatus {
        case .fullAccess:
            return nil
        case .notDetermined:
            let granted = await requestRemindersAccess()
            return granted ? nil : L10n.PermissionError.remindersDeniedByUser
        case .denied, .restricted:
            return L10n.PermissionError.remindersDenied
        default:
            return L10n.PermissionError.remindersUnknown
        }
    }

    // MARK: - Contacts

    func requestContactsAccess() async -> Bool {
        do {
            return try await contactStore.requestAccess(for: .contacts)
        } catch {
            return false
        }
    }

    var contactsAuthorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func ensureContactsAccess() async -> String? {
        switch contactsAuthorizationStatus {
        case .authorized:
            return nil
        case .notDetermined:
            let granted = await requestContactsAccess()
            return granted ? nil : L10n.PermissionError.contactsDeniedByUser
        case .denied, .restricted:
            return L10n.PermissionError.contactsDenied
        case .limited:
            return nil
        @unknown default:
            return L10n.PermissionError.contactsUnknown
        }
    }

    // MARK: - Notifications

    func requestNotificationAccess() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func ensureNotificationAccess() async -> String? {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return nil
        case .notDetermined:
            let granted = await requestNotificationAccess()
            return granted ? nil : L10n.PermissionError.notificationDeniedByUser
        case .denied:
            return L10n.PermissionError.notificationDenied
        @unknown default:
            return L10n.PermissionError.notificationUnknown
        }
    }

    // MARK: - Location

    private var locationManagerDelegate: LocationPermissionDelegate?

    @MainActor
    func ensureLocationAccess() async -> String? {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return nil
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                let delegate = LocationPermissionDelegate { status in
                    switch status {
                    case .authorizedWhenInUse, .authorizedAlways:
                        continuation.resume(returning: nil)
                    default:
                        continuation.resume(returning: L10n.PermissionError.locationDeniedByUser)
                    }
                }
                self.locationManagerDelegate = delegate
                manager.delegate = delegate
                manager.requestWhenInUseAuthorization()
            }
        case .denied, .restricted:
            return L10n.PermissionError.locationDenied
        @unknown default:
            return L10n.PermissionError.locationUnknown
        }
    }

    // MARK: - Status Summary

    func permissionSummary() -> String {
        let cal = calendarAuthorizationStatus
        let rem = remindersAuthorizationStatus
        let con = contactsAuthorizationStatus
        let loc = CLLocationManager().authorizationStatus

        return """
        Apple Ecosystem Permissions:
        - Calendar: \(describeEKStatus(cal))
        - Reminders: \(describeEKStatus(rem))
        - Contacts: \(describeCNStatus(con))
        - Location: \(describeCLStatus(loc))
        - HealthKit: \(describeHealthAvailability())
        - Notifications: (check async)
        """
    }

    // MARK: - HealthKit

    private var healthAuthRequested = false

    /// All HealthKit types the app may read/write – requested once upfront.
    static let allHealthReadTypes: Set<HKObjectType> = {
        var types: Set<HKObjectType> = []
        let qIds: [HKQuantityTypeIdentifier] = [
            .stepCount, .heartRate, .bodyMass, .bodyFatPercentage, .height,
            .bloodPressureSystolic, .bloodPressureDiastolic,
            .bloodGlucose, .oxygenSaturation, .bodyTemperature,
            .dietaryEnergyConsumed, .dietaryWater,
            .dietaryCarbohydrates, .dietaryProtein, .dietaryFatTotal,
            .activeEnergyBurned, .distanceWalkingRunning,
        ]
        for id in qIds {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        if let sleep = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
        types.insert(HKObjectType.workoutType())
        // Note: HKCorrelationType.bloodPressure cannot be in read set either —
        // request the individual quantity types (systolic/diastolic) instead.
        return types
    }()

    static let allHealthWriteTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = []
        let qIds: [HKQuantityTypeIdentifier] = [
            .bodyMass, .bodyFatPercentage, .height,
            .heartRate, .bloodPressureSystolic, .bloodPressureDiastolic,
            .bloodGlucose, .oxygenSaturation, .bodyTemperature,
            .dietaryEnergyConsumed, .dietaryWater,
            .dietaryCarbohydrates, .dietaryProtein, .dietaryFatTotal,
            .activeEnergyBurned, .distanceWalkingRunning,
        ]
        for id in qIds {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        types.insert(HKObjectType.workoutType())
        // Note: HKCorrelationType.bloodPressure must NOT be in toShare —
        // only the individual quantity types (systolic/diastolic) are shareable.
        return types
    }()

    /// Request all HealthKit permissions once. Subsequent calls are no-ops.
    func ensureHealthAccess() async -> String? {
        guard HKHealthStore.isHealthDataAvailable() else {
            return L10n.PermissionError.healthUnavailable
        }
        if healthAuthRequested { return nil }
        do {
            try await healthStore.requestAuthorization(
                toShare: Self.allHealthWriteTypes,
                read: Self.allHealthReadTypes
            )
            healthAuthRequested = true
            return nil
        } catch {
            return L10n.PermissionError.healthFailed(error.localizedDescription)
        }
    }

    /// Legacy per-type entry point – still requests everything in batch.
    func ensureHealthAccess(read: Set<HKObjectType>, write: Set<HKSampleType>) async -> String? {
        await ensureHealthAccess()
    }

    /// Check if sharing (write) is authorized for a specific sample type.
    func isHealthSharingAuthorized(for type: HKObjectType) -> Bool {
        healthStore.authorizationStatus(for: type) == .sharingAuthorized
    }

    private func describeEKStatus(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .fullAccess: return "Full Access"
        case .writeOnly: return "Write Only"
        case .notDetermined: return "Not Determined"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private func describeCNStatus(_ s: CNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "Authorized"
        case .limited: return "Limited"
        case .notDetermined: return "Not Determined"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private func describeCLStatus(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When In Use"
        case .notDetermined: return "Not Determined"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }

    private func describeHealthAvailability() -> String {
        HKHealthStore.isHealthDataAvailable() ? "Available" : "Unavailable"
    }
}

// MARK: - Location Permission Helper

private final class LocationPermissionDelegate: NSObject, CLLocationManagerDelegate {
    private let completion: (CLAuthorizationStatus) -> Void
    private var didCallBack = false

    init(completion: @escaping (CLAuthorizationStatus) -> Void) {
        self.completion = completion
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !didCallBack, manager.authorizationStatus != .notDetermined else { return }
        didCallBack = true
        completion(manager.authorizationStatus)
    }
}
