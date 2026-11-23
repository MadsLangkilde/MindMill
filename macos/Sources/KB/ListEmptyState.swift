import SwiftUI

/// What an empty list says, at the top of the column where the rows would be. Lists never centre vertically.
struct ListEmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension ListEmptyState where Actions == EmptyView {
    init(title: String, systemImage: String, message: String? = nil) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}
