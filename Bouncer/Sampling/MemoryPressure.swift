/// System-wide memory pressure derived from `vm_statistics64` page counts.
///
/// Computed each sample tick in `ProcessMonitor.sampleSystemRAM()` and
/// published as `ProcessMonitor.memoryPressure`.
enum MemoryPressure {
    /// More than 25 % of physical RAM is available (free + inactive + purgeable).
    case normal
    /// Available RAM is between 10 % and 25 % — approaching pressure.
    case warning
    /// Available RAM is 10 % or less — system is under heavy memory pressure.
    case critical
}
