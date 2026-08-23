// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Clement Rahula

import Foundation

/// A name, a path or a device identifier, kept in one piece inside a sentence.
///
/// A drive is called what its owner called it, and the sentence around it is in
/// whatever language they read. Latin letters run left to right and Arabic and
/// Hebrew run right to left, and the quotation marks, slashes and dots between
/// them belong to neither: the paragraph decides which way they face. So
/// “Elements” inside an Arabic sentence renders with its quotes swapped, and
/// /Volumes/Elements comes out as Volumes/Elements/ -- correct characters,
/// wrong order.
///
/// The isolates say: whatever is between these two marks is one run, work out
/// its direction by itself, and put the result where the sentence expects it.
/// They are invisible, they survive interpolation, and in a left-to-right
/// language they change nothing at all.
///
/// Not for anything a machine reads afterwards. A transcript, a report, a log
/// line and a path handed to a program all go without: an invisible character
/// in a path is a path that does not resolve.
public func isolated(_ value: String) -> String {
    "\u{2068}" + value + "\u{2069}"
}
