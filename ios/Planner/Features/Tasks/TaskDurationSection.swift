import SwiftUI

struct TaskDurationSection: View {
    @Binding var minutes: Int?
    @State private var customizing = false

    private var choices: [Int] { Array(Set([15, 30, 45, 60, 90, 120, 180] + (minutes.map { [$0] } ?? []))).sorted() }

    var body: some View {
        Section {
            Picker("Durée", selection: $minutes) {
                Text("Aucune").tag(Int?.none)
                ForEach(choices, id: \.self) { Text(DurationText.format($0)).tag(Int?.some($0)) }
            }
            Button("Durée personnalisée…") { customizing = true }
        }
        .sheet(isPresented: $customizing) { CustomDurationView(minutes: $minutes) }
    }
}

private struct CustomDurationView: View {
    @Binding var minutes: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    private var value: Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...1440).contains(value) else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Durée en minutes", text: $text)
                        .keyboardType(.numberPad)
                        .focused($focused)
                    if let value { Text(DurationText.format(value)).foregroundStyle(.secondary) }
                } footer: { Text("Entre 1 et 1 440 minutes (24 heures).") }
            }
            .navigationTitle("Durée personnalisée")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choisir") { if let value { minutes = value; dismiss() } }.disabled(value == nil)
                }
            }
            .onAppear { text = minutes.map(String.init) ?? ""; focused = true }
        }
    }
}
