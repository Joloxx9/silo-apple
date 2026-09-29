import SwiftUI

/// A typed percentage value (min...100). A slider makes the low end — where a
/// few percent is the difference between legible and invisible — fiddly to
/// hit; typing the number directly doesn't have that problem.
///
/// Shared by the Settings subtitle-appearance screen (iOS + macOS) and the
/// in-player subtitle-appearance sheet (iOS) so the two never drift on the
/// clamp, commit, or accessibility behavior.
struct PercentField: View {
    let label: String
    let accessibilityLabelText: String
    let min: Int
    let value: Int
    let onCommit: (Int) -> Void

    @State private var draft: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer()
            TextField("", text: $draft)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
            Text("%")
                .foregroundStyle(Color.siloSecondaryText)
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { _, newValue in
            if !focused { draft = String(newValue) }
        }
        // The number pad has no Done key, so dismissing the sheet or
        // navigating away while this field is still focused (swipe-away,
        // back navigation) never fires onSubmit or the focus-change commit
        // above — it just tears the view down with a typed-but-uncommitted
        // draft. onDisappear is the SwiftUI equivalent safety net.
        .onDisappear { commit() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue("\(value) percent")
    }

    private func commit() {
        guard let parsed = Int(draft) else {
            draft = String(value)
            return
        }
        let clamped = Swift.min(100, Swift.max(min, parsed))
        draft = String(clamped)
        if clamped != value {
            onCommit(clamped)
        }
    }
}
