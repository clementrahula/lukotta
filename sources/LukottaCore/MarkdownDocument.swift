import Foundation

/// The small subset of Markdown the bundled documents use.
///
/// Parsing is logic, not presentation, so it lives here where it can be tested
/// without a running interface.
public enum MarkdownDocument {

    public enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case table(header: [String], rows: [[String]])
    }

    public static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var table: [[String]] = []

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
            // Row two of a Markdown table is the alignment rule, not data.
            let rows = Array(table.dropFirst(2))
            blocks.append(.table(header: header, rows: rows))
            table = []
        }
        func flushAll() {
            flushParagraph()
            flushBullets()
            flushTable()
        }

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushAll()
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
            } else if !bullets.isEmpty, raw.first == " " || raw.first == "\t" {
                // An indented line after a bullet continues that bullet. Treating
                // it as a new paragraph broke every wrapped list item into a
                // bullet followed by a stray block of text.
                bullets[bullets.count - 1] += " " + line
            } else {
                flushBullets()
                flushTable()
                paragraph.append(line)
            }
        }
        flushAll()
        return blocks
    }

}
