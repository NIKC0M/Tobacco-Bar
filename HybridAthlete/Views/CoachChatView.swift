import SwiftUI

struct CoachChatView: View {
    @EnvironmentObject private var state: AppState
    @State private var turns: [ClaudeClient.ChatTurn] = []
    @State private var draft = ""
    @State private var streaming = ""
    @State private var isStreaming = false
    @State private var error: String?

    private let starters = [
        "Why did you change today's session?",
        "Am I doing enough strength work for a hybrid block?",
        "My legs feel heavy on easy runs. What does the data say?",
        "How should I taper for my goal event?"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !state.settings.cloudCoachingEnabled {
                    disabledBanner
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if turns.isEmpty && streaming.isEmpty {
                                emptyState
                            }
                            ForEach(turns) { turn in
                                bubble(role: turn.role, text: turn.text).id(turn.id)
                            }
                            if !streaming.isEmpty {
                                bubble(role: .assistant, text: streaming).id("streaming")
                            }
                            if let error {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: streaming) { _, _ in
                        withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                    }
                }

                composer
            }
            .navigationTitle("Coach")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") {
                        turns = []; streaming = ""; error = nil
                    }
                    .disabled(turns.isEmpty)
                }
            }
        }
    }

    private var disabledBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text("Claude coaching is off. Turn it on in Settings — your training metrics are sent to Anthropic when you do.")
                .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about your own numbers")
                .font(.headline)
            Text("Every question is answered against your current snapshot: load, readiness, the last three weeks of sessions and this week's plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(starters, id: \.self) { starter in
                Button {
                    draft = starter
                    send()
                } label: {
                    Text(starter)
                        .font(.caption)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bubble(role: ClaudeClient.ChatTurn.Role, text: String) -> some View {
        HStack {
            if role == .user { Spacer(minLength: 40) }
            Text(text)
                .font(.callout)
                .padding(12)
                .background(role == .user ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
            if role == .assistant { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask your coach…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(isStreaming)
            Button {
                send()
            } label: {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || isStreaming
                      || !state.settings.cloudCoachingEnabled)
        }
        .padding()
        .background(.bar)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        draft = ""
        error = nil
        turns.append(.init(role: .user, text: text))
        isStreaming = true
        streaming = ""

        Task {
            do {
                for try await chunk in state.chatStream(history: turns) {
                    streaming += chunk
                }
                if !streaming.isEmpty {
                    turns.append(.init(role: .assistant, text: streaming))
                }
            } catch {
                self.error = error.localizedDescription
            }
            streaming = ""
            isStreaming = false
        }
    }
}
