import SwiftUI
import AppKit
import Foundation

extension TestsView {
    func qualityTone(_ quality: String) -> SomaStatusTone {
        switch quality {
        case "Best", "High": return .good
        case "Good": return .info
        case "Risk": return .warning
        case "Broken": return .danger
        default: return .neutral
        }
    }

    func speedTone(_ speed: String) -> SomaStatusTone {
        switch speed {
        case "Fast", "Fastest": return .good
        case "Balanced", "Medium": return .info
        case "Slow": return .warning
        default: return .neutral
        }
    }

    func openCasesInVSCode() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Visual Studio Code", casesURL.path]
        do {
            try process.run()
            statusText = "Opened \(casesURL.lastPathComponent) in VSCode"
        } catch {
            NSWorkspace.shared.open(casesURL)
            statusText = "Opened \(casesURL.lastPathComponent)"
        }
    }
}
