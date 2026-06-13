//
//  SkillListSheet.swift
//  OpenCode
//
//  Bottom-sheet picker of the skills the connected opencode server
//  exposes (`GET /skill`). Tap a row → the caller receives the skill's
//  name and the sheet dismisses; the composer takes it from there
//  (prepending `/<name> ` to its draft via `SkillPrefix.apply`).
//
//  Read-only: skills are server-defined; the app doesn't author or
//  modify them. Browse-and-hint, not create-and-edit.
//
//  No full-content / markdown detail view in v1 — the description
//  authors write into each skill's frontmatter is the primary
//  explanation, and shipping a markdown renderer for it doubles the
//  scope. See AGENTS.md "Out of scope" for v1.
//

import SwiftUI

struct SkillListSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Invoked with the picked skill's name. The sheet auto-dismisses
    /// afterwards; the caller never has to think about lifecycle.
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Skills")
                .navigationBarTitleDisplayMode(.inline)
        }
        // Same detents as TodoListSheet — medium starts compact (most
        // skill lists fit), large covers servers with dozens.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        let skills = store.skills
        if skills.isEmpty {
            // Reachable when the server has no skills configured OR when
            // the skills fetch hasn't finished yet on the very first
            // connect. The fetch is sub-second on healthy networks so the
            // latter is rarely user-visible; same placeholder either way
            // keeps the sheet honest.
            ContentUnavailableView(
                "No Skills",
                systemImage: "wand.and.stars",
                description: Text("This opencode server has no skills configured.")
            )
        } else {
            List {
                ForEach(skills) { skill in
                    SkillRow(skill: skill) {
                        onPick(skill.name)
                        dismiss()
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Row

/// One skill row: name in body weight, description below in caption
/// (limited to 3 lines and truncated, matching the picker convention).
/// Whole-row tap, no chevron — picking is the only action.
private struct SkillRow: View {
    let skill: Skill
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if !skill.description.isEmpty {
                    Text(skill.description.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Padding the row content (not the row itself) so the whole
            // tappable area is reliably the same as the visible row.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
