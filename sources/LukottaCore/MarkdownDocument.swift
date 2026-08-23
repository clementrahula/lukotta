// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// The small subset of Markdown the bundled documents use.
///
/// Parsing is logic rather than presentation, so it lives here and can be
/// tested without a running interface.
public enum MarkdownDocument {

    public enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case table(header: [String], rows: [[String]])
        /// A horizontal rule, which separates one part of a document from the
        /// next.
        case rule
        /// Lines to be shown as they were written, indented or fenced.
        case code([String])
    }

    public static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var table: [[String]] = []
        var code: [String] = []
        var fenced = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func flushBullets() {
            if !bullets.isEmpty {
                blocks.append(.bullets(bullets))
                bullets = []
            }
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            let header = table.first ?? []
            // Row two of a Markdown table is the alignment rule rather than
            // data.
            let rows = Array(table.dropFirst(2))
            blocks.append(.table(header: header, rows: rows))
            table = []
        }
        func flushCode() {
            // Trailing blank lines belong to the space after the block rather
            // than to the block.
            while code.last?.isEmpty == true { code.removeLast() }
            if !code.isEmpty {
                blocks.append(.code(code))
                code = []
            }
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushTable()
            flushCode()
        }

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Inside a fence every line is content, including blank ones and
            // ones that would otherwise look like a heading or a list.
            if fenced {
                if line.hasPrefix("```") {
                    fenced = false
                    flushCode()
                } else {
                    code.append(raw)
                }
                continue
            }

            if line.hasPrefix("```") {
                flushAll()
                fenced = true
            } else if line.isEmpty {
                // A blank line inside an indented block does not end it. The
                // next indented line continues the same block.
                if code.isEmpty {
                    flushAll()
                } else {
                    code.append("")
                }
            } else if !bullets.isEmpty, raw.hasPrefix("    ") || raw.hasPrefix("\t") {
                // An indented line under a bullet is that bullet continuing,
                // which is handled below rather than as code.
                bullets[bullets.count - 1] += " " + line
            } else if raw.hasPrefix("    ") || raw.hasPrefix("\t") {
                flushParagraph()
                flushTable()
                code.append(raw)
            } else if line.hasPrefix("---") || line.hasPrefix("***") || line.hasPrefix("___") {
                flushAll()
                blocks.append(.rule)
            } else if line.hasPrefix("#") {
                flushAll()
                let level = line.prefix(while: { $0 == "#" }).count
                blocks.append(
                    .heading(
                        level: level,
                        text: line.dropFirst(level).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("|") {
                flushParagraph()
                flushBullets()
                let cells =
                    line
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty || table.isEmpty }
                table.append(cells.filter { !$0.isEmpty })
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                flushTable()
                bullets.append(String(line.dropFirst(2)))
            } else if !bullets.isEmpty, raw.first == " " {
                // An indented line after a bullet continues that bullet. Treating
                // it as a new paragraph broke every wrapped list item into a
                // bullet followed by a stray block of text.
                bullets[bullets.count - 1] += " " + line
            } else {
                flushBullets()
                flushTable()
                flushCode()
                paragraph.append(line)
            }
        }
        flushAll()
        return blocks
    }

}
