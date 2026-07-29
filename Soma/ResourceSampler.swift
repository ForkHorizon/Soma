import Foundation
import Darwin

/// Lightweight in-process sampler. Writes this app's memory + CPU plus the
/// system swap/free-RAM picture to ~/.soma/logs/soma_resource.log on a timer and
/// on demand (recording start/stop, memory-pressure events), so a slowdown or a
/// force-quit can be diagnosed after the fact instead of guessed at.
///
/// Everything here is read in-process via Mach/sysctl — no subprocess spawn.
final class ResourceSampler {
    static let shared = ResourceSampler()

    private var timer: Timer?
    private let writeQueue = DispatchQueue(label: "soma.resource-sampler")
    private let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".soma/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("soma_resource.log")
    }()

    func start(interval: TimeInterval = 30) {
        guard timer == nil else { return }
        sample("start")
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample("tick") }
        RunLoop.main.add(t, forMode: .common)   // keep sampling even during UI tracking
        timer = t
    }

    /// Record an extra sample tagged with a reason (e.g. "record_start",
    /// "mem_pressure_critical"), so spikes line up with what the app was doing.
    func mark(_ reason: String) { sample(reason) }

    private func sample(_ reason: String) {
        let footprint = Self.footprintMB()
        let cpu = Self.cpuPercent()
        let threads = Self.threadCount()
        let swap = Self.swapUsage()
        let freeGB = Self.freeMemoryGB()
        let line = String(
            format: "%@  [%@] app: footprint=%.0fMB cpu=%.0f%% threads=%d | system: swap_used=%.0f/%.0fMB free=%.1fGB\n",
            Self.timestamp(), reason, footprint, cpu, threads, swap.usedMB, swap.totalMB, freeGB)
        writeQueue.async { [logURL] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    // MARK: - Metrics (all in-process, no subprocess)

    /// Real memory cost of THIS process (what shows up as pressure), in MB.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576.0
    }

    /// Instantaneous CPU% of this process (sum of non-idle threads).
    private static func cpuPercent() -> Double {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)) }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var tcount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(tcount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &tcount)
                }
            }
            if kr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    private static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }

    private static func swapUsage() -> (usedMB: Double, totalMB: Double) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Double(usage.xsu_used) / 1_048_576.0, Double(usage.xsu_total) / 1_048_576.0)
    }

    private static func freeMemoryGB() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pages = Double(stats.free_count) + Double(stats.inactive_count) + Double(stats.speculative_count)
        return pages * Double(vm_page_size) / 1_073_741_824.0
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
