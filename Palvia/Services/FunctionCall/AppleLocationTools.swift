import Foundation
import CoreLocation

// MARK: - Shared Location Cache

final class LocationCache: @unchecked Sendable {
    static let shared = LocationCache()

    private let queue = DispatchQueue(label: "com.iclaw.location-cache")
    private var _cachedLocation: CLLocation?
    private let maxAge: TimeInterval = 600 // 10 minutes

    func save(_ location: CLLocation) {
        queue.sync { _cachedLocation = location }
    }

    func lastKnown() -> CLLocation? {
        queue.sync {
            guard let loc = _cachedLocation,
                  abs(loc.timestamp.timeIntervalSinceNow) < maxAge else { return nil }
            return loc
        }
    }

    /// System-cached location from CLLocationManager (often available after recent GPS use)
    @MainActor
    func systemCached() -> CLLocation? {
        let mgr = CLLocationManager()
        guard let loc = mgr.location,
              abs(loc.timestamp.timeIntervalSinceNow) < maxAge else { return nil }
        return loc
    }
}

// MARK: - Location Result

enum LocationSource {
    case live
    case systemCache
    case appCache
}

struct LocatedResult {
    let location: CLLocation
    let source: LocationSource
}

struct AppleLocationTools {

    func getCurrentLocation(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureLocationAccess() { return err }

        let timeout = max(10.0, min(60.0, arguments["timeout"] as? Double ?? 30.0))
        do {
            let result = try await fetchWithFallback(timeout: timeout)
            var lines = [
                "Current Location:",
                "- Latitude: \(result.location.coordinate.latitude)",
                "- Longitude: \(result.location.coordinate.longitude)",
                "- Altitude: \(String(format: "%.1f", result.location.altitude))m",
                "- Accuracy: \(String(format: "%.1f", result.location.horizontalAccuracy))m",
            ]

            switch result.source {
            case .live: break
            case .systemCache:
                let age = Int(abs(result.location.timestamp.timeIntervalSinceNow))
                lines.append("- Source: system cached location (\(age)s ago)")
            case .appCache:
                let age = Int(abs(result.location.timestamp.timeIntervalSinceNow))
                lines.append("- Source: app cached location (\(age)s ago, approximate)")
            }

            let includeAddress = (arguments["include_address"] as? Bool) ?? true
            if includeAddress {
                let geocoder = CLGeocoder()
                if let placemark = try? await geocoder.reverseGeocodeLocation(result.location).first {
                    lines.append("- Address: \(formatPlacemark(placemark))")
                }
            }

            return lines.joined(separator: "\n")
        } catch LocationFetchError.servicesDisabled {
            return "[Error] Location Services are disabled system-wide. Please enable them in Settings > Privacy & Security > Location Services."
        } catch LocationFetchError.timeout {
            return "[Error] Location request timed out and no cached location available. Please ensure GPS is enabled and try again in an open area."
        } catch let clError as CLError where clError.code == .denied {
            return "[Error] Location access denied. Please enable it in Settings > Privacy > Location Services."
        } catch {
            return "[Error] Failed to get location: \(error.localizedDescription)"
        }
    }

    func geocode(arguments: [String: Any]) async -> String {
        guard let address = arguments["address"] as? String else {
            return "[Error] Missing required parameter: address"
        }

        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(address)
            if placemarks.isEmpty {
                return "(No results found for '\(address)')"
            }

            return placemarks.prefix(5).map { pm in
                var line = "- \(formatPlacemark(pm))"
                if let loc = pm.location {
                    line += "\n  Coordinates: \(loc.coordinate.latitude), \(loc.coordinate.longitude)"
                }
                return line
            }.joined(separator: "\n")
        } catch {
            return "[Error] Geocoding failed: \(error.localizedDescription)"
        }
    }

    func reverseGeocode(arguments: [String: Any]) async -> String {
        guard let lat = arguments["latitude"] as? Double else {
            return "[Error] Missing required parameter: latitude"
        }
        guard let lon = arguments["longitude"] as? Double else {
            return "[Error] Missing required parameter: longitude"
        }

        let location = CLLocation(latitude: lat, longitude: lon)
        let geocoder = CLGeocoder()

        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            if placemarks.isEmpty {
                return "(No address found for coordinates \(lat), \(lon))"
            }

            return placemarks.prefix(3).map { pm in
                "- \(formatPlacemark(pm))"
            }.joined(separator: "\n")
        } catch {
            return "[Error] Reverse geocoding failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Location Fetch with Fallback

    private func fetchWithFallback(timeout: TimeInterval) async throws -> LocatedResult {
        guard CLLocationManager.locationServicesEnabled() else {
            throw LocationFetchError.servicesDisabled
        }

        do {
            let location = try await fetchLiveLocation(timeout: timeout)
            LocationCache.shared.save(location)
            return LocatedResult(location: location, source: .live)
        } catch {
            if let sys = await LocationCache.shared.systemCached() {
                LocationCache.shared.save(sys)
                return LocatedResult(location: sys, source: .systemCache)
            }
            if let cached = LocationCache.shared.lastKnown() {
                return LocatedResult(location: cached, source: .appCache)
            }
            throw LocationFetchError.timeout
        }
    }

    private func fetchLiveLocation(timeout: TimeInterval) async throws -> CLLocation {
        try await withThrowingTaskGroup(of: CLLocation.self) { group in
            group.addTask {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let location = update.location {
                        return location
                    }
                }
                throw LocationFetchError.noLocation
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw LocationFetchError.timeout
            }

            guard let result = try await group.next() else {
                throw LocationFetchError.noLocation
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Helpers

    private func formatPlacemark(_ pm: CLPlacemark) -> String {
        var parts: [String] = []
        if let name = pm.name { parts.append(name) }
        if let thoroughfare = pm.thoroughfare {
            var street = thoroughfare
            if let sub = pm.subThoroughfare { street = sub + " " + street }
            if !parts.contains(street) { parts.append(street) }
        }
        if let locality = pm.locality, !parts.contains(locality) { parts.append(locality) }
        if let admin = pm.administrativeArea { parts.append(admin) }
        if let postal = pm.postalCode { parts.append(postal) }
        if let country = pm.country { parts.append(country) }
        return parts.joined(separator: ", ")
    }
}

private enum LocationFetchError: Error {
    case timeout
    case servicesDisabled
    case noLocation
}
