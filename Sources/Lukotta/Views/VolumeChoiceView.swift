import AppKit
import LukottaCore
import SwiftUI

// MARK: - Choosing a volume

/// Shown when an unlocked container holds several logical volumes — the normal
/// case for Ubuntu, Debian and Fedora, which put root, home and swap inside one
/// LUKS container.
struct VolumeChoiceView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    let volumes: [LogicalVolume]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a volume").font(.title3.weight(.semibold))
                Text("“\(drive.name)” is unlocked and contains \(volumes.count) volumes.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(volumes, id: \.identifier) { vol in
                        Button {
                            model.choose(vol, on: drive)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "internaldrive")
                                    .font(.system(size: 22)).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vol.label).font(.body.weight(.medium))
                                    Text("\(vol.filesystem) · \(vol.size)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(13)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            InfoBox(
                icon: "lock.open",
                text:
                    "The drive stays unlocked, so opening one of these will not ask for the password again."
            )

            Spacer()
            HStack {
                Button("Back", action: model.backToDrives)
                Spacer()
            }
        }
    }
}
