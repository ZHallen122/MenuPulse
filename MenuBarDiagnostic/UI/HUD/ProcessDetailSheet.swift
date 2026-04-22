import SwiftUI
import AppKit
import Darwin

struct ProcessDetailSheet: View {
    let process: MenuBarProcess
    @Environment(\.dismiss) var dismiss
    @State private var openFileCount: Int? = nil

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 12) {
                if let icon = process.icon {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                }
                VStack(alignment: .leading) {
                    Text(process.name).font(.title2.bold())
                    Text("PID: \(process.pid)").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            Divider()
            // Stats grid
            VStack(alignment: .leading, spacing: 8) {
                if let date = process.launchDate {
                    LabeledContent("Launch Time", value: date, format: .dateTime.hour().minute().second())
                }
                LabeledContent("CPU", value: process.cpuString)
                LabeledContent("RAM", value: process.memoryString)
                if let fds = openFileCount {
                    LabeledContent("Open Files", value: "\(fds)")
                } else {
                    LabeledContent("Open Files", value: "loading…")
                }
            }
            Divider()
            // Kill button
            Button(role: .destructive) {
                kill(process.pid, SIGTERM)
                dismiss()
            } label: {
                Label("Kill Process", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            let pid = process.pid
            DispatchQueue.global().async {
                let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
                let count = size > 0 ? Int(size) / MemoryLayout<proc_fdinfo>.size : 0
                DispatchQueue.main.async { openFileCount = count }
            }
        }
    }
}
