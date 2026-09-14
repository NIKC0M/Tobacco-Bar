import SwiftUI

struct SuuntoSetupView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: state.suuntoStatus.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(state.suuntoStatus.isHealthy ? .green : .orange)
                    Text(SuuntoLink.message(for: state.suuntoStatus))
                        .font(.callout)
                }
            } header: {
                Text("Status")
            }

            Section {
                ForEach(SuuntoLink.setupSteps.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .frame(width: 20, height: 20)
                            .background(.quaternary, in: Circle())
                        Text(SuuntoLink.setupSteps[index]).font(.callout)
                    }
                }
            } header: {
                Text("How the chain works")
            } footer: {
                Text("Your watch syncs to the Suunto app, the Suunto app writes into Apple Health, and this app reads from Apple Health. Nothing here talks to Suunto's servers — that keeps your data on your phone and means any watch or app that writes to Apple Health works the same way.")
            }

            Section("Sources currently writing to Health") {
                if state.workoutSources.isEmpty {
                    Text("No workouts found yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(state.workoutSources) { source in
                        LabeledContent(source.name, value: "\(source.count) sessions")
                    }
                }
            }

            Section {
                Button("Refresh from Apple Health") {
                    Task { await state.refresh() }
                }
            }
        }
        .navigationTitle("Suunto sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}
