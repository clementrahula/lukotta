#!/usr/bin/env python3
"""Collect every string the interface shows, as translation keys.

SwiftUI's Text, Button, Label and Toggle take LocalizedStringKey, so the literal
written in the code is already the key. String(localized:) and appString() are
the same idea for text built outside a view. Neither is extracted by the Swift
compiler without Xcode's build system, so they are gathered here.

An interpolation becomes a format specifier, which is what the key looks like
once Foundation has resolved it: a count becomes %lld and anything else %@.
"""

import json, pathlib, re, sys

CALLS = [
    "Text", "Button", "Label", "Toggle", "Picker",
    ".help", ".accessibilityLabel", ".accessibilityHint", ".accessibilityValue",
    "String(localized:", "appString", "checkboxWithTitle:", "withTitle:",
]

# A literal, allowing escaped quotes and Swift's interpolations inside it.
LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
# A multi-line literal, which is how a sentence too long for one line is written
# without splitting it into fragments nobody can translate.
BLOCK = re.compile(r'"""\n(.*?)\n\s*"""', re.S)
CALL = re.compile(
    r'(?:Text|Button|Label|Toggle|Picker|appString|Bullet)\s*\(\s*"'
    r'|(?:text|title|message|actionTitle):\s*"'
    r'|\.(?:help|accessibilityLabel|accessibilityHint|accessibilityValue)\s*\(\s*"'
    r'|localized:\s*"'
    r'|(?:checkboxWithTitle|withTitle):\s*"'
)

COUNTISH = re.compile(r"\.count\b|\bmb\b|Int\(")

# Both halves of a choice are shown to someone, so both are keys. The ones
# naming an SF Symbol are not text at all, and are recognised by the call they
# sit in rather than by how they look — "trash" and "eye" are symbol names, and
# "locked" and "done" are not, and nothing about the strings says which.
TERNARY = re.compile(r'\?\s*"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"')


def specifier(expr: str) -> str:
    return "%lld" if COUNTISH.search(expr) else "%@"


def to_key(raw: str) -> str:
    """Turn a Swift literal into the key Foundation will look up."""
    out, i = [], 0
    while i < len(raw):
        if raw.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(raw) and depth:
                if raw[j] == "(":
                    depth += 1
                elif raw[j] == ")":
                    depth -= 1
                j += 1
            out.append(specifier(raw[i + 2 : j - 1]))
            i = j
        elif raw.startswith("\\n", i):
            out.append("\n"); i += 2
        elif raw.startswith('\\"', i):
            out.append('"'); i += 2
        elif raw.startswith("\\u{", i):
            j = raw.index("}", i)
            out.append(chr(int(raw[i + 3 : j], 16))); i = j + 1
        elif raw.startswith("\\\\", i):
            out.append("\\"); i += 2
        else:
            out.append(raw[i]); i += 1
    return "".join(out)


def unwrap_block(raw: str) -> str:
    """Join a multi-line literal the way Swift does: a trailing \\ means no break."""
    out = []
    for line in raw.split("\n"):
        stripped = line.strip()
        if stripped.endswith("\\"):
            out.append(stripped[:-1])
        else:
            out.append(stripped + "\n")
    return "".join(out).rstrip("\n")


# A literal returned from something typed LocalizedStringKey is a key too, and
# there is no call around it to recognise. Only looked for in files that use the
# type, so an ordinary String return elsewhere is not mistaken for interface text.
RETURNED = re.compile(r'\breturn\s+"((?:[^"\\]|\\.)*)"')


def keys_in(path: pathlib.Path):
    text = path.read_text()
    if "LocalizedStringKey" in text:
        for m in RETURNED.finditer(text):
            key = to_key(m.group(1))
            if key.strip():
                yield key
    # Multi-line literals are interface sentences only in the app. In the core
    # they are shell scripts, which are not for reading and not for translating.
    is_interface = "Lukotta" in path.parts and "LukottaCore" not in path.parts
    for m in BLOCK.finditer(text) if is_interface else []:
        key = to_key(unwrap_block(m.group(1)))
        if key.strip() and " " in key:
            yield key
    for m in TERNARY.finditer(text):
        if "systemName" in text[max(0, m.start() - 90) : m.start()]:
            continue
        for raw in m.groups():
            key = to_key(raw)
            if key.strip():
                yield key
    for m in CALL.finditer(text):
        start = text.rindex('"', m.start(), m.end())
        lit = LITERAL.match(text, start)
        if not lit:
            continue
        key = to_key(lit.group(1))
        if key.strip():
            yield key


def main():
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "sources")
    found = {}
    for swift in sorted(root.rglob("*.swift")):
        # "LukottaTests", not "Tests": fixtures are full of text that looks like
        # interface copy and is not.
        if any("Tests" in part for part in swift.parts):
            continue
        for key in keys_in(swift):
            found.setdefault(key, str(swift))
    print(json.dumps(found, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
