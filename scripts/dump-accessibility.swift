// Print what a screen reader would find in the running app.
//
// Accessibility is easy to get wrong in a way nothing else catches: a control
// with no label compiles, draws correctly, and is silent. This asks macOS what
// it actually exposes, so a missing label shows up as desc=nil.
//
//   swift scripts/dump-accessibility.swift
//
// Needs Accessibility permission for whatever runs it (Terminal, say) in
// Privacy & Security. Every control should have a description; a nil one is a
// control nobody can use without seeing it.

import ApplicationServices
import AppKit

guard AXIsProcessTrusted() else {
    print("NO ACCESSIBILITY PERMISSION — cannot inspect the element tree from here")
    exit(2)
}
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.clementrahula.lukotta" }) else {
    print("Lukotta is not running"); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)

func attr(_ e: AXUIElement, _ name: String) -> String? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    return (v as? String)
}

func walk(_ e: AXUIElement, depth: Int) {
    let role = attr(e, kAXRoleAttribute as String) ?? "?"
    let title = attr(e, kAXTitleAttribute as String)
    let desc = attr(e, kAXDescriptionAttribute as String)
    let help = attr(e, kAXHelpAttribute as String)
    let interesting = ["AXTextField", "AXSecureTextField", "AXButton", "AXCheckBox",
                       "AXTextArea", "AXProgressIndicator", "AXRadioGroup", "AXPopUpButton"]
    // Anything that carries a description is something a screen reader will
    // read out, whatever its role. Controls are listed even without one,
    // because that absence is the bug worth finding.
    // Static text carries its words as a value rather than a description, so
    // both are worth printing: a row can be perfectly readable through one and
    // look empty through the other.
    let value = attr(e, kAXValueAttribute as String)
    if interesting.contains(role) || desc != nil || value != nil {
        var line = "  \(role): title=\(title.map { "\"\($0)\"" } ?? "nil")"
        line += " desc=\(desc.map { "\"\($0)\"" } ?? "nil")"
        if let value { line += " value=\"\(value.prefix(90))\"" }
        if let help { line += " help=\"\(help)\"" }
        print(line)
    }
    var kids: CFTypeRef?
    if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success,
       let children = kids as? [AXUIElement], depth < 25 {
        for c in children { walk(c, depth: depth + 1) }
    }
}

var wins: CFTypeRef?
if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wins) == .success,
   let windows = wins as? [AXUIElement] {
    for w in windows { walk(w, depth: 0) }
}
