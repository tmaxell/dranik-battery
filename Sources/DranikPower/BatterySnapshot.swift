import Foundation

/// One reading of the battery, taken from `AppleSmartBattery`.
public struct BatterySnapshot: Equatable, Sendable {
    /// Charge percentage as macOS reports it in the menu bar.
    ///
    /// On Apple Silicon `CurrentCapacity` is already a percentage and
    /// `MaxCapacity` is normalised to 100, so `CurrentCapacity / MaxCapacity`
    /// is not the health figure it looks like. Use `healthFraction` for that.
    ///
    /// This is **not** derivable from any capacity pair macOS exposes. Measured
    /// against `AppleRawCurrentCapacity / AppleRawMaxCapacity` the offset was
    /// +1.0 points on one reading and +5.1 on another; `NominalChargeCapacity`
    /// is +7.4 off and `DesignCapacity` +11.4. macOS applies its own smoothing
    /// and the gap moves with charge history, so no flag or denominator
    /// reproduces it.
    ///
    /// A charge limit must therefore be compared against this number rather than
    /// against anything computed from raw capacity — this is the figure the user
    /// sees and sets the limit against.
    public let percentage: Int
    public let isCharging: Bool
    public let isExternalConnected: Bool
    public let isFullyCharged: Bool

    /// Present capacity in mAh.
    public let rawCurrentCapacity: Int
    /// Full-charge capacity in mAh — the numerator of battery health.
    public let rawMaxCapacity: Int
    /// Factory capacity in mAh — the denominator of battery health.
    public let designCapacity: Int
    public let cycleCount: Int

    /// Degrees Celsius.
    public let temperature: Double
    /// Pack voltage in mV.
    public let voltage: Int
    /// Pack current in mA; negative while discharging.
    public let amperage: Int
    /// Minutes until full or empty; `nil` when macOS is still estimating.
    public let timeRemaining: Int?

    /// Non-zero when the charger is deliberately not charging.
    ///
    /// This is the hardware's own account of why charging stopped, which is why
    /// it is worth reading even though nothing here writes to the SMC yet: it is
    /// the independent confirmation that a future charge-gate write took effect.
    public let notChargingReason: Int?
    public let chargerInhibitReason: Int?
    public let chargingCurrent: Int?
    public let chargingVoltage: Int?

    public init(
        percentage: Int,
        isCharging: Bool,
        isExternalConnected: Bool,
        isFullyCharged: Bool,
        rawCurrentCapacity: Int,
        rawMaxCapacity: Int,
        designCapacity: Int,
        cycleCount: Int,
        temperature: Double,
        voltage: Int,
        amperage: Int,
        timeRemaining: Int?,
        notChargingReason: Int?,
        chargerInhibitReason: Int?,
        chargingCurrent: Int?,
        chargingVoltage: Int?
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isExternalConnected = isExternalConnected
        self.isFullyCharged = isFullyCharged
        self.rawCurrentCapacity = rawCurrentCapacity
        self.rawMaxCapacity = rawMaxCapacity
        self.designCapacity = designCapacity
        self.cycleCount = cycleCount
        self.temperature = temperature
        self.voltage = voltage
        self.amperage = amperage
        self.timeRemaining = timeRemaining
        self.notChargingReason = notChargingReason
        self.chargerInhibitReason = chargerInhibitReason
        self.chargingCurrent = chargingCurrent
        self.chargingVoltage = chargingVoltage
    }

    /// Full-charge capacity as a fraction of design capacity, 0...1.
    ///
    /// `nil` if design capacity is missing, rather than a fabricated 100 %.
    public var healthFraction: Double? {
        guard designCapacity > 0 else { return nil }
        return Double(rawMaxCapacity) / Double(designCapacity)
    }

    /// Instantaneous pack power in watts; negative while discharging.
    public var powerWatts: Double {
        Double(voltage) * Double(amperage) / 1_000_000
    }
}
