//
//  FileReferenceTests.swift
//  OpenCodeTests
//
//  Tests for FileReference.append — the small but easy-to-break
//  helper that splices `@<path> ` into the composer draft from the
//  project-file picker. Five cases cover the spacing branches that
//  matter: empty, ends-in-space, ends-in-newline, ends-in-word,
//  and the deliberately-undeduplicated repeat-pick case.
//

import Foundation
import Testing
@testable import OpenCode

@MainActor
struct FileReferenceTests {

    @Test func appendsToEmptyDraft() {
        #expect(
            FileReference.append(path: "src/foo.swift", to: "")
                == "@src/foo.swift "
        )
    }

    @Test func appendsAfterExistingTrailingSpace() {
        // User typed "look at " — the trailing space is theirs to
        // own; we don't add a second one.
        #expect(
            FileReference.append(path: "src/foo.swift", to: "look at ")
                == "look at @src/foo.swift "
        )
    }

    @Test func appendsAfterTrailingNewline() {
        // Multi-line drafts end in `\n`; treated the same as a
        // trailing space — no extra separator inserted.
        let result = FileReference.append(path: "src/foo.swift", to: "fix this:\n")
        #expect(result == "fix this:\n@src/foo.swift ")
    }

    @Test func insertsSpaceWhenDraftEndsInWord() {
        // Draft ends in a non-whitespace character — without the
        // inserted space, the reference would fuse onto the previous
        // word and read as a different token to the model.
        #expect(
            FileReference.append(path: "src/foo.swift", to: "refactor")
                == "refactor @src/foo.swift "
        )
    }

    @Test func appendingTwiceDoesNotDeduplicate() {
        // Picking the same file twice deliberately adds two references.
        // The user can backspace if they didn't mean to; silently
        // de-duping would be confusing when the picker dismissed but
        // the draft didn't change.
        let once = FileReference.append(path: "src/foo.swift", to: "")
        let twice = FileReference.append(path: "src/foo.swift", to: once)
        #expect(twice == "@src/foo.swift @src/foo.swift ")
    }

    @Test func handlesPathsWithSpacesByLeavingThemBare() {
        // Per the design: bare path always, no backtick quoting in v1.
        // If a path-with-space breaks model parsing in practice, that's
        // a one-line change to add quoting; this test pins the current
        // behaviour so the change is intentional.
        #expect(
            FileReference.append(path: "My Folder/file.swift", to: "")
                == "@My Folder/file.swift "
        )
    }
}
