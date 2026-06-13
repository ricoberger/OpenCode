//
//  MessageViews.swift
//  OpenCode
//
//  Rendering for messages and their parts, per the v1 rendering matrix:
//
//  | Part type        | Treatment                                   |
//  |------------------|---------------------------------------------|
//  | text             | markdown bubble (user: plain trailing)      |
//  | reasoning        | collapsed expandable card (tool-card style) |
//  | tool             | compact expandable status card              |
//  | file             | filename chip                               |
//  | agent/subtask    | small informational chip                    |
//  | step/snapshot/…  | hidden (structural markers)                 |
//  | unknown          | "Unsupported part" placeholder chip         |
//
//  Tool calls get real-but-compact rendering on purpose: hiding them makes
//  supervising an agent impossible, full payloads make it unreadable.
//

import MarkdownUI
import SwiftUI

/// Entry point per message: branches on the author role.
struct MessageView: View {
    let message: MessageWithParts

    var body: some View {
        switch message.info.role {
        case .user:
            UserMessageView(message: message)
        case .assistant, .unknown:
            // Unknown roles render like assistant turns — their parts still
            // display individually, which beats hiding content.
            AssistantMessageView(message: message)
        }
    }
}

// MARK: - User

/// A user prompt: right-aligned tinted bubble, plain text (user input is
/// not markdown-rendered — what was typed is what shows), plus any file
/// parts the user attached. The bubble is suppressed when the message
/// has no text (attachments-only sends still render their chips).
private struct UserMessageView: View {
    let message: MessageWithParts

