// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import SwiftUI

struct WorkingView: View {
    @EnvironmentObject var model: AppModel
    let drive: Drive

    private var stage: MountStage {
        MountStage.inferred(from: model.stageLines + model.statusLines)
    }

    /// The unpack reports a percentage; surface it rather than the stage list.
    private var unpackProgress: String? {
        model.statusLines.last(where: { $0.contains("Setting up the Linux environment") })
            .flatMap { $0.contains("%") ? $0 : nil }
    }

    /// Only the steps this mount takes: the approval one belongs to a
    /// single route.
    private var steps: [MountStage] {
        MountStage.shown(askingApproval: model.mountAsksApproval)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Opening “\(drive.name)”").font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("This usually takes under a minute.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let unpackProgress {
                VStack(alignment: .leading, spacing: 7) {
                    Text(unpackProgress).font(.callout)
                        .accessibilityHidden(true)
                    ProgressView(value: percent(of: unpackProgress), total: 100)
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Setting up the Linux environment")
                        .accessibilityValue(
                            "\(Int(percent(of: unpackProgress))) percent")
                    Text("The Linux environment is unpacked once, on first use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(steps, id: \.rawValue) { s in
                        StageRow(stage: s, current: stage)
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { model.cancelMount(drive) }
                Spacer()
            }
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
    /// When set, `current` is where the mount stopped rather than where it is.
    var stopped = false

    private var done: Bool { stage.rawValue < current.rawValue }
    private var active: Bool { stage == current }
    private var failed: Bool { stopped && active }

    private var state: String {
        if failed { return "stopped here" }
        if done { return "done" }
        if active { return "in progress" }
        return stopped ? "not reached" : "waiting"
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if failed {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                } else if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if active {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 18, height: 18)

            Text(stage.title)
                .font(failed ? .callout.weight(.medium) : .callout)
                .foregroundStyle(
                    failed ? .primary : (active ? .primary : (done ? .secondary : .tertiary)))
            if failed {
                Text("stopped here").font(.caption).foregroundStyle(.red)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stage.title): \(state)")
    }
}
