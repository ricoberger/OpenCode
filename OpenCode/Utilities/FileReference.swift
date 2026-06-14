//
//  FileReference.swift
//  OpenCode
//
//  Pure helper for injecting an `@<relative-path>` project-file
//  reference into the composer draft. Mirrors the opencode TUI's `@`
//  feature — the agent recognises the reference in the prompt text
//  and resolves it via Read.
//
//  Append (not prepend) because file references typically come after
//  the user's already-typed prompt sentence: "can you refactor the
//  auth flow in @path/to/file.swift". The composer's text field has
//  no SwiftUI-exposed cursor position, so append-at-end is the closest
//  honest equivalent to insert-at-caret.
//

import Foundation

enum FileReference {
    /// Returns `draft` with `@<path> ` appended.
    ///
    /// - Empty draft → just `"@<path> "`.
    /// - Draft ending in whitespace (space, tab, newline) → `"<draft>@<path> "`
    ///   (no extra leading space — preserves the user's spacing).
    /// - Draft ending in any other character → `"<draft> @<path> "`
    ///   (one space inserted so the reference doesn't fuse onto the
    ///   previous word).
    ///
    /// Always trailing-spaces the reference so the caret lands ready
    /// for the user to keep typing.
    static func append(path: String, to draft: String) -> String {
        let reference = "@\(path) "

        if draft.isEmpty {
            return reference
        }

        if let last = draft.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            return draft + reference
        }

        return draft + " " + reference
    }
}