    var body: some View {
        let text = userText
        let files = userFileParts
        VStack(alignment: .trailing, spacing: 6) {
            if !text.isEmpty {
                HStack {
                    // Keeps the bubble from spanning the full width, chat-style.
                    Spacer(minLength: 48)
                    Text(text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .textSelection(.enabled)
                }
            }
            if !files.isEmpty {
                // Right-aligned column of attachment previews. Images show
                // an inline thumbnail (decoded from the part's data URL),
                // documents show a paperclip+filename capsule — mirroring
                // the composer chip styles so what you sent looks like
                // what's now in the transcript.
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(files) { part in
                        UserAttachmentView(file: part)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Joins the visible text parts. Synthetic/ignored parts are system
    /// injections or reverted content — not something the user typed.
    private var userText: String {
        message.parts.compactMap { part -> String? in
            if case .text(let data) = part.content, !data.synthetic, !data.ignored {
                return data.text
            }
            return nil
        }
        .joined(separator: "\n\n")
    }

    /// File parts attached to the user's prompt. Preserves message order
    /// so attachments display in the order the user picked them.
    private var userFileParts: [UserFilePart] {
        message.parts.compactMap { part in
            if case .file(let data) = part.content {
                return UserFilePart(id: part.id, data: data)
            }
            return nil
        }
    }
}

/// Identifiable wrapper so ForEach can key on the part id — `FilePartData`
/// alone has no stable identity (multiple identical attachments are
/// legal).
private struct UserFilePart: Identifiable {
    let id: String
    let data: FilePartData
}

/// One attachment as it appears in the user's transcript bubble.
/// Images decode their bytes inline from the part's `data:` URL (the
/// only form the composer ever sends — see ComposerView). Anything else
/// falls back to the paperclip chip used elsewhere for file parts.
private struct UserAttachmentView: View {
    let file: UserFilePart

    private let maxImageDimension: CGFloat = 200

    var body: some View {
        if let mime = file.data.mime, mime.hasPrefix("image/"),
           let url = file.data.url,
           let image = decodedImage(from: url)
        {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: maxImageDimension, maxHeight: maxImageDimension)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            Label(file.data.filename ?? file.data.mime ?? "Attachment", systemImage: "paperclip")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: Capsule())
        }
    }

    /// Decodes the inline `data:` URL into a SwiftUI `Image`. Returns
    /// `nil` for hosted URLs (we don't fetch network attachments — the
    /// server doesn't emit any today, but if a future part type does,
    /// it'll fall through to the paperclip chip rather than crash).
    private func decodedImage(from url: String) -> Image? {
        guard let data = decodeDataURL(url),
              let uiImage = UIImage(data: data)
        else { return nil }
        return Image(uiImage: uiImage)
    }
}

// MARK: - Assistant

/// An assistant turn: its parts stacked vertically in arrival order, plus
/// an error banner when the turn failed.
private struct AssistantMessageView: View {
    let message: MessageWithParts

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(message.parts) { part in
                PartView(part: part)
            }

            // Aborts are deliberately suppressed: the user pressed stop,
            // a red banner would be noise.
            if let error = message.info.error, !error.isAbort {
                Label(error.displayMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

// MARK: - Parts

/// Dispatches one part to its visual treatment (see the matrix at the top
/// of this file).
private struct PartView: View {
    let part: Part

    var body: some View {
        switch part.content {
        case .text(let data):
            if !data.synthetic && !data.ignored && !data.text.isEmpty {
                // MarkdownUI renders full GFM (code blocks, lists, tables) —
                // native AttributedString markdown only handles inline
                // styles, which is not enough for a coding agent's output.
                Markdown(data.text)
                    .markdownTextStyle(\.code) {
                        FontFamilyVariant(.monospaced)
                        BackgroundColor(Color.secondary.opacity(0.2))
                    }
                    .textSelection(.enabled)
            }

        case .reasoning(let data):
            if !data.text.isEmpty {
                ReasoningView(data: data)
            }

        case .tool(let data):
            ToolCard(data: data)

        case .file(let data):
            Label(data.filename ?? data.mime ?? "Attachment", systemImage: "paperclip")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.fill.tertiary, in: Capsule())

        case .agent(let name):
            if !name.isEmpty {
                Label(name, systemImage: "person.crop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .subtask(let data):
            Label(
                data.description ?? data.prompt ?? "Subtask", systemImage: "arrow.triangle.branch"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)

        case .unknown(let type):
            // The lenient-decoding fallback made visible: a newer server
            // sent a part type this app version does not know.
            if !type.isEmpty {
                Text("Unsupported part: \(type)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.fill.quaternary, in: Capsule())
            }

        case .stepStart, .stepFinish, .snapshot, .patch, .retry, .compaction:
            // Structural markers — meaningful to the server, noise to the
            // reader.
            EmptyView()
        }
    }
}

// MARK: - Reasoning

/// Reasoning rendered in the same card style as tool calls: a compact
/// tappable header (spinner while the model is still thinking, sparkles
/// once done, one-line preview) that expands to the full reasoning text.
private struct ReasoningView: View {
    let data: ReasoningPartData
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                        .frame(width: 16)

                    Text("thinking")
                        .font(.caption.monospaced().bold())

                    // One-line preview of the reasoning, mirroring the
                    // tool card's summary slot.
                    Text(preview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                // Make the whole row tappable, not just the visible glyphs.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(data.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Spinner while the model is still thinking (no end time yet),
    /// sparkles once the reasoning is complete — same pattern as the tool
    /// card's status icon.
    @ViewBuilder
    private var statusIcon: some View {
        if data.timeEnd == nil {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.tint)
        }
    }

    private var preview: String {
        data.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first ?? ""
    }
}

// MARK: - Tool card

/// Compact, expandable rendering of one tool invocation.
///
/// Collapsed: status icon + tool name + one-line summary (the bash command,
/// the file path, ...). Tapping expands to the input arguments, the
/// (truncated) output, and the error message if the call failed. The same
/// card re-renders through the pending → running → completed/error
/// lifecycle as part updates stream in.
private struct ToolCard: View {
    let data: ToolPartData
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    statusIcon
                        .frame(width: 16)

                    Text(data.tool)
                        .font(.caption.monospaced().bold())

                    Text(data.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Middle truncation keeps both ends of paths/commands
                        // visible — usually the informative parts.
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                // Make the whole row tappable, not just the visible glyphs.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                expandedContent
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// One glyph per lifecycle state (see ToolPartData.Status).
    @ViewBuilder
    private var statusIcon: some View {
        switch data.status {
        case .pending:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .unknown:
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Input arguments — skip the empty-object case to avoid a
            // useless "{}" line.
            if let input = data.input, input != .object([:]) {
                Text(input.displayString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }

            // Output is capped twice: by character count (huge outputs would
            // make SwiftUI text layout crawl) and by visible line count.
            if let output = data.output, !output.isEmpty {
                Text(truncated(output))
                    .font(.caption2.monospaced())
                    .lineLimit(30)
                    .textSelection(.enabled)
            }

            if let errorMessage = data.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.red)
                    .lineLimit(10)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func truncated(_ text: String, limit: Int = 3000) -> String {
        if text.count <= limit { return text }
        return text.prefix(limit) + "\n…(truncated)"
    }
}
