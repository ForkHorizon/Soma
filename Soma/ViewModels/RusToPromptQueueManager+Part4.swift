import Combine
import Foundation
extension RusToPromptQueueManager {
    /// Free RAM (free + inactive + speculative pages) read in-process via Mach.
    /// Replaces spawning a `/usr/bin/vm_stat` subprocess every 5s — same numbers,
    /// no per-tick process spawn or transient allocation.
    nonisolated static func readFreeMemoryGB() async -> Double? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = Double(stats.free_count) + Double(stats.inactive_count) + Double(stats.speculative_count)
        return pages > 0 ? pages * Double(vm_page_size) / 1_073_741_824.0 : nil
    }
}
