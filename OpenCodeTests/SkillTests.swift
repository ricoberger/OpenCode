//
//  SkillTests.swift
//  OpenCodeTests
//
//  Skill model decoding + SkillPrefix.apply behaviour. The skill flow
//  is small but two paths benefit from coverage: the REST response
//  shape (so a future server change is caught instantly) and the
//  prefix-rewrite logic (replace vs prepend vs empty are easy to break
//  with a one-character regex change).
//

import Foundation
import Testing
@testable import OpenCode

@MainActor
struct SkillTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Skill decoding

    @Test func decodesSkillArray() throws {
        // Matches the wire shape returned by `GET /skill` (verified
        // against a live opencode instance: name + description + location
        // + content, additionalProperties: false).
        let json = """
        [
          {
            "name": "git-commit",
            "description": "Commit message helper",
            "location": "/Users/x/.claude/skills/git-commit/SKILL.md",
            "content": "# Git Commit\\n\\nWrite commits..."
          }
        ]
        """
        let skills = try decode([Skill].self, json)
        #expect(skills.count == 1)
        let skill = try #require(skills.first)
        #expect(skill.name == "git-commit")
        #expect(skill.description == "Commit message helper")
        #expect(skill.location.hasSuffix("SKILL.md"))
        #expect(skill.content.hasPrefix("# Git Commit"))
        // Identity = name, so SwiftUI ForEach keying on \.id is stable.
        #expect(skill.id == "git-commit")
    }

    /// Lenient-decoding contract: only `name` is required for identity;
    /// every other field decoding to defaults rather than throwing.
    @Test func decodesSkillWithMissingOptionalFields() throws {
        let json = """
        [{ "name": "minimal" }]
        """
        let skills = try decode([Skill].self, json)
        let skill = try #require(skills.first)
        #expect(skill.name == "minimal")
        #expect(skill.description == "")
        #expect(skill.location == "")
        #expect(skill.content == "")
    }

    /// v2 endpoint adds a `slash: boolean`; the v1 decoder must ignore
    /// it instead of throwing on unknown keys — keeps the door open to
    /// pointing the client at `/api/skill` later without a model change.
    @Test func decodesSkillIgnoresExtraFields() throws {
        let json = """
        [{
          "name": "future",
          "description": "d",
          "location": "/x",
          "content": "c",
          "slash": true
        }]
        """
        let skills = try decode([Skill].self, json)
        #expect(skills.first?.name == "future")
    }

    // MARK: - Prefix rewrite

    @Test func applyPrependsToEmptyDraft() {
        #expect(SkillPrefix.apply(skillName: "grill-me", to: "") == "/grill-me ")
    }

    @Test func applyPrependsWhenNoExistingPrefix() {
        let result = SkillPrefix.apply(skillName: "grill-me", to: "Plan the rollout")
        #expect(result == "/grill-me Plan the rollout")
    }

    @Test func applyReplacesExistingPrefix() {
        // Picking a *different* skill on an already-prefixed draft must
        // swap, not stack — otherwise the user ends up with two slash
        // commands and a confused agent.
        let result = SkillPrefix.apply(skillName: "git-commit", to: "/grill-me Plan the rollout")
        #expect(result == "/git-commit Plan the rollout")
    }

    @Test func applyReplacesSameSkillPrefixIdempotently() {
        let result = SkillPrefix.apply(skillName: "grill-me", to: "/grill-me Plan the rollout")
        #expect(result == "/grill-me Plan the rollout")
    }

    @Test func applyDoesNotTreatBareSlashAsPrefix() {
        // The regex requires `/<name><whitespace>` — a lone `/` or a
        // `/` followed immediately by non-name characters is not a
        // prefix and gets preserved as part of the draft.
        #expect(
            SkillPrefix.apply(skillName: "grill-me", to: "/") == "/grill-me /"
        )
        #expect(
            SkillPrefix.apply(skillName: "grill-me", to: "/$ weird") == "/grill-me /$ weird"
        )
    }

    @Test func applyReplacesAnyLeadingSlashWordToken() {
        // By design the regex is purely syntactic — any leading
        // `^/<word><whitespace>` is treated as a slash-command prefix
        // and gets replaced. The helper doesn't know which names are
        // real skills, and consulting the dynamic list would couple
        // the rewrite to mutable state for no real benefit. This test
        // pins the behaviour so a future "be smarter" refactor has to
        // think about whether it really is.
        let result = SkillPrefix.apply(skillName: "grill-me", to: "/why is this so")
        #expect(result == "/grill-me is this so")
    }

    @Test func applyHandlesPrefixWithNewlineSeparator() {
        // `\s` matches any whitespace — a newline-separated prefix
        // should still be recognised. Real users sometimes paste
        // multi-line prompts.
        let result = SkillPrefix.apply(skillName: "git-commit", to: "/grill-me\nPlan the rollout")
        #expect(result == "/git-commit Plan the rollout")
    }

    @Test func applyAcceptsHyphenAndUnderscoreInSkillNames() {
        let result = SkillPrefix.apply(skillName: "sre-grafana-dashboard", to: "/git_commit foo")
        #expect(result == "/sre-grafana-dashboard foo")
    }
}
