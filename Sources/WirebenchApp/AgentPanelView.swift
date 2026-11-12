#if WIREBENCH_AI
import SwiftUI
import WirebenchModel

/// The agent panel: a conversation with a chatbot service over the OpenAI chat-completions API. Which service, the model, the key and the
/// conversation all live in `AgentModel`, which the Qt app draws as well; this is only its SwiftUI face.
///
/// The key is typed here once and goes to the Keychain; it is never shown again and never written anywhere else.
struct AgentPanelView: View {
    @Bindable var agent: AgentModel
    @State private var draft = ""
    @State private var keyDraft = ""
    @State private var showingConnection = true
    /// How much of the conversation's top and bottom the floating bars cover, so its content can rest clear of them.
    @State private var topInset: CGFloat = 0
    @State private var bottomInset: CGFloat = 0

    var body: some View {
        // The conversation fills the window and scrolls *under* two floating glass bars, so the glass has something to refract.
        // The bars are overlays, not safe-area insets: macOS draws its own lighter backdrop band across a top inset.
        conversation
            .overlay(alignment: .top) {
                topBar.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { topInset = $0 }
            }
            .overlay(alignment: .bottom) {
                bottomBar.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bottomInset = $0 }
            }
            .frame(minWidth: 340, idealWidth: 400, minHeight: 460, idealHeight: 600)
            .modifier(GlassWindowBackground())
            .onAppear {
                showingConnection = agent.preset.needsKey && !agent.hasKey
                agent.refreshModels()          // what the service offers now
            }
    }

    /// The header, and under it the connection settings when they are open.
    private var topBar: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                header
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassPanel(cornerRadius: 20)
                if showingConnection {
                    connection
                        .padding(14)
                        .glassPanel(cornerRadius: 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
        }
        .animation(.smooth(duration: 0.25), value: showingConnection)
    }

    /// What is wrong, the switch for editing, and the box the question is typed in.
    private var bottomBar: some View {
        GlassGroup(spacing: 8) {
            VStack(spacing: 8) {
                if !agent.error.isEmpty {
                    Text(agent.error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .glassPanel(cornerRadius: 16, tint: .red, tintOpacity: 0.12)
                        .textSelection(.enabled)
                }
                editing
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .glassPanel(cornerRadius: 18)
                input
            }
            .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Agent").font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingConnection.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
                .help(showingConnection ? "Hide the connection settings" : "Show the connection settings")
            Button { agent.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Clear the conversation")
                .disabled(agent.messages.count <= 1)
        }
    }

    private var status: String {
        if agent.preset.needsKey && !agent.hasKey { return "\(agent.preset.name): no key yet" }
        return "\(agent.preset.name) · \(agent.model)"
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Service", selection: $agent.providerID) {
                ForEach(agent.presets) { Text($0.name).tag($0.id) }
            }
            if agent.providerID == AgentPreset.custom.id {
                TextField("Address, e.g. https://example.com/v1", text: $agent.baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            if agent.preset.needsKey {
                if agent.hasKey {
                    HStack {
                        Image(systemName: "key.fill").foregroundStyle(.green)
                        Text("Key saved in \(agent.keyLocation)").font(.callout)
                        Spacer()
                        Button("Remove") { agent.removeKey() }
                    }
                } else {
                    HStack {
                        SecureField("API key", text: $keyDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Get one at \(agent.preset.keyHelp). It is kept in the system's secure storage and sent only to this service.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(agent.preset.keyHelp).font(.caption).foregroundStyle(.secondary)
            }
            // Under the key, and only once there is one (a local service needs none): the model has nothing to be chosen from before that.
            if !agent.preset.needsKey || agent.hasKey {
                HStack {
                    if agent.availableModels.isEmpty {
                        // The service did not say (or has not yet): the name is typed.
                        TextField("Model", text: $agent.model)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $agent.model) {
                            // A name typed earlier that the list does not show stays choosable.
                            if !agent.availableModels.contains(agent.model) { Text(agent.model).tag(agent.model) }
                            ForEach(agent.availableModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if agent.isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { agent.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Ask the service for its models again")
                    }
                }
                if !agent.modelsHint.isEmpty {
                    Text(agent.modelsHint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func saveKey() {
        agent.setKey(keyDraft)
        keyDraft = ""                                  // not kept here
        showingConnection = false
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(agent.messages.enumerated()), id: \.offset) { index, message in
                        bubble(message).id(index)
                    }
                    if agent.isSending {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(agent.currentAction.isEmpty ? "Thinking…" : agent.currentAction).foregroundStyle(.secondary) }
                            .id("thinking")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .contentMargins(.top, topInset, for: .scrollContent)           // rests below the bars, scrolls under them
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .contentMargins(.top, topInset, for: .scrollIndicators)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            .defaultScrollAnchor(.bottom)          // opens at the latest message, not under the bars at the top
            .scrollEdgeEffectHiddenIfAvailable()
            .onChange(of: agent.messages.count) {
                withAnimation { proxy.scrollTo(agent.messages.count - 1, anchor: .bottom) }
            }
            .onChange(of: agent.isSending) {
                if agent.isSending { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: AgentMessage) -> some View {
        if message.role == .tool {
            // What the agent did to the project: a small line, not a speech bubble.
            Label(message.text, systemImage: message.failed ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(message.failed ? Color.orange : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .textSelection(.enabled)
        } else {
            speech(message)
        }
    }

    private func speech(_ message: AgentMessage) -> some View {
        let fromUser = message.role == .user
        return HStack {
            if fromUser { Spacer(minLength: 40) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .glassPanel(cornerRadius: 18, tint: fromUser ? .accentColor : nil, tintOpacity: fromUser ? 0.28 : 0.10)
            if !fromUser { Spacer(minLength: 40) }
        }
    }

    /// Whether the agent may change the project. It can always read it.
    private var editing: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $agent.canEdit) {
                Text("Allow editing the project").font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text(agent.toolsRefused
                 ? "The service would not take tools\(agent.toolsRefusal.isEmpty ? "" : " (\(agent.toolsRefusal))"), so the agent cannot see or change the project. Choosing another model tries again."
                 : agent.canEdit
                     ? "The agent can read and change the open project. Undo takes a change back."
                     : "The agent can read the open project, which is sent to the service as it looks, but cannot change it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The question, in a glass field with a round send button.
    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask the agent…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.leading, 6)
                .padding(.vertical, 6)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 18, height: 18)
            }
            .glassButtonStyle(prominent: true)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.defaultAction)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.isSending)
            .help("Send")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassPanel(cornerRadius: 24)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        agent.send(text)
        // Kept if it could not be sent (no key yet), so nothing typed is lost.
        if agent.isSending { draft = "" }
    }
}

// MARK: - Glass helpers for this window

/// The window itself is translucent, so the desktop shows faintly through behind the glass.
private struct GlassWindowBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.thinMaterial, for: .window)
        } else {
            content.background(.thinMaterial)
        }
    }
}

private extension View {
    /// Lets the conversation run right under the glass bars, with no blurred band (and hard edge) of the system's own at the bars' border.
    @ViewBuilder
    func scrollEdgeEffectHiddenIfAvailable() -> some View {
        if #available(macOS 26.0, *) { scrollEdgeEffectHidden(true, for: .vertical) } else { self }
    }
}
#endif
