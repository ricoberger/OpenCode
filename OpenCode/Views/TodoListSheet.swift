//
//  TodoListSheet.swift
//  OpenCode
//
//  Bottom-sheet view of one session's current todo list (the agent's
//  internal plan, owned server-side by the TodoWrite tool).
//
//  Read-only by design: todos are agent-owned state, the app only
//  visualizes them. Data is already in the store by the time the sheet
//  presents — ContentView loads todos alongside messages on session
//  selection — and `todo.updated` SSE events keep the list live while the
//  sheet is open. Pull-to-refresh is cheap insurance against a missed
//  event and matches the rest of iOS.
//
//  Items render in server order (the agent's intentional ordering — first
//  item is "do next"). Completed and cancelled items get a strikethrough
//  and secondary color but stay in place rather than sinking to the
//  bottom, so the user can see what was done in the agent's own sequence.
//

import SwiftUI

struct TodoListSheet: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Identifies which session's todos to show. The sheet reads from the
    /// store every render so SSE updates flow in without any local cache.
    let sessionID: String

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Todos")
                .navigationBarTitleDisplayMode(.inline)
                .refreshable {
                    // Insurance against a missed SSE event; the endpoint
                    // returns a small array so the cost is negligible.
                    await store.loadTodos(sessionID: sessionID)
                }
        }
        // Medium starts compact (most plans fit); large is available for
        // longer lists without forcing the user into a full-screen sheet.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var content: some View {
        let todos = store.todos(for: sessionID)
        if todos.isEmpty {
            ContentUnavailableView(
                "No Todos",
                systemImage: "checklist",
                description: Text(
                    "The agent will add todos here as it plans complex tasks."
                )
            )
        } else {
            List {
                // `id: \.self` because the server provides no stable id;
                // TodoItem is Hashable. Duplicate items (same content +
                // status + priority) would collapse into one row, which
                // the agent does not produce in practice.
                ForEach(todos, id: \.self) { todo in
                    TodoRow(todo: todo)
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Row

/// One row in the todo list: a status glyph leading the content text. Done
/// and cancelled items are dimmed and struck through so the active plan
/// stands out at a glance.
private struct TodoRow: View {
    let todo: TodoItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.body)
                .foregroundStyle(statusTint)
                // Pin the glyph width so multi-line content text aligns
                // to a consistent leading edge.
                .frame(width: 20, alignment: .center)

            Text(todo.content)
                .font(.body)
                .strikethrough(isFinished, color: .secondary)
                .foregroundStyle(isFinished ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        // Make the whole row a single accessibility element with a status
        // prefix, so VoiceOver reads "completed: write the tests" instead
        // of "checkmark, write the tests".
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessibilityStatus): \(todo.content)")
    }

    /// `true` for completed and cancelled — the visual treatment is the
    /// same (dim + strikethrough); the icon distinguishes them.
    private var isFinished: Bool {
        switch todo.status {
        case .completed, .cancelled: return true
        case .pending, .inProgress, .unknown: return false
        }
    }

    private var statusIcon: String {
        switch todo.status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        // Matches the unknown-discriminator glyph used elsewhere
        // (ToolCard for unknown tool statuses); keeps forward-compat
        // statuses visible without crashing the row.
        case .unknown: return "questionmark.circle"
        }
    }

    private var statusTint: Color {
        switch todo.status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .completed: return .green
        case .cancelled: return .secondary
        case .unknown: return .secondary
        }
    }

    private var accessibilityStatus: String {
        switch todo.status {
        case .pending: return "Pending"
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        case .unknown: return "Unknown status"
        }
    }
}
