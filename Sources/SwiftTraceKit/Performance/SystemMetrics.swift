//
//  SystemMetrics.swift
//  SwiftTraceKit
//
//  Low level readings from the Mach kernel. These are the same numbers Xcode's
//  debug gauges show, read from inside the process.
//

import Foundation
import Darwin
import os

enum SystemMetrics {

    /// Memory footprint in bytes.
    ///
    /// `phys_footprint` is the value iOS uses to enforce the per-app memory
    /// limit (and what Xcode's memory gauge displays), so it is the right
    /// number to watch. `resident_size` would overstate usage because it
    /// includes shared pages.
    static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Bytes the app can still allocate before iOS terminates it.
    ///
    /// Returns 0 on the simulator and on macOS, where no per-app limit is
    /// enforced; callers treat 0 as "unknown".
    static func availableMemory() -> UInt64 {
        UInt64(os_proc_available_memory())
    }

    /// CPU usage of the whole process, as a percentage of one core.
    ///
    /// The value is the sum over all non-idle threads, so it can exceed 100 on
    /// multi-core devices (two busy threads read as about 200).
    static func cpuUsage() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return nil }

        defer {
            // task_threads allocates the array in our address space; it must be
            // released explicitly or every sample would leak a little memory.
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
        }

        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            // Each thread_t is a port right owned by us after task_threads.
            mach_port_deallocate(mach_task_self_, threadList[index])

            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }
}
