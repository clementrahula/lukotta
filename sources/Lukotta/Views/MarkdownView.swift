import LukottaCore
import SwiftUI

/// Renders the subset of Markdown the bundled documents use: headings,
/// paragraphs, bullet lists, tables, rules and code blocks.
///
/// A full Markdown engine would be a dependency for one screen, and raw source
/// makes a compliance document harder to read.
struct MarkdownView: View {
    let source: String

    private var blocks: [MarkdownDocument.Block] { MarkdownDocument.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    // MARK: Blocks

    // MARK: Rendering

    @ViewBuilder private func view(for block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(text)
                .font(
                    level <= 1 ? .title2.weight(.semibold) : level == 2 ? .headline : .subheadline
                )
                .padding(.top, level <= 2 ? 8 : 2)

        case .paragraph(let text):
            Text(inline(text))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle().fill(Color.secondary.opacity(0.5))
                            .frame(width: 4, height: 4).offset(y: -2)
                        Text(inline(item))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .rule:
            Divider().padding(.vertical, 2)

        case .code(let lines):
            // Shown as written. These are layouts and commands, where a
            // reflowed line is a wrong one.
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))

        case .table(let header, let rows):
            VStack(spacing: 0) {
                tableRow(header, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, isHeader: false, striped: index.isMultiple(of: 2))
                }
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool, striped: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(inline(cell))
                    .font(.system(size: 11.5, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(isHeader ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(striped && !isHeader ? Color.primary.opacity(0.025) : Color.clear)
    }

    /// Bold, code spans and bare links, via the system Markdown parser.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
