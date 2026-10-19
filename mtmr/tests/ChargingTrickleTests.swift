import Cocoa
import IOKit.ps

@main
struct ChargingTrickleTests {
    static func main() {
        let chargingBattery: [String: Any] = [kIOPSIsChargingKey: true, kIOPSCurrentCapacityKey: 49, kIOPSMaxCapacityKey: 100]
        precondition(ChargingMonitor.charging(connected: true, description: chargingBattery))
        precondition(!ChargingMonitor.charging(connected: false, description: chargingBattery))
        for capacity in [100, 101] {
            var fullBattery = chargingBattery
            fullBattery[kIOPSCurrentCapacityKey] = capacity
            precondition(!ChargingMonitor.charging(connected: true, description: fullBattery))
        }
        var heldBattery = chargingBattery
        heldBattery[kIOPSCurrentCapacityKey] = 80
        heldBattery[kIOPSIsChargingKey] = false
        precondition(ChargingMonitor.charging(connected: true, description: heldBattery))
        precondition(!ChargingMonitor.charging(connected: true, description: [:]))
        var invalidBattery = chargingBattery
        invalidBattery[kIOPSMaxCapacityKey] = 0
        precondition(!ChargingMonitor.charging(connected: true, description: invalidBattery))
        let scaledBattery: [String: Any] = [kIOPSIsChargingKey: true, kIOPSCurrentCapacityKey: 1500, kIOPSMaxCapacityKey: 2000]
        precondition(ChargingMonitor.charging(connected: true, description: scaledBattery))
        precondition(ParticleFlowView.defaultCount == 45)
        precondition(ParticleFlowView.defaultSeconds == 2.5)
        for _ in 0..<1000 {
            precondition((0.8...1.6).contains(ParticleFlowView.trickleInterval()))
            let timing = ParticleFlowView.burstTiming(spawnFraction: Double.random(in: 0...1), seconds: 2.5)
            precondition((0...0.6).contains(timing.delay))
            precondition((1.2...2).contains(timing.lifetime))
            precondition(timing.delay + timing.lifetime <= 2.5)
        }
        precondition(ParticleFlowView.canEmitTrickle(activeCount: 2))
        precondition(ParticleFlowView.canEmitTrickle(activeCount: 3))
        precondition(!ParticleFlowView.canEmitTrickle(activeCount: 4))
        print("Charging state, trickle intervals and in-flight limit checks passed")
    }
}
