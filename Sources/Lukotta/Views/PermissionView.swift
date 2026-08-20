import AppKit
import LukottaCore
import SwiftUI

// MARK: - Permission

struct PermissionView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.wave.fill")
                    .font(.system(size: 28)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Lukotta").font(.title3.weight(.semibold))
                    Text(
                        "Lukotta opens BitLocker and Linux drives that macOS cannot read on its own. One setting is needed first.\n\nReading a drive at the raw device level needs Full Disk Access — an administrator password is not enough, and the removable-volumes permission covers files on a drive, not the raw device. macOS has no way for an app to request this one, so it has to be switched on by hand."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                Step(number: 1, text: "Open Privacy & Security → Full Disk Access.")
                Step(number: 2, text: "Click + and add Lukotta, then switch it on.")
                Step(
                    number: 3,
                    text:
                        "Come back here and choose Relaunch — a new permission only applies to a freshly started app."
                )
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            InfoBox(
                icon: "hand.raised",
                text:
                    "This is a macOS privacy setting, not a change to your Mac. You can switch it off again at any time, and nothing is installed."
            )

            Spacer()
            HStack {
                Button("Reveal App") { model.revealApp() }
                Spacer()
                Button("Relaunch") { model.relaunch() }
                Button("Check Again") { model.recheckPermission() }
                Button("Open Privacy Settings") { model.openPrivacySettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct Step: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Circle().fill(.tint))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
