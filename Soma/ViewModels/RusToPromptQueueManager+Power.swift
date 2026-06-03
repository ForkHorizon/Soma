import Combine
import Foundation
import IOKit.ps

extension RusToPromptQueuePowerSource {
    var label: String {
        switch self {
        case .externalPower:
            return "Adapter"
        case .battery:
            return "Battery"
        case .unknown:
            return "Power unknown"
        }
    }
}

extension RusToPromptQueueManager {
    var isBatteryBlockingQueue: Bool {
        powerSource == .battery && queuedCount > 0
    }


    var isBatteryBlockingActiveRun: Bool {
        powerSource == .battery
            && activeProcess != nil
            && batteryStartOverrideItemID != activeItemID
    }


    func refreshPowerSource() {
        let previous = powerSource
        refreshPowerSourceValue()
        if previous != powerSource {
            appendActivity("Power source changed: \(powerSource.label).")
        }
        applyPowerGate()
    }


    func refreshPowerSourceValue() {
        powerSource = Self.readPowerSource()
    }


    func applyPowerGate() {
        if powerSource == .battery {
            pauseActiveRunForBatteryIfNeeded()
        } else {
            resumePowerPausedRunIfNeeded()
        }
    }


    func canStartQueueOnCurrentPower(allowBatteryStart: Bool) -> Bool {
        powerSource != .battery || allowBatteryStart
    }


    func markWaitingForPower(index: Int) {
        guard items.indices.contains(index) else { return }
        let changed = items[index].status != .queued || items[index].statusMessage != "Waiting for power adapter"
        guard changed else { return }
        items[index].status = .queued
        items[index].statusMessage = "Waiting for power adapter"
        items[index].updatedAt = Date()
        saveToDisk()
        appendActivity("Queue waiting for power adapter.")
    }


    func pauseActiveRunForBatteryIfNeeded() {
        guard isBatteryBlockingActiveRun, !isPowerPaused, !isPaused else { return }
        isPowerPaused = true
        isPaused = true
        if let activeItemID, let index = items.firstIndex(where: { $0.id == activeItemID }) {
            items[index].statusMessage = "Paused on battery; connect power to continue"
            items[index].updatedAt = Date()
        }
        writeControl(["pause": true, "skip_cooldown": false, "stop": false])
        saveToDisk()
        appendActivity("Queue paused on battery power.")
    }


    func resumePowerPausedRunIfNeeded() {
        guard isPowerPaused else { return }
        isPowerPaused = false
        isPaused = false
        if let activeItemID, let index = items.firstIndex(where: { $0.id == activeItemID }) {
            items[index].statusMessage = "Running staged benchmark"
            items[index].updatedAt = Date()
        }
        writeControl(["pause": false, "skip_cooldown": false, "stop": false])
        saveToDisk()
        appendActivity("Adapter power restored; queue resumed.")
    }


    func allowActiveRunOnBatteryIfNeeded(_ allowBatteryStart: Bool) {
        guard allowBatteryStart, powerSource == .battery, let activeItemID else { return }
        batteryStartOverrideItemID = activeItemID
        isPowerPaused = false
        isPaused = false
        if let index = items.firstIndex(where: { $0.id == activeItemID }) {
            items[index].statusMessage = "Running staged benchmark"
            items[index].updatedAt = Date()
        }
        appendActivity("Manual battery override enabled for current run.")
    }


    nonisolated static func readPowerSource() -> RusToPromptQueuePowerSource {
        guard let infoRef = IOPSCopyPowerSourcesInfo() else {
            return .unknown
        }
        let info = infoRef.takeRetainedValue()
        guard let providingRef = IOPSGetProvidingPowerSourceType(info) else {
            return .unknown
        }
        let providing = providingRef.takeRetainedValue() as String
        if providing == kIOPSACPowerValue {
            return .externalPower
        }
        if providing == kIOPSBatteryPowerValue {
            return .battery
        }

        guard let sourcesRef = IOPSCopyPowerSourcesList(info) else {
            return .unknown
        }
        let sources = sourcesRef.takeRetainedValue() as NSArray
        if sources.count == 0 {
            return .externalPower
        }

        var sawBattery = false
        for source in sources {
            guard let descriptionRef = IOPSGetPowerSourceDescription(info, source as CFTypeRef),
                  let description = descriptionRef.takeUnretainedValue() as? [String: Any],
                  let state = description[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            if state == kIOPSACPowerValue {
                return .externalPower
            }
            if state == kIOPSBatteryPowerValue {
                sawBattery = true
            }
        }
        return sawBattery ? .battery : .unknown
    }
}
