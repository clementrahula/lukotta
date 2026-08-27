// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import AppKit
import LukottaCore
import SwiftUI

// MARK: - Shared pieces

struct InfoBox: View {
    /// Optional: a note that reads as a sentence does not need a picture of
    /// itself in front of it.
    var icon: String?
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if let icon {
                Image(systemName: icon).foregroundStyle(.secondary).font(.caption)
                    .accessibilityHidden(true)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .accessibilityElement(children: .combine)
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 11.5, design: .monospaced))
                            .environment(\.layoutDirection, .leftToRight)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 150, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Engine output")
            .onChange(of: lines.count) { _, n in
                withAnimation { proxy.scrollTo(max(0, n - 1), anchor: .bottom) }
            }
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actionTitle: LocalizedStringKey
    let action: () -> Void

    /// Whether the action is still running, and what it found when it stopped.
    ///
    /// A button that does its work in a tenth of a second and says nothing
    /// reads as a button that does nothing. Both are optional so the other
    /// empty states, whose actions open a window rather than go away and think,
    /// are unchanged.
    var busy: Bool = false
    var result: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)

            Button(action: action) {
                if busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(actionTitle)
                    }
                } else {
                    Text(actionTitle)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(busy)

            // Kept in the layout whether or not there is anything to say, so
            // the button does not jump when the answer arrives.
            Text(result ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(result == nil)
                .animation(.default, value: result)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A line of news, with a way to be rid of it.
///
/// No icon in front of it. A symbol there says a category -- a warning, an
/// error -- and this is neither: a drive went away and can be opened again. The
/// close button is what somebody reaches for once they have read it, and
/// without one the sentence stays until something else happens to clear it.
struct NoticeLine: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .help("Dismiss")
        }
        .accessibilityElement(children: .combine)
    }
}

/// A button that goes away and looks for something.
///
/// A scan finishes in a fraction of a second, so a plain button appears to do
/// nothing at all: no delay, no change, no answer. This holds a spinner for
/// long enough to be seen and puts what was found beside it, which is the
/// difference between a button that works and a button that looks broken.
struct RescanButton: View {
    let title: LocalizedStringKey
    let busy: Bool
    var result: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Button(action: action) {
                if busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(title)
                    }
                } else {
                    Text(title)
                }
            }
            .disabled(busy)
        }
        .animation(.default, value: busy)
        .animation(.default, value: result)
    }
}
