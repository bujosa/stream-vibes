import SwiftUI

struct AIModelSelector: View {
    let provider: AIProvider
    @AppStorage private var model: String
    @State private var customMode = false

    init(provider: AIProvider) {
        self.provider = provider
        let existing = AIModelPreferences.value(for: provider.rawValue)
        _model = AppStorage(wrappedValue: existing, AIModelPreferences.key(for: provider.rawValue))
    }

    private var isCustom: Bool {
        customMode || (!model.isEmpty && !provider.modelOptions.contains { $0.id == model })
    }

    private var selection: Binding<String> {
        Binding(get: { isCustom ? "__custom__" : model }, set: { value in
            customMode = value == "__custom__"
            if !customMode { model = value }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Model", selection: selection) {
                Text(provider.isAPI ? "Recommended · \(provider.defaultModel)" : "Use CLI default").tag("")
                ForEach(provider.modelOptions) { option in
                    Text("\(option.name) · \(option.detail)").tag(option.id)
                }
                Divider()
                Text("Custom model…").tag("__custom__")
            }
            if isCustom {
                TextField("Model ID", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .accessibilityLabel("Custom model ID")
            }
            if let option = provider.modelOptions.first(where: { $0.id == (model.isEmpty ? provider.defaultModel : model) }), !isCustom {
                Text(option.detail).font(.caption).foregroundStyle(.secondary)
            }
            Text(provider.isAPI ? "Availability depends on your provider account. Model choice is remembered separately for each provider." : "Leave the default to use your CLI configuration. Ollama uses llama3.2 unless you choose an installed model.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
