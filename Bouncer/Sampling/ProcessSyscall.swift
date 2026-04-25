import Darwin

/// Lightweight wrapper around `libproc` syscalls.
///
/// All methods are entirely stack-allocated — no heap memory is used.
struct ProcessSyscall {

    /// Returns the parent process ID (PPID) of the given PID.
    ///
    /// Calls `proc_pidinfo` with the `PROC_PIDTBSDINFO` flavour, which fills a
    /// `proc_bsdinfo` struct on the caller's stack.  No heap allocation occurs.
    ///
    /// - Parameter pid: The process whose PPID you want.
    /// - Returns: The PPID, or `nil` if the call fails (process has already exited,
    ///   permission denied, etc.).
    static func getParentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard ret == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        let ppid = pid_t(info.pbi_ppid)
        return ppid > 0 ? ppid : nil
    }
}
