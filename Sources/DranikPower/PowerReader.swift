import Foundation
import IOKit

public enum PowerReaderError: Error, CustomStringConvertible {
    case serviceNotFound
    case propertiesUnavailable(kern_return_t)
    case missingProperty(String)

    public var description: String {
        switch self {
        case .serviceNotFound:
            return "AppleSmartBattery service not found (no battery?)"
        case .propertiesUnavailable(let code):
            return String(format: "IORegistryEntryCreateCFProperties failed: 0x%08x", UInt32(bitPattern: code))
        case .missingProperty(let name):
            return "AppleSmartBattery has no property '\(name)'"
        }
    }
}

/// Reads battery state from the public `AppleSmartBattery` IO registry entry.
///
/// Requires no privileges and no private API, which is why user-facing telemetry
/// comes from here rather than from equivalent SMC keys.
public enum PowerReader {
    public static func snapshot() throws -> BatterySnapshot {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else {
            throw PowerReaderError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard result == kIOReturnSuccess, let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
            throw PowerReaderError.propertiesUnavailable(result)
        }

        let charger = properties["ChargerData"] as? [String: Any] ?? [:]

        // TimeRemaining is 65535 while macOS is still estimating.
        let rawTimeRemaining = properties["TimeRemaining"] as? Int
        let timeRemaining = (rawTimeRemaining == 65535) ? nil : rawTimeRemaining

        return BatterySnapshot(
            percentage: try require(properties, "CurrentCapacity"),
            isCharging: properties["IsCharging"] as? Bool ?? false,
            isExternalConnected: properties["ExternalConnected"] as? Bool ?? false,
            isFullyCharged: properties["FullyCharged"] as? Bool ?? false,
            rawCurrentCapacity: properties["AppleRawCurrentCapacity"] as? Int ?? 0,
            rawMaxCapacity: properties["AppleRawMaxCapacity"] as? Int ?? 0,
            designCapacity: properties["DesignCapacity"] as? Int ?? 0,
            cycleCount: properties["CycleCount"] as? Int ?? 0,
            // Reported in hundredths of a degree Celsius.
            temperature: Double(properties["Temperature"] as? Int ?? 0) / 100,
            voltage: properties["Voltage"] as? Int ?? 0,
            amperage: properties["Amperage"] as? Int ?? 0,
            timeRemaining: timeRemaining,
            notChargingReason: (charger["NotChargingReason"] as? Int).map(NotChargingReason.init),
            chargerInhibitReason: charger["ChargerInhibitReason"] as? Int,
            chargingCurrent: charger["ChargingCurrent"] as? Int,
            chargingVoltage: charger["ChargingVoltage"] as? Int
        )
    }

    private static func require(_ properties: [String: Any], _ name: String) throws -> Int {
        guard let value = properties[name] as? Int else {
            throw PowerReaderError.missingProperty(name)
        }
        return value
    }
}
