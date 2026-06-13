//
//  ComposerView.swift
//  OpenCode
//
//  Prompt input with attachments, send, and stop.
//
//  Behavior decisions baked in here:
//  - The draft (text + attachments) is only cleared after the server
//    accepts the prompt, so a failed send never loses typed text or
//    queued files.
//  - Sending while the agent is busy is allowed — the server queues the
//    prompt. The stop button appears *next to* send while working.
//  - Return inserts a newline (mobile chat convention); sending is always
//    explicit via the send button.
//  - Attachments are encoded inline as `data:` URLs (the server has no
//    upload endpoint). Images go through AttachmentEncoder — see
//    `Utilities/AttachmentEncoding.swift` for the resize policy.
//  - The chip strip is only rendered when at least one attachment is
//    queued; the input row otherwise stays compact.
//  - Send is disabled while any attachment is still loading and while any
//    attachment is in an error state — partial sends would silently drop
//    pending images or ship a broken one.
//  - Model/agent selection lives in the chat settings menu (see ChatView).
//

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Environment(ServerConnection.self) private var connection
    @Environment(SessionStore.self) private var store

    let session: Session

    @State private var draft = ""
    /// True while a prompt request is in flight; debounces the send button.
    @State private var sending = false
    /// Tracked so the Return-key handler can keep the field focused (the
    /// text system tries to end editing on hardware Return).
    @FocusState private var isFocused: Bool

    /// Queued attachments for the next send. Lifecycle matches the text
    /// draft: cleared on send success, preserved on send failure, reset
    /// on session switch (ChatView is identity-keyed by session ID).
    @State private var attachments: [Attachment] = []
    /// PhotosPicker's selection binding. Drained into `attachments` on
    /// change and reset to empty so re-picking the same photo works.
    @State private var photoSelection: [PhotosPickerItem] = []
    /// Drives the photo picker. The picker is presented via the
    /// `.photosPicker(isPresented:)` modifier (not as an inline
    /// `PhotosPicker` view inside the Menu) — Menu dismisses on tap and
    /// swallows the inline picker's presentation, so the imperative form
    /// is the only one that works from a Menu item.
    @State private var showingPhotosPicker = false
    /// Drives the `.fileImporter` sheet (Files app).
    @State private var showingFileImporter = false

    private var isWorking: Bool {
        store.status(for: session.id).isWorking
    }

    private var isConnected: Bool {
        connection.state.isConnected
    }

    /// Send is allowed when there's actual content to send, nothing is
    /// in flight, and every attachment has finished encoding cleanly.
    private var canSend: Bool {
        guard isConnected, !sending else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !attachments.isEmpty
        guard hasText || hasAttachments else { return false }
        // Loading or failed attachments block send — see file header.
        return attachments.allSatisfy(\.isReady)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { id in
                    attachments.removeAll { $0.id == id }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                attachMenu

                TextField(
                    isConnected ? "Message" : "Disconnected",
                    text: $draft,
                    axis: .vertical
                )
                // Grows with content up to 6 lines, then scrolls internally.
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 18))
                // Typing while disconnected would silently go nowhere —
                // disable and let the placeholder explain why.
                .disabled(!isConnected)
                .focused($isFocused)
                // The software keyboard's return key inserts a newline in a
                // vertical-axis TextField, but *hardware* keyboards
                // (Simulator with the Mac keyboard, iPad keyboards) deliver
                // Return as a key event that would otherwise do nothing.
                // Intercept it so both keyboards behave the same.
                // Limitation: SwiftUI exposes no cursor position for
                // TextField, so the newline is appended at the end — fine
                // for linear chat typing.
                .onKeyPress(.return) {
                    draft += "\n"
                    // The text system still tries to end editing on hardware
                    // Return despite us handling the event; re-assert focus
                    // on the next runloop so the caret stays in the field.
                    Task { isFocused = true }
                    return .handled
                }

                // Stop appears only while the agent works; send stays
                // available so the user can queue a follow-up.
                if isWorking {
                    Button {
                        Task { await store.abort(sessionID: session.id) }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            // Optically centers the icon against a
                            // single-line field (whose text sits inside 8pt
                            // vertical padding); with .bottom alignment the
                            // button stays pinned as the field grows.
                            .padding(.bottom, 6)
                    }
                    .accessibilityLabel("Stop")
                }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        // Same optical centering as the stop button.
                        .padding(.bottom, 6)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
        // PhotosPicker's selection is driven through a binding; reset it
        // to empty after draining so the user can re-pick the same photo
        // in a follow-up turn (otherwise `onChange` would not re-fire).
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            for item in items {
                Task { await ingest(photoItem: item) }
            }
            photoSelection = []
        }
        // Imperative photo picker — paired with the Menu Button that
        // flips `showingPhotosPicker`. Required because an inline
        // PhotosPicker view inside a Menu doesn't actually present.
        .photosPicker(
            isPresented: $showingPhotosPicker,
            selection: $photoSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        // `.fileImporter` returns security-scoped URLs; we read the bytes
        // inside `ingest(fileURL:)`, which handles start/stopAccessing.
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    Task { await ingest(fileURL: url) }
                }
            case .failure:
                // User-cancelled or system error — nothing to do; the
                // banner is reserved for store-side failures.
                break
            }
        }
    }

    // MARK: - Attach menu

    /// Paperclip Menu with Photos + Files entries. Both items are plain
    /// Buttons that flip presentation flags — see the comments on
    /// `showingPhotosPicker` for why we don't use the inline
    /// `PhotosPicker` view form here.
    private var attachMenu: some View {
        Menu {
            Button {
                showingPhotosPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

            Button {
                showingFileImporter = true
            } label: {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.title2)
                .foregroundStyle(.secondary)
                // Same optical centering as the send/stop buttons.
                .padding(.bottom, 6)
        }
        .disabled(!isConnected)
        .accessibilityLabel("Add Attachment")
    }

    // MARK: - Actions

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let toSend = attachments  // snapshot — mutations during send are ignored
        guard (!text.isEmpty || !toSend.isEmpty), !sending else { return }
        guard toSend.allSatisfy(\.isReady) else { return }

        sending = true
        Task {
            defer { sending = false }
            do {
                try await store.send(
                    text: text,
                    attachments: toSend.compactMap(\.partInput),
                    sessionID: session.id
                )
                // Only clear after the server accepted the prompt.
                draft = ""
                attachments = []
            } catch {
                // Draft + attachments are kept; the error banner (fed by
                // the store) reports the failure.
            }
        }
    }

    /// Picks one PhotosPickerItem's bytes off the main actor, runs them
    /// through `AttachmentEncoder` (resize/JPEG/data URL), and flips the
    /// placeholder chip to either `.ready` or `.failed`. A placeholder is
    /// inserted up front so the chip strip is responsive while the data
    /// is still loading.
    private func ingest(photoItem item: PhotosPickerItem) async {
        let id = UUID()
        // Try to surface a useful filename — PhotosPickerItem only
        // exposes `itemIdentifier` (an opaque PHAsset id), not a real
        // name. Compose a stable label so the user sees *something*.
        let placeholderName = "Image"
        attachments.append(Attachment(id: id, kind: .image, filename: placeholderName, state: .loading))

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                update(id: id) { $0.state = .failed("No data") }
                return
            }
            // Best-effort source MIME: photos picker can hand us
            // image/jpeg, image/heic, image/png. UTType fallback covers
            // less common formats.
            let mime = item.supportedContentTypes.first?.preferredMIMEType
                ?? "image/jpeg"
            let encoded = AttachmentEncoder.encodeImage(data: data, sourceMime: mime)
            update(id: id) { $0.state = .ready(encoded) }
        } catch {
            update(id: id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// Reads a Files-picked URL inside its security scope, classifies it
    /// (image vs document, by UTType), runs through the matching encoder.
    private func ingest(fileURL url: URL) async {
        let id = UUID()
        let filename = url.lastPathComponent
        let mime = AttachmentEncoder.mimeType(forFilename: filename)
        let kind: Attachment.Kind = mime.hasPrefix("image/") ? .image : .file
        attachments.append(Attachment(id: id, kind: kind, filename: filename, state: .loading))

        // Files returns security-scoped URLs; bytes must be read between
        // start/stopAccessing or the read fails for iCloud / external
        // providers (Dropbox, Drive, ...).
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let encoded: EncodedAttachment
            if kind == .image {
                encoded = AttachmentEncoder.encodeImage(data: data, sourceMime: mime)
            } else {
                encoded = AttachmentEncoder.encodeDocument(data: data, mime: mime)
            }
            update(id: id) { $0.state = .ready(encoded) }
        } catch {
            update(id: id) { $0.state = .failed(error.localizedDescription) }
        }
    }

    /// Mutate-in-place helper: state changes between cell appearances
    /// must hit the same `id` to avoid losing user removes that happened
    /// while loading was in flight.
    private func update(id: UUID, _ mutate: (inout Attachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        mutate(&attachments[index])
    }
}

// MARK: - Attachment model

/// One queued attachment in the composer. Lives only in `ComposerView`'s
/// `@State`; not pushed into the store (the store deals in already-sent
/// message parts, never staged drafts).
struct Attachment: Identifiable, Equatable {
    enum Kind: Equatable {
        case image
        case file
    }

    /// Async lifecycle: from picker tap through encoded bytes.
    enum State: Equatable {
        /// Bytes still being loaded/encoded. Send is disabled while any
        /// chip is in this state.
        case loading
        /// Successful encode — carries the wire-ready `data:` URL.
        case ready(EncodedAttachment)
        /// Encoding or loading failed; the user must × the chip before
        /// sending. The associated message is shown in the chip's a11y
        /// label (a future polish could surface it inline).
        case failed(String)
    }

    let id: UUID
    var kind: Kind
    var filename: String
    var state: State

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Convert to the wire-format part input; `nil` for any non-ready
    /// state so the send path never accidentally ships placeholders.
    var partInput: PromptRequest.PartInput? {
        guard case .ready(let encoded) = state else { return nil }
        return .file(mime: encoded.mime, url: encoded.dataURL, filename: filename)
    }
}

// MARK: - Chip strip

/// Horizontal scrolling strip of attachment chips, rendered above the
/// input row when any attachment is queued. Hidden entirely when empty
/// so the composer stays compact.
private struct AttachmentStrip: View {
    let attachments: [Attachment]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        onRemove(attachment.id)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // A faint divider at the bottom visually separates the strip from
        // the input row without adding extra padding.
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - Chip

/// One attachment chip. Image chips show a thumbnail; file chips show a
/// paperclip + filename capsule. Both render the loading and failed
/// states with overlays so the chip shape stays stable across the chip's
/// lifecycle.
private struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    private let imageSide: CGFloat = 56

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .frame(maxWidth: 200)
                .overlay(alignment: .center) {
                    overlay
                }

            // Inset slightly so the × button visually sits *on* the chip,
            // not floating off it.
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
            }
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove attachment")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var content: some View {
        switch attachment.kind {
        case .image:
            imageContent
        case .file:
            fileContent
        }
    }

    @ViewBuilder
    private var imageContent: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        Group {
            if let thumbnail = imageThumbnail {
                thumbnail
                    .resizable()
                    .scaledToFill()
            } else {
                // Placeholder shape while loading / on failure, so the
                // chip's size doesn't jump as the state changes.
                Rectangle()
                    .fill(.fill.tertiary)
            }
        }
        .frame(width: imageSide, height: imageSide)
        .clipShape(shape)
    }

    private var fileContent: some View {
        Label(attachment.filename, systemImage: "paperclip")
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.fill.tertiary, in: Capsule())
            // Cap the capsule so very long names don't push the strip
            // off the screen; truncation handles the rest.
            .frame(maxWidth: 180, alignment: .leading)
    }

    @ViewBuilder
    private var overlay: some View {
        switch attachment.state {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(6)
                .background(.regularMaterial, in: Circle())
        case .ready:
            EmptyView()
        }
    }

    /// Decodes the chip's thumbnail from the encoded data URL. Only the
    /// resized JPEG (or kept original) is decoded — never the source
    /// bytes — so the chip is cheap to render.
    private var imageThumbnail: Image? {
        guard case .ready(let encoded) = attachment.state,
              attachment.kind == .image,
              let data = decodeDataURL(encoded.dataURL),
              let uiImage = UIImage(data: data)
        else { return nil }
        return Image(uiImage: uiImage)
    }

    private var accessibilityLabel: String {
        switch attachment.state {
        case .loading: return "Loading \(attachment.filename)"
        case .ready: return attachment.kind == .image ? "Image \(attachment.filename)" : "File \(attachment.filename)"
        case .failed(let message): return "Failed to attach \(attachment.filename): \(message)"
        }
    }
}

/// Pulls the base64-encoded bytes back out of a `data:` URL. Shared by
/// the composer chip and the user-message echo in MessageViews. Returns
/// `nil` for malformed inputs — view code falls back to a placeholder.
func decodeDataURL(_ url: String) -> Data? {
    guard let commaRange = url.range(of: ","),
          url.hasPrefix("data:")
    else { return nil }
    let payload = String(url[commaRange.upperBound...])
    return Data(base64Encoded: payload)
}
