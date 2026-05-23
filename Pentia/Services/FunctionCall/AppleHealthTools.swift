import Foundation
import HealthKit

struct AppleHealthTools {
    private var store: HKHealthStore { ApplePermissionManager.shared.healthStore }
    private var pm: ApplePermissionManager { ApplePermissionManager.shared }

    private func ensureAccess() async -> String? { await pm.ensureHealthAccess() }

    private func checkWriteAuth(_ id: HKQuantityTypeIdentifier) -> String? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            return "[Error] This health data type is unavailable on this device."
        }
        if !pm.isHealthSharingAuthorized(for: type) {
            return "[Error] Write access denied for this data type. Please enable it in Settings > Health > Data Access & Devices > iClaw."
        }
        return nil
    }

    // MARK: - Read

    func readSteps(arguments: [String: Any]) async -> String {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            return "[Error] Step count type is unavailable on this device."
        }
        if let err = await ensureAccess() { return err }

        let (start, end) = resolveDateRange(arguments: arguments, defaultDays: 7)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, error in
                if let error {
                    continuation.resume(returning: "[Error] Failed to read steps: \(error.localizedDescription)")
                    return
                }
                let count = result?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: """
                Steps summary:
                - Range: \(formatDate(start)) to \(formatDate(end))
                - Total steps: \(Int(count))
                """)
            }
            store.execute(query)
        }
    }

    func readHeartRate(arguments: [String: Any]) async -> String {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return "[Error] Heart rate type is unavailable on this device."
        }
        if let err = await ensureAccess() { return err }

        let (start, end) = resolveDateRange(arguments: arguments, defaultDays: 1)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        do {
            let samples = try await fetchQuantitySamples(type: type, predicate: predicate, limit: 200)
            if samples.isEmpty {
                return "(No heart-rate samples found between \(formatDate(start)) and \(formatDate(end)))"
            }

            let unit = HKUnit.count().unitDivided(by: .minute())
            let values = samples.map { $0.quantity.doubleValue(for: unit) }
            let avg = values.reduce(0, +) / Double(values.count)
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 0

            return """
            Heart rate summary:
            - Range: \(formatDate(start)) to \(formatDate(end))
            - Samples: \(values.count)
            - Avg: \(String(format: "%.1f", avg)) bpm
            - Min: \(String(format: "%.0f", minV)) bpm
            - Max: \(String(format: "%.0f", maxV)) bpm
            """
        } catch {
            return "[Error] Failed to read heart rate: \(error.localizedDescription)"
        }
    }

    func readSleep(arguments: [String: Any]) async -> String {
        guard let type = HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) else {
            return "[Error] Sleep analysis type is unavailable on this device."
        }
        if let err = await ensureAccess() { return err }

        let (start, end) = resolveDateRange(arguments: arguments, defaultDays: 7)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        do {
            let samples = try await fetchCategorySamples(type: type, predicate: predicate, limit: 500)
            if samples.isEmpty {
                return "(No sleep samples found between \(formatDate(start)) and \(formatDate(end)))"
            }

            var totalSleepSeconds: TimeInterval = 0
            var totalInBedSeconds: TimeInterval = 0

            for sample in samples {
                let duration = sample.endDate.timeIntervalSince(sample.startDate)
                if isAsleepSample(sample.value) {
                    totalSleepSeconds += duration
                } else if sample.value == HKCategoryValueSleepAnalysis.inBed.rawValue {
                    totalInBedSeconds += duration
                }
            }

            return """
            Sleep summary:
            - Range: \(formatDate(start)) to \(formatDate(end))
            - Samples: \(samples.count)
            - Asleep: \(formatDuration(totalSleepSeconds))
            - In bed: \(formatDuration(totalInBedSeconds))
            """
        } catch {
            return "[Error] Failed to read sleep data: \(error.localizedDescription)"
        }
    }

    func readBodyMass(arguments: [String: Any]) async -> String {
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            return "[Error] Body mass type is unavailable on this device."
        }
        if let err = await ensureAccess() { return err }

        let (start, end) = resolveDateRange(arguments: arguments, defaultDays: 30)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        do {
            let samples = try await fetchQuantitySamples(type: type, predicate: predicate, limit: 50)
            if samples.isEmpty {
                return "(No body-mass samples found between \(formatDate(start)) and \(formatDate(end)))"
            }

            let unitLabel = (arguments["unit"] as? String)?.lowercased() ?? "kg"
            let unit: HKUnit = (unitLabel == "lb" || unitLabel == "lbs") ? .pound() : .gramUnit(with: .kilo)

            let rows = samples.prefix(20).map { sample in
                let v = sample.quantity.doubleValue(for: unit)
                return "- \(formatDate(sample.endDate)): \(String(format: "%.2f", v)) \(unitLabel == "lb" || unitLabel == "lbs" ? "lb" : "kg")"
            }.joined(separator: "\n")

            return """
            Body mass samples:
            - Range: \(formatDate(start)) to \(formatDate(end))
            - Count: \(samples.count)
            \(rows)
            """
        } catch {
            return "[Error] Failed to read body mass: \(error.localizedDescription)"
        }
    }

    func readBloodPressure(arguments: [String: Any]) async -> String {
        guard let sysType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diaType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
              let corrType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure) else {
            return "[Error] Blood pressure type is unavailable on this device."
        }
        if let err = await ensureAccess() { return err }

        let (start, end) = resolveDateRange(arguments: arguments, defaultDays: 30)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        do {
            let correlations = try await fetchCorrelationSamples(type: corrType, predicate: predicate, limit: 50)
            if correlations.isEmpty {
                return "(No blood pressure samples found between \(formatDate(start)) and \(formatDate(end)))"
            }

            let mmHg = HKUnit.millimeterOfMercury()
            let rows = correlations.prefix(20).map { corr -> String in
                let sys = corr.objects(for: sysType).first as? HKQuantitySample
                let dia = corr.objects(for: diaType).first as? HKQuantitySample
                let sVal = sys.map { Int($0.quantity.doubleValue(for: mmHg)) } ?? 0
                let dVal = dia.map { Int($0.quantity.doubleValue(for: mmHg)) } ?? 0
                return "- \(formatDate(corr.endDate)): \(sVal)/\(dVal) mmHg"
            }.joined(separator: "\n")

            return """
            Blood pressure samples:
            - Range: \(formatDate(start)) to \(formatDate(end))
            - Count: \(correlations.count)
            \(rows)
            """
        } catch {
            return "[Error] Failed to read blood pressure: \(error.localizedDescription)"
        }
    }

    func readBloodGlucose(arguments: [String: Any]) async -> String {
        await readSimpleQuantity(arguments: arguments, id: .bloodGlucose,
                                 unit: HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter()),
                                 unitLabel: "mmol/L", label: "Blood glucose", defaultDays: 30)
    }

    func readBloodOxygen(arguments: [String: Any]) async -> String {
        await readSimpleQuantity(arguments: arguments, id: .oxygenSaturation,
                                 unit: .percent(), unitLabel: "%", label: "Blood oxygen (SpO₂)", defaultDays: 7,
                                 valueTransform: { $0 * 100.0 }, valueFormat: "%.1f")
    }

    func readBodyTemperature(arguments: [String: Any]) async -> String {
        let useFahrenheit = (arguments["unit"] as? String)?.lowercased() == "f"
        let unit: HKUnit = useFahrenheit ? .degreeFahrenheit() : .degreeCelsius()
        let uLabel = useFahrenheit ? "°F" : "°C"
        return await readSimpleQuantity(arguments: arguments, id: .bodyTemperature,
                                         unit: unit, unitLabel: uLabel, label: "Body temperature", defaultDays: 30)
    }

    // MARK: - Write

    func writeDietaryEnergy(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.dietaryEnergyConsumed) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed) else {
            return "[Error] Dietary energy type is unavailable on this device."
        }

        guard let kcal = (arguments["kcal"] as? Double) ?? (arguments["energy_kcal"] as? Double) else {
            return "[Error] Missing required parameter: kcal"
        }
        if kcal <= 0 { return "[Error] kcal must be a positive number." }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let end = when
        let start = Calendar.current.date(byAdding: .minute, value: -1, to: end) ?? end
        let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)

        var metadata: [String: Any] = [:]
        if let meal = arguments["meal"] as? String, !meal.isEmpty { metadata[HKMetadataKeyFoodType] = meal }
        if let note = arguments["note"] as? String, !note.isEmpty { metadata["iClawNote"] = note }

        let sample = HKQuantitySample(type: type, quantity: quantity, start: start, end: end, metadata: metadata.isEmpty ? nil : metadata)

        do {
            try await saveSample(sample)
            return "Dietary energy written successfully.\n- Energy: \(String(format: "%.1f", kcal)) kcal\n- Date: \(formatDate(end))"
        } catch {
            return "[Error] Failed to write dietary energy: \(error.localizedDescription)"
        }
    }

    func writeBodyMass(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.bodyMass) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyMass) else {
            return "[Error] Body mass type is unavailable on this device."
        }

        guard let value = arguments["value"] as? Double, value > 0 else {
            return "[Error] Missing or invalid parameter: value (must be positive)"
        }

        let unitLabel = (arguments["unit"] as? String)?.lowercased() ?? "kg"
        let unit: HKUnit = (unitLabel == "lb" || unitLabel == "lbs") ? .pound() : .gramUnit(with: .kilo)
        let displayUnit = (unitLabel == "lb" || unitLabel == "lbs") ? "lb" : "kg"

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Body mass written successfully.\n- Value: \(String(format: "%.2f", value)) \(displayUnit)\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write body mass: \(error.localizedDescription)"
        }
    }

    func writeDietaryWater(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.dietaryWater) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .dietaryWater) else {
            return "[Error] Dietary water type is unavailable on this device."
        }

        guard let ml = (arguments["ml"] as? Double) ?? (arguments["value"] as? Double), ml > 0 else {
            return "[Error] Missing or invalid parameter: ml (must be positive)"
        }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: ml), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Dietary water written successfully.\n- Water: \(String(format: "%.0f", ml)) ml\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write dietary water: \(error.localizedDescription)"
        }
    }

    func writeDietaryCarbohydrates(arguments: [String: Any]) async -> String {
        await writeNutrient(arguments: arguments, id: .dietaryCarbohydrates, gramsKey: "grams", defaultLabel: "carbohydrates")
    }

    func writeDietaryProtein(arguments: [String: Any]) async -> String {
        await writeNutrient(arguments: arguments, id: .dietaryProtein, gramsKey: "grams", defaultLabel: "protein")
    }

    func writeDietaryFat(arguments: [String: Any]) async -> String {
        await writeNutrient(arguments: arguments, id: .dietaryFatTotal, gramsKey: "grams", defaultLabel: "fat")
    }

    func writeBloodPressure(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.bloodPressureSystolic) { return err }
        guard let sysType = HKQuantityType.quantityType(forIdentifier: .bloodPressureSystolic),
              let diaType = HKQuantityType.quantityType(forIdentifier: .bloodPressureDiastolic),
              let corrType = HKCorrelationType.correlationType(forIdentifier: .bloodPressure) else {
            return "[Error] Blood pressure type is unavailable on this device."
        }

        guard let systolic = (arguments["systolic"] as? Double) ?? (arguments["sys"] as? Double),
              let diastolic = (arguments["diastolic"] as? Double) ?? (arguments["dia"] as? Double) else {
            return "[Error] Missing required parameters: systolic and diastolic"
        }
        if systolic <= 0 || diastolic <= 0 { return "[Error] Values must be positive." }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let mmHg = HKUnit.millimeterOfMercury()
        let sysSample = HKQuantitySample(type: sysType, quantity: HKQuantity(unit: mmHg, doubleValue: systolic), start: when, end: when)
        let diaSample = HKQuantitySample(type: diaType, quantity: HKQuantity(unit: mmHg, doubleValue: diastolic), start: when, end: when)
        let correlation = HKCorrelation(type: corrType, start: when, end: when, objects: [sysSample, diaSample])

        do {
            try await saveSample(correlation)
            return "Blood pressure written successfully.\n- Value: \(Int(systolic))/\(Int(diastolic)) mmHg\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write blood pressure: \(error.localizedDescription)"
        }
    }

    func writeBodyFat(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.bodyFatPercentage) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage) else {
            return "[Error] Body fat percentage type is unavailable on this device."
        }

        guard let pct = (arguments["percentage"] as? Double) ?? (arguments["value"] as? Double), pct > 0 else {
            return "[Error] Missing or invalid parameter: percentage (must be positive)"
        }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .percent(), doubleValue: pct / 100.0), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Body fat percentage written successfully.\n- Value: \(String(format: "%.1f", pct))%\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write body fat: \(error.localizedDescription)"
        }
    }

    func writeHeight(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.height) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .height) else {
            return "[Error] Height type is unavailable on this device."
        }

        guard let value = arguments["value"] as? Double, value > 0 else {
            return "[Error] Missing or invalid parameter: value (must be positive)"
        }

        let unitLabel = (arguments["unit"] as? String)?.lowercased() ?? "cm"
        let unit: HKUnit
        let displayUnit: String
        switch unitLabel {
        case "m": unit = .meter(); displayUnit = "m"
        case "in", "inch": unit = .inch(); displayUnit = "in"
        case "ft", "foot": unit = .foot(); displayUnit = "ft"
        default: unit = .meterUnit(with: .centi); displayUnit = "cm"
        }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Height written successfully.\n- Value: \(String(format: "%.1f", value)) \(displayUnit)\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write height: \(error.localizedDescription)"
        }
    }

    func writeBloodGlucose(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.bloodGlucose) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .bloodGlucose) else {
            return "[Error] Blood glucose type is unavailable on this device."
        }

        guard let value = arguments["value"] as? Double, value > 0 else {
            return "[Error] Missing or invalid parameter: value (must be positive)"
        }

        let unitLabel = (arguments["unit"] as? String)?.lowercased() ?? "mmol/l"
        let unit: HKUnit
        let displayUnit: String
        if unitLabel == "mg/dl" || unitLabel == "mg" {
            unit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
            displayUnit = "mg/dL"
        } else {
            unit = HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitDivided(by: .liter())
            displayUnit = "mmol/L"
        }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Blood glucose written successfully.\n- Value: \(String(format: "%.2f", value)) \(displayUnit)\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write blood glucose: \(error.localizedDescription)"
        }
    }

    func writeBloodOxygen(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.oxygenSaturation) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) else {
            return "[Error] Blood oxygen type is unavailable on this device."
        }

        guard let pct = (arguments["percentage"] as? Double) ?? (arguments["value"] as? Double), pct > 0 else {
            return "[Error] Missing or invalid parameter: percentage (must be positive, e.g. 98)"
        }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .percent(), doubleValue: pct / 100.0), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Blood oxygen written successfully.\n- SpO₂: \(String(format: "%.1f", pct))%\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write blood oxygen: \(error.localizedDescription)"
        }
    }

    func writeBodyTemperature(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.bodyTemperature) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .bodyTemperature) else {
            return "[Error] Body temperature type is unavailable on this device."
        }

        guard let value = arguments["value"] as? Double, value > 0 else {
            return "[Error] Missing or invalid parameter: value (must be positive)"
        }

        let unitLabel = (arguments["unit"] as? String)?.lowercased() ?? "c"
        let unit: HKUnit = (unitLabel == "f" || unitLabel == "fahrenheit") ? .degreeFahrenheit() : .degreeCelsius()
        let displayUnit = (unitLabel == "f" || unitLabel == "fahrenheit") ? "°F" : "°C"

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Body temperature written successfully.\n- Value: \(String(format: "%.1f", value)) \(displayUnit)\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write body temperature: \(error.localizedDescription)"
        }
    }

    func writeHeartRate(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(.heartRate) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            return "[Error] Heart rate type is unavailable on this device."
        }

        guard let bpm = (arguments["bpm"] as? Double) ?? (arguments["value"] as? Double), bpm > 0 else {
            return "[Error] Missing or invalid parameter: bpm (must be positive)"
        }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: bpmUnit, doubleValue: bpm), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Heart rate written successfully.\n- Value: \(Int(bpm)) bpm\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write heart rate: \(error.localizedDescription)"
        }
    }

    func writeWorkout(arguments: [String: Any]) async -> String {
        if let err = await ensureAccess() { return err }

        guard let start = parseDate(arguments["start_date"] as? String) else {
            return "[Error] Missing or invalid start_date. Use ISO 8601 or yyyy-MM-dd HH:mm."
        }
        let end = parseDate(arguments["end_date"] as? String) ?? Date()
        if end <= start { return "[Error] end_date must be later than start_date." }

        let activity = parseWorkoutActivity(arguments["activity_type"] as? String)
        let kcal = arguments["energy_kcal"] as? Double
        let distanceKm = arguments["distance_km"] as? Double

        do {
            let config = HKWorkoutConfiguration()
            config.activityType = activity
            config.locationType = .unknown

            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
            try await beginCollection(builder: builder, at: start)

            var samples: [HKSample] = []
            if let kcal,
               let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                samples.append(HKQuantitySample(type: energyType, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: start, end: end))
            }
            if let distanceKm,
               let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
                samples.append(HKQuantitySample(type: distanceType, quantity: HKQuantity(unit: .meter(), doubleValue: distanceKm * 1000.0), start: start, end: end))
            }
            if !samples.isEmpty {
                try await addSamples(samples, to: builder)
            }

            try await endCollection(builder: builder, at: end)
            _ = try await finishWorkout(builder: builder)

            var lines = [
                "Workout written successfully.",
                "- Activity: \(activity.name)",
                "- Start: \(formatDate(start))",
                "- End: \(formatDate(end))"
            ]
            if let kcal { lines.append("- Energy: \(String(format: "%.1f", kcal)) kcal") }
            if let distanceKm { lines.append("- Distance: \(String(format: "%.2f", distanceKm)) km") }
            return lines.joined(separator: "\n")
        } catch {
            return "[Error] Failed to write workout: \(error.localizedDescription)"
        }
    }

    // MARK: - Generic Read Helper

    private func readSimpleQuantity(
        arguments: [String: Any],
        id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        unitLabel: String,
        label: String,
        defaultDays: Int,
        valueTransform: ((Double) -> Double)? = nil,
        valueFormat: String = "%.2f"
    ) async -> String {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            return "[Error] \(label) type is unavailable on this device."
        }
        if let err = await ensureAccess() { return err }

        let (start, end) = resolveDateRange(arguments: arguments, defaultDays: defaultDays)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        do {
            let samples = try await fetchQuantitySamples(type: type, predicate: predicate, limit: 50)
            if samples.isEmpty {
                return "(No \(label.lowercased()) samples found between \(formatDate(start)) and \(formatDate(end)))"
            }

            let rows = samples.prefix(20).map { sample in
                var v = sample.quantity.doubleValue(for: unit)
                if let t = valueTransform { v = t(v) }
                return "- \(formatDate(sample.endDate)): \(String(format: valueFormat, v)) \(unitLabel)"
            }.joined(separator: "\n")

            return """
            \(label) samples:
            - Range: \(formatDate(start)) to \(formatDate(end))
            - Count: \(samples.count)
            \(rows)
            """
        } catch {
            return "[Error] Failed to read \(label.lowercased()): \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func fetchCorrelationSamples(type: HKCorrelationType, predicate: NSPredicate?, limit: Int) async throws -> [HKCorrelation] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKCorrelation]) ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchQuantitySamples(type: HKQuantityType, predicate: NSPredicate?, limit: Int) async throws -> [HKQuantitySample] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchCategorySamples(type: HKCategoryType, predicate: NSPredicate?, limit: Int) async throws -> [HKCategorySample] {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
    }

    private func saveSample(_ sample: HKSample) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(sample) { ok, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if ok {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AppleHealthTools",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown save failure"]
                    ))
                }
            }
        }
    }

    private func beginCollection(builder: HKWorkoutBuilder, at start: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: start) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AppleHealthTools",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to begin workout collection"]
                    ))
                }
            }
        }
    }

    private func addSamples(_ samples: [HKSample], to builder: HKWorkoutBuilder) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.add(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AppleHealthTools",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to add workout samples"]
                    ))
                }
            }
        }
    }

    private func endCollection(builder: HKWorkoutBuilder, at end: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: end) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AppleHealthTools",
                        code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to end workout collection"]
                    ))
                }
            }
        }
    }

    private func finishWorkout(builder: HKWorkoutBuilder) async throws -> HKWorkout {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKWorkout, Error>) in
            builder.finishWorkout { workout, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let workout {
                    continuation.resume(returning: workout)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "AppleHealthTools",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to finish workout"]
                    ))
                }
            }
        }
    }

    private func writeNutrient(
        arguments: [String: Any],
        id: HKQuantityTypeIdentifier,
        gramsKey: String,
        defaultLabel: String
    ) async -> String {
        if let err = await ensureAccess() { return err }
        if let err = checkWriteAuth(id) { return err }
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else {
            return "[Error] \(defaultLabel.capitalized) type is unavailable on this device."
        }

        guard let grams = (arguments[gramsKey] as? Double) ?? (arguments["value"] as? Double), grams > 0 else {
            return "[Error] Missing or invalid parameter: \(gramsKey) (must be positive)"
        }

        let when = parseDate(arguments["date"] as? String) ?? Date()
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .gram(), doubleValue: grams), start: when, end: when)

        do {
            try await saveSample(sample)
            return "Dietary \(defaultLabel) written successfully.\n- \(defaultLabel.capitalized): \(String(format: "%.1f", grams)) g\n- Date: \(formatDate(when))"
        } catch {
            return "[Error] Failed to write dietary \(defaultLabel): \(error.localizedDescription)"
        }
    }

    private func resolveDateRange(arguments: [String: Any], defaultDays: Int) -> (Date, Date) {
        let end = parseDate(arguments["end_date"] as? String) ?? Date()
        if let start = parseDate(arguments["start_date"] as? String) {
            return (start, end)
        }
        let start = Calendar.current.date(byAdding: .day, value: -defaultDays, to: end) ?? end
        return (start, end)
    }

    private func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formats = ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return ISO8601DateFormatter().date(from: text)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h)h \(m)m"
    }

    private func isAsleepSample(_ value: Int) -> Bool {
        if value == HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue { return true }
        if #available(iOS 16.0, *) {
            return value == HKCategoryValueSleepAnalysis.asleepCore.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepDeep.rawValue
                || value == HKCategoryValueSleepAnalysis.asleepREM.rawValue
        }
        return false
    }

    private func parseWorkoutActivity(_ raw: String?) -> HKWorkoutActivityType {
        guard let raw else { return .other }
        switch raw.lowercased() {
        case "running", "run": return .running
        case "walking", "walk": return .walking
        case "cycling", "bike": return .cycling
        case "swimming", "swim": return .swimming
        case "hiking", "hike": return .hiking
        case "yoga": return .yoga
        case "functional_strength_training", "strength", "weights": return .functionalStrengthTraining
        case "traditional_strength_training": return .traditionalStrengthTraining
        case "high_intensity_interval_training", "hiit": return .highIntensityIntervalTraining
        case "elliptical": return .elliptical
        case "rowing": return .rowing
        case "stair_climbing", "stairs": return .stairClimbing
        case "mixed_cardio", "cardio": return .mixedCardio
        default: return .other
        }
    }
}

private extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .traditionalStrengthTraining: return "traditional_strength_training"
        case .highIntensityIntervalTraining: return "high_intensity_interval_training"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stair_climbing"
        case .mixedCardio: return "mixed_cardio"
        default: return "other"
        }
    }
}
