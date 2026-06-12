//
//  MessageViews.swift
//  OpenCode
//
//  Rendering for messages and their parts, per the v1 rendering matrix:
//  text as markdown, reasoning collapsed, tools as compact expandable cards,
//  files as chips, structural parts hidden, unknown types as placeholders.
//

import MarkdownUI
import SwiftUI

struct MessageView: View {
    let message: MessageWithParts

    var body: some View {
        switch message.info.role {
        case .user:
            UserMessageView(message: message)
        case .assistant, .unknown:
            AssistantMessageView(message: message)
        }
    }
}

// MARK: - User

private struct UserMessageView: View {
    let message: MessageWithParts

    var body: some View {
        let text = userText
        if !text.isEmpty {
            HStack {
                Spacer(minLength: 48)
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            }
        }
    }

    private var userText: String {
        message.parts.compactMap { part -> String? in
            if case .text(let data) = part.content, !data.synthetic, !data.ignored {
                return data.text
            }
            return nil
        }
        .joined(separator: "\n\n")
    }
}

// MARK: - Assistant

private struct AssistantMessageView: View {
    let message: MessageWithParts

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(message.parts) { part in
                PartView(part: part)
            }

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

private struct PartView: View {
    let part: Part

    var body: some View {
        switch part.content {
        case .text(let data):
            if !data.synthetic && !data.ignored && !data.text.isEmpty {
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
            Label(data.description ?? data.prompt ?? "Subtask", systemImage: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

        case .unknown(let type):
            if !type.isEmpty {
                Text("Unsupported part: \(type)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.fill.quaternary, in: Capsule())
            }

        case .stepStart, .stepFinish, .snapshot, .patch, .retry, .compaction:
            EmptyView()
        }
    }
}

// MARK: - Reasoning

private struct ReasoningView: View {
    let data: ReasoningPartData
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(data.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Label("Thinking", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tool card

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
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
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
            if let input = data.input, input != .object([:]) {
                Text(input.displayString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }

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
