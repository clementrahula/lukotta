import LukottaCore
import SwiftUI

/// What is happening while a container file is being opened, and what happened
/// if it did not work.
///
/// Attaching takes a moment, and can take much longer for a file on a share
/// that has gone away. Without this the window sat unchanged for several
/// seconds after File → Open Disk Image, which reads as nothing having
/// happened at all.
///
/// It closes itself when the drive appears, because the drive appearing is the
/// whole of the answer. A failure stays until it is read.
struct ImageOpenSheet: View {
    @EnvironmentObject var model: AppModel
    let state: AppModel.ImageOpening

    private var name: String { state.url.lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch state {
            case .opening:
                HStack(spacing: 13) {
                    ProgressView().controlSize(.small)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Opening “\(name)”").font(.headline)
                        Text("Examining its contents.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)

            case .handedToMacOS(_, let mountPoint):
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("macOS opened “\(name)”").font(.headline)
                        // Why it was handed over as well as that it was. A
                        // volume appearing in Finder that the user did not put
                        // there is a surprise worth heading off.
                        Text(
                            "macOS reads and writes exFAT itself, so this image was opened directly as an ordinary disk."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: mountPoint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                        Text("Eject it in Finder when you are finished.")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
                .accessibilityElement(children: .combine)

            case .failed(_, let message):
                HStack(alignment: .top, spacing: 13) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“\(name)” was not opened").font(.headline)
                        Text(message)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            HStack {
                Spacer()
                switch state {
                case .opening:
                    // Stops waiting, and puts back anything that attached in
                    // the meantime.
                    Button("Cancel") { model.cancelImageOpen() }
                        .keyboardShortcut(.cancelAction)
                case .failed:
                    Button("OK") { model.dismissImageProblem() }
                        .keyboardShortcut(.defaultAction)
                case .handedToMacOS(_, let mountPoint):
                    Button("Show in Finder") { model.revealInFinder(mountPoint) }
                    Button("OK") { model.dismissImageProblem() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
