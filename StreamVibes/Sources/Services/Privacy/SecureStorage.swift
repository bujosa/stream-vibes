import SwiftUI

@MainActor
@propertyWrapper
struct SecureStorage: DynamicProperty {
    @State private var store = CredentialStore.shared
    private let key: String

    init(_ key: String) {
        self.key = key
    }

    var wrappedValue: String {
        get { store.value(for: key) }
        nonmutating set { store.set(newValue, for: key) }
    }

    var projectedValue: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

private struct CredentialStorageAlert: ViewModifier {
    @State private var store = CredentialStore.shared

    func body(content: Content) -> some View {
        content.alert(
            "Credential storage",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.dismissError() } }
            )
        ) {
            Button("OK") { store.dismissError() }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

extension View {
    func credentialStorageAlert() -> some View {
        modifier(CredentialStorageAlert())
    }
}
