import Darwin
import Foundation
import Observation

/// CPU, memory and disk readings for the menu bar panel. Samples only while the panel is open.
@MainActor @Observable
final class SystemStats {
    struct Memory: Equatable {
        var wired: UInt64 = 0, used: UInt64 = 0, compressed: UInt64 = 0, cache: UInt64 = 0, free: UInt64 = 0
        var total = ProcessInfo.processInfo.physicalMemory
        /// Wired + app memory + compressed: what macOS can't simply drop.
        var pressure: Double { total == 0 ? 0 : Double(wired + used + compressed) / Double(total) }
    }

    struct Disk: Equatable {
        var total: Int64 = 0, available: Int64 = 0
        var used: Int64 { max(0, total - available) }
        var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    private(set) var cpu: Double = 0
    private(set) var cpuUser: Double = 0
    private(set) var cpuSystem: Double = 0
    /// Recent CPU load, oldest first, for the bar graph.
    private(set) var cpuHistory: [Double] = []
    private(set) var memory = Memory()
    private(set) var disk = Disk()

    private(set) var model = SystemStats.sysctl("hw.model") ?? "Mac"
    private(set) var chip = SystemStats.sysctl("machdep.cpu.brand_string") ?? ""
    private(set) var cores = ProcessInfo.processInfo.activeProcessorCount
    private var demoUptime: TimeInterval?
    var uptime: TimeInterval { demoUptime ?? ProcessInfo.processInfo.systemUptime }

    static let historyLength = 40
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64)?
    private var timer: Task<Void, Never>?

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Task { [weak self] in
            var delay = Duration.milliseconds(500)  // CPU load needs two readings; show the first one quickly
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                self?.sample()
                delay = .seconds(2)
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func sample() {
        guard demoUptime == nil else { return }  // demo readings stay fixed
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks {
                let user = Double(ticks.user &- last.user), system = Double(ticks.system &- last.system)
                let total = user + system + Double(ticks.idle &- last.idle)
                if total > 0 {
                    cpuUser = user / total
                    cpuSystem = system / total
                    cpu = cpuUser + cpuSystem
                    cpuHistory = Array((cpuHistory + [cpu]).suffix(Self.historyLength))
                }
            }
            lastTicks = ticks
        }
        if let m = Self.memory() { memory = m }
        if let values = try? URL(filePath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            disk = Disk(total: Int64(values.volumeTotalCapacity ?? 0), available: values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
    }

    /// Made-up readings for `--snapshot <dir> demo`, so shared screenshots don't describe the Mac they were taken on.
    func fillDemo() {
        let gb: UInt64 = 1 << 30
        model = "Mac15,3"; chip = "Apple M3 Pro"; cores = 12; demoUptime = 3 * 86_400 + 5 * 3_600
        cpuUser = 0.14; cpuSystem = 0.05; cpu = cpuUser + cpuSystem
        cpuHistory = (0..<Self.historyLength).map { i in 0.12 + 0.1 * abs(sin(Double(i) / 3)) + (i % 9 == 4 ? 0.35 : 0) }
        memory = Memory(wired: 3 * gb, used: 7 * gb, compressed: 1 * gb, cache: 4 * gb, free: gb / 2, total: 18 * gb)
        disk = Disk(total: 494_000_000_000, available: 182_000_000_000)
    }

    /// Summed over all cores; nice time counts as user.
    private static func cpuTicks() -> (user: UInt64, system: UInt64, idle: UInt64)? {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS, let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0
        for i in 0..<Int(cpus) {
            let base = i * Int(CPU_STATE_MAX)
            user += UInt64(info[base + Int(CPU_STATE_USER)]) + UInt64(info[base + Int(CPU_STATE_NICE)])
            system += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
        }
        return (user, system, idle)
    }

    /// Same split as Activity Monitor: wired, app memory, compressed, cached files, free.
    private static func memory() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        return Memory(wired: UInt64(stats.wire_count) * page, used: app * page,
                      compressed: UInt64(stats.compressor_page_count) * page,
                      cache: (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page,
                      free: UInt64(stats.free_count) * page)
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
