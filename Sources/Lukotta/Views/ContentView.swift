import AppKit
import LukottaCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Header()
            Divider().opacity(0.5)
            Group {
                switch model.phase {
                case .needsPermission: PermissionView()
                case .scanning: ScanningView()
                case .chooseDrive: DriveListView()
                case .unlock(let d): UnlockView(drive: d)
                case .working(let d): WorkingView(drive: d)
                case .chooseVolume(let d, let vols):
                    VolumeChoiceView(drive: d, volumes: vols)
                case .mounted(let d, let p): MountedView(drive: d, mountPoint: p)
                case .failed(let d, let s, let detail):
                    FailureView(drive: d, summary: s, detail: detail)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
        .frame(minWidth: 580, idealWidth: 640, minHeight: 560, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $model.showHelp) { HelpSheet() }
        .sheet(isPresented: $model.showReport) { ReportIssueSheet() }
    }
}

// MARK: - Chrome

struct Header: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            LukottaMark()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("Lukotta").font(.headline)
                Text("Open encrypted drives on macOS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.showReport = true
            } label: {
                Image(systemName: "ladybug.circle")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Report a problem or send a crash report")
            .accessibilityLabel("Report a problem")
            .padding(.trailing, 8)

            Button {
                model.showHelp = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("How Lukotta works, and what it supports")
            .accessibilityLabel("About Lukotta")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

struct ScanningView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Looking for encrypted drives…").foregroundStyle(.secondary)
        }
    }
}
