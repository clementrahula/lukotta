// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula
//
// Presses an element of a running app by accessibility identifier or title, or waits for text. No clicks.
//   ax-press <bundle id> press <identifier> [seconds]
//   ax-press <bundle id> title <button title> [seconds]
//   ax-press <bundle id> shows <text> [seconds]
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: ax-press <bundle id> press|title|shows <what> [seconds]")
    exit(2)
}
guard AXIsProcessTrusted() else {
    print("no accessibility permission")
    exit(2)
}
let bundle = args[1]
let verb = args[2]
let what = args[3]
let seconds = args.count > 4 ? Double(args[4]) ?? 30 : 30

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}

func text(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }

func matches(_ e: AXUIElement) -> Bool {
    switch verb {
    case "press": return text(e, "AXIdentifier") == what
    case "title": return text(e, kAXTitleAttribute as String) == what
    default:
        return [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains {
            text(e, $0 as String)?.contains(what) == true
        }
    }
}

func find(_ e: AXUIElement, depth: Int) -> AXUIElement? {
    if matches(e) { return e }
    guard depth < 60 else { return nil }
    for child in (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] {
        if let hit = find(child, depth: depth + 1) { return hit }
    }
    return nil
}

let deadline = Date().addingTimeInterval(seconds)
repeat {
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        for window in (attr(root, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
            guard let hit = find(window, depth: 0) else { continue }
            if verb == "shows" {
                print("shown")
            } else {
                let done = AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success
                print(done ? "pressed" : "refused")
            }
            exit(0)
        }
    }
    Thread.sleep(forTimeInterval: 0.5)
} while Date() < deadline
print("absent")
exit(1)
