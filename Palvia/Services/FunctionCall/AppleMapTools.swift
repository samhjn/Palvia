import Foundation
import MapKit

struct AppleMapTools {

    func searchPlaces(arguments: [String: Any]) async -> String {
        guard let query = arguments["query"] as? String else {
            return "[Error] Missing required parameter: query"
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        if let lat = arguments["latitude"] as? Double,
           let lon = arguments["longitude"] as? Double {
            let radius = (arguments["radius"] as? Double) ?? 5000
            let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            request.region = MKCoordinateRegion(
                center: center,
                latitudinalMeters: radius * 2,
                longitudinalMeters: radius * 2)
        } else if let nearMe = arguments["near_me"] as? Bool, nearMe {
            if let err = await ApplePermissionManager.shared.ensureLocationAccess() { return err }
            let timeout = max(10.0, min(60.0, arguments["timeout"] as? Double ?? 30.0))
            do {
                let loc = try await fetchWithFallback(timeout: timeout)
                let radius = (arguments["radius"] as? Double) ?? 5000
                request.region = MKCoordinateRegion(
                    center: loc.coordinate,
                    latitudinalMeters: radius * 2,
                    longitudinalMeters: radius * 2)
            } catch {
                return "[Error] Failed to get current location for nearby search: \(error.localizedDescription). Try providing latitude/longitude explicitly."
            }
        }

        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()

            if response.mapItems.isEmpty {
                return "(No places found for '\(query)')"
            }

            let limit = min(response.mapItems.count, 20)
            return response.mapItems.prefix(limit).enumerated().map { idx, item in
                var line = "\(idx + 1). **\(item.name ?? "(Unknown)")**"

                if let phone = item.phoneNumber, !phone.isEmpty {
                    line += " | Phone: \(phone)"
                }

                if let placemark = item.placemark as MKPlacemark? {
                    line += "\n   Address: \(formatPlacemark(placemark))"
                    line += "\n   Coordinates: \(placemark.coordinate.latitude), \(placemark.coordinate.longitude)"
                }

                if let url = item.url {
                    line += "\n   URL: \(url.absoluteString)"
                }

                if let category = item.pointOfInterestCategory?.rawValue {
                    line += "\n   Category: \(category)"
                }

                return line
            }.joined(separator: "\n\n")
        } catch {
            return "[Error] Search failed: \(error.localizedDescription)"
        }
    }

    func getDirections(arguments: [String: Any]) async -> String {
        let request = MKDirections.Request()

        if let fromLat = arguments["from_latitude"] as? Double,
           let fromLon = arguments["from_longitude"] as? Double {
            let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: fromLat, longitude: fromLon))
            request.source = MKMapItem(placemark: placemark)
        } else if let fromAddress = arguments["from_address"] as? String {
            if let item = await searchSinglePlace(fromAddress) {
                request.source = item
            } else {
                return "[Error] Could not find origin: '\(fromAddress)'"
            }
        } else {
            request.source = MKMapItem.forCurrentLocation()
        }

        if let toLat = arguments["to_latitude"] as? Double,
           let toLon = arguments["to_longitude"] as? Double {
            let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: toLat, longitude: toLon))
            request.destination = MKMapItem(placemark: placemark)
        } else if let toAddress = arguments["to_address"] as? String {
            if let item = await searchSinglePlace(toAddress) {
                request.destination = item
            } else {
                return "[Error] Could not find destination: '\(toAddress)'"
            }
        } else {
            return "[Error] Missing destination. Provide to_address or to_latitude/to_longitude."
        }

        let transport = arguments["transport"] as? String ?? "driving"
        switch transport.lowercased() {
        case "walking", "walk": request.transportType = .walking
        case "transit", "public": request.transportType = .transit
        default: request.transportType = .automobile
        }

        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()

            if response.routes.isEmpty {
                return "(No routes found)"
            }

            return response.routes.enumerated().map { idx, route in
                let distance = route.distance < 1000
                    ? String(format: "%.0fm", route.distance)
                    : String(format: "%.1fkm", route.distance / 1000)
                let time = formatDuration(route.expectedTravelTime)

                var line = "Route \(idx + 1): \(route.name)"
                line += "\n- Distance: \(distance)"
                line += "\n- Time: \(time)"
                line += "\n- Transport: \(transport)"

                if !route.steps.isEmpty {
                    let steps = route.steps.filter { !$0.instructions.isEmpty }
                    if !steps.isEmpty {
                        line += "\n- Steps:"
                        for (i, step) in steps.enumerated() {
                            let stepDist = step.distance < 1000
                                ? String(format: "%.0fm", step.distance)
                                : String(format: "%.1fkm", step.distance / 1000)
                            line += "\n  \(i + 1). \(step.instructions) (\(stepDist))"
                        }
                    }
                }

                return line
            }.joined(separator: "\n\n")
        } catch {
            return "[Error] Failed to get directions: \(error.localizedDescription)"
        }
    }

    // MARK: - Location Fetch with Fallback

    private func fetchWithFallback(timeout: TimeInterval) async throws -> CLLocation {
        guard CLLocationManager.locationServicesEnabled() else {
            throw CLError(.denied)
        }

        do {
            let location = try await fetchLiveLocation(timeout: timeout)
            LocationCache.shared.save(location)
            return location
        } catch {
            if let sys = await LocationCache.shared.systemCached() {
                LocationCache.shared.save(sys)
                return sys
            }
            if let cached = LocationCache.shared.lastKnown() {
                return cached
            }
            throw error
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
                throw CLError(.locationUnknown)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CLError(.locationUnknown)
            }

            guard let result = try await group.next() else {
                throw CLError(.locationUnknown)
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Helpers

    private func searchSinglePlace(_ query: String) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let search = MKLocalSearch(request: request)
        return try? await search.start().mapItems.first
    }

    private func formatPlacemark(_ pm: MKPlacemark) -> String {
        var parts: [String] = []
        if let sub = pm.subThoroughfare { parts.append(sub) }
        if let street = pm.thoroughfare { parts.append(street) }
        if let city = pm.locality { parts.append(city) }
        if let state = pm.administrativeArea { parts.append(state) }
        if let postal = pm.postalCode { parts.append(postal) }
        if let country = pm.country { parts.append(country) }
        return parts.joined(separator: ", ")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 {
            return "\(h)h \(m)min"
        }
        return "\(m)min"
    }
}
