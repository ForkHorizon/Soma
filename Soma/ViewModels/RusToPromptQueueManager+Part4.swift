import Combine
import Foundation
extension RusToPromptQueueManager {
    nonisolated static func readFreeMemoryGB() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let pageSize = 16_384.0
            let keys = ["Pages free", "Pages inactive", "Pages speculative"]
            var pages = 0.0
            for line in text.components(separatedBy: .newlines) {
                for key in keys where line.hasPrefix(key) {
                    let digits = line
                        .replacingOccurrences(of: ".", with: "")
                        .components(separatedBy: CharacterSet.decimalDigits.inverted)
                        .filter { !$0.isEmpty }
                    if let value = digits.first.flatMap(Double.init) {
                        pages += value
                    }
                }
            }
            return pages > 0 ? (pages * pageSize / 1_073_741_824.0) : nil
        } catch {
            return nil
        }
    }
}
