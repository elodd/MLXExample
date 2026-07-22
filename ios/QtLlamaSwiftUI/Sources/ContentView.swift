import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        ZStack {
            Color(red: 0.067, green: 0.075, blue: 0.094).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                Text("Qt MLX Llama")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 1))

                Text("On-device inference with MLX")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                modelSection
                conversation
                composer

                Text(viewModel.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .preferredColorScheme(.dark)
        .onChange(of: viewModel.isModelReady) { _, isReady in
            guard isReady else {
                isComposerFocused = false
                return
            }
            Task { @MainActor in
                await Task.yield()
                guard viewModel.isModelReady else { return }
                isComposerFocused = true
            }
        }
    }

    private var modelSection: some View {
        VStack(spacing: 5) {
            HStack {
                Text(viewModel.modelName)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("Download model") {
                    viewModel.downloadModel()
                }
                .font(.system(size: 11, weight: .semibold))
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.46, green: 0.35, blue: 0.91))
                .frame(width: 120, height: 30)
                .disabled(!viewModel.canDownload)
            }

            ProgressView(value: Double(viewModel.progress), total: 100)
                .tint(Color(red: 0.47, green: 0.84, blue: 0.78))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Model download progress")
                .accessibilityValue("\(viewModel.progress) percent")
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if viewModel.messages.isEmpty {
                        Text("Start a conversation with your local model.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(viewModel.messages) { message in
                        MessageView(message: message).id(message.id)
                    }
                }
                .padding(16)
            }
            .background(Color(red: 0.102, green: 0.118, blue: 0.149))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(red: 0.19, green: 0.22, blue: 0.275)))
            .onChange(of: viewModel.messages) { _, messages in
                guard let last = messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message your model…", text: $viewModel.draft, axis: .vertical)
                .focused($isComposerFocused)
                .lineLimit(1...4)
                .padding(10)
                .background(Color(red: 0.102, green: 0.118, blue: 0.149))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(red: 0.19, green: 0.22, blue: 0.275)))
                .disabled(!viewModel.isModelReady || viewModel.isGenerating)
                .onSubmit { viewModel.send() }

            Button("Send") { viewModel.send() }
                .fontWeight(.semibold)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.46, green: 0.35, blue: 0.91))
                .disabled(!viewModel.canSend)
        }
    }
}

private struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(author)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(color)
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var author: String {
        switch message.author {
        case .user: "You"
        case .model: "Llama"
        case .error: "Model error"
        }
    }

    private var color: Color {
        switch message.author {
        case .user: Color(red: 0.47, green: 0.84, blue: 0.78)
        case .model: Color(red: 0.73, green: 0.66, blue: 1)
        case .error: Color(red: 1, green: 0.56, blue: 0.56)
        }
    }
}

#Preview {
    ContentView()
}
