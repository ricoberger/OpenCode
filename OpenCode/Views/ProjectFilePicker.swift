//
//  ProjectFilePicker.swift
//  OpenCode
//
//  Bottom-sheet picker for project files served by the opencode server.
//  Search-only (no browse) — mirrors the TUI's `@` autocomplete: type
//  a few characters, pick a result, the caller injects `@<path> ` into
//  the composer draft via `FileReference.append`.
//
//  Why no cached store: project files churn as the agent works (edits,
//  renames, deletions all happen mid-session) and the `/find/file`
//  endpoint is fast. Per-sheet-open fetches stay honest about what's
//  on disk right now.
//
//  Why no .searchable on the List: SwiftUI's .searchable owns its own
//  text and timing. We need the query value at the picker level (to
//  debounce, cancel in-flight tasks, and drive the empty/no-results
//  branching), so the search field is rendered inline at the top of
//  the sheet.
//

import SwiftUI

struct ProjectFilePicker: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Invoked with the picked file's relative path. The sheet
    /// auto-dismisses afterwards.
    let onPick: (String) -> Void

    @State private var query: String = ""
    @State private var results: [String] = []
    @State private var isSearching = false
    /// In-flight search task; cancelled on every new keystroke so an
    /// older slow response can't overwrite a newer fast one.
    @State private var searchTask: Task<Void, Never>?

    /// Trimmed query — leading/trailing whitespace shouldn't trigger
    /// searches that the server would just normalize away anyway.
    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                Divider()
                content
            }
            .navigationTitle("Project Files")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Cancel the in-flight task if the sheet goes away mid-search;
        // the user already moved on.
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: - Search field

    /// Inline search field at the top of the sheet. We render it
    /// ourselves (instead of .searchable on the List) so the picker
    /// owns the debounce and cancellation logic — see file header.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search files", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onChange(of: query) { _, _ in
            scheduleSearch()
        }
    }

    // MARK: - Result list

    @ViewBuilder
    private var content: some View {
        if trimmedQuery.isEmpty {
            // Picker just opened (or query was cleared). Invite the
            // user to type — no auto-listing of the project root, no
            // surprise data fetch on sheet open.
            ContentUnavailableView(
                "Find Project Files",
                systemImage: "at",
                description: Text("Type to search files in the opencode project.")
            )
        } else if results.isEmpty && !isSearching {
            // SwiftUI's built-in search-no-match. Renders
            // "No Results for '<query>'" with the standard styling so
            // we don't have to invent copy for this case.
            ContentUnavailableView.search(text: trimmedQuery)
        } else {
            List {
                ForEach(results, id: \.self) { path in
                    FileRow(path: path) {
                        onPick(path)
                        dismiss()
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Search

    /// Debounce + cancel-previous orchestration. Cancelling early in
    /// the new task means a slow 250 ms-old request can't overwrite
    /// the results of a fresh one.
    private func scheduleSearch() {
        searchTask?.cancel()

        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            // Cleared the field — also clear the results so the empty
            // state takes over immediately, not after the next search.
            results = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            // 250ms debounce — standard for as-you-type search; balances
            // responsiveness against request volume.
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
            await runSearch(query: trimmed)
        }
    }

    private func runSearch(query: String) async {
        guard let client = connection.client else {
            isSearching = false
            return
        }
        do {
            let found = try await client.findFiles(query: query)
            // Guard against the task being cancelled while the request
            // was in flight — assigning results would otherwise race
            // with a newer search that already cleared them.
            if Task.isCancelled { return }
            results = found
            isSearching = false
        } catch {
            if Task.isCancelled { return }
            // Surface via the store's banner (consistent with every
            // other request failure) and fall back to the no-results
            // state in the sheet.
            store.lastError = error.localizedDescription
            results = []
            isSearching = false
        }
    }
}

// MARK: - Row

/// One file result: filename in body weight on top, full relative path
/// in caption underneath. Long paths truncate-head so the filename
/// (the most informative part) stays visible.
private struct FileRow: View {
    let path: String
    let onTap: () -> Void

    private var filename: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.body)
                    .foregroundStyle(.primary)
                if path != filename {
                    // Skip the relative-path row when the file lives at
                    // the project root (path == filename) — would just
                    // be a duplicate line.
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
