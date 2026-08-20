import AppKit
import LukottaCore
import SwiftUI

struct WorkingView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive
    @State private var showDetail = false

    private var stage: MountStage {
        MountStage.inferred(from: model.stageLines + model.statusLines)
    }

    /// The unpack reports a percentage; surface it rather than the stage list.
    private var unpackProgress: String? {
        model.statusLines.last(where: { $0.contains("Setting up the Linux environment") })
            .flatMap { $0.contains("%") ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Opening “\(drive.name)”").font(.title3.weight(.semibold))
                Text("This usually takes under a minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let unpackProgress {
                VStack(alignment: .leading, spacing: 7) {
                    Text(unpackProgress).font(.callout)
                    ProgressView(value: percent(of: unpackProgress), total: 100)
                        .progressViewStyle(.linear)
                    Text("The Linux environment is unpacked once, on first use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(MountStage.allCases, id: \.rawValue) { s in
                        StageRow(stage: s, current: stage)
                    }
                }
            }

            DisclosureGroup("Details", isExpanded: $showDetail) {
                LogView(lines: model.statusLines)
            }
            .font(.caption)
            Spacer()
        }
    }

    private func percent(of text: String) -> Double {
        let digits = text.split(whereSeparator: { !$0.isNumber })
        return Double(digits.last.map(String.init) ?? "0") ?? 0
    }
}

struct StageRow: View {
    let stage: MountStage
    let current: MountStage

    private var done: Bool { stage.rawValue < current.rawValue }
    private var active: Bool { stage == current }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if active {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)

            Text(stage.title)
                .font(.callout)
                .foregroundStyle(active ? .primary : (done ? .secondary : .tertiary))
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title): \(done ? "done" : active ? "in progress" : "waiting")")
    }
}
