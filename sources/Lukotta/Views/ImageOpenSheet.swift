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
                        Text("Looking at what is inside it.")
                            .font(.callout).foregroundStyle(.secondary)
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
                }
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
