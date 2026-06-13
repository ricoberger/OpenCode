//
//  SkillPrefix.swift
//  OpenCode
//
//  Pure helper that wires the skill picker into the composer's text.
//
//  Tapping a skill in the picker injects `/<name> ` into the composer
//  draft so the agent loads that skill on the next turn — mirroring how
//  slash commands work in the opencode TUI. Picking a *different* skill
//  swaps the existing prefix rather than stacking them, so the user
//  can re-pick freely.
//
//  Kept as a free function with no SwiftUI / view dependency so unit
//  tests can drive it directly.
//

import Foundation

enum SkillPrefix {
    /// Returns `draft` with the new slash-command prefix applied.
    ///
    /// - Empty draft → just `"/<name> "` (trailing space lets the caret
    ///   land ready to type the actual prompt).
    /// - Draft that already starts with `^/[A-Za-z0-9_-]+\s` → replace
    ///   the matched prefix with `"/<name> "` (picking a second skill
    ///   swaps, doesn't stack).
    /// - Anything else → prepend `"/<name> "` to the existing draft so
    ///   typed text is preserved.
    static func apply(skillName name: String, to draft: String) -> String {
        let prefix = "/\(name) "

        if draft.isEmpty {
            return prefix
        }

        if let range = leadingSlashCommandRange(in: draft) {
            return prefix + draft[range.upperBound...]
        }

        return prefix + draft
    }

    /// Range of the leading `^/[A-Za-z0-9_-]+\s` match, if any. The skill
    /// name character class follows opencode's filesystem-safe naming
    /// convention (slugs, hyphens, digits). Returns `nil` for drafts
    /// without a recognisable slash-command prefix — including bare
    /// slashes the user may be mid-typing.
    private static func leadingSlashCommandRange(in text: String) -> Range<String.Index>? {
        // Inline regex literal: matches `/`, then 1+ name chars, then
        // exactly one whitespace character. We don't consume more — the
        // user's typed prompt is whatever follows.
        text.range(of: #"^/[A-Za-z0-9_-]+\s"#, options: .regularExpression)
    }
}
