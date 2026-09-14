import SwiftUI

/// Manual session entry.
///
/// The important field here is RPE. Strength work barely moves heart rate, so
/// without a perceived-effort number the load model systematically
/// under-counts lifting — which then makes the acute:chronic ratio look safe
/// while the athlete digs a hole.
struct LogWorkoutView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    var prefill: PlannedSession?

    init(prefill: PlannedSession? = nil) {
        self.prefill = prefill
    }

    @State private var modality: Modality = .strength
    @State private var start = Date()
    @State private var minutes = 60
    @State private var rpe = 7
    @State private var avgHR = ""
    @State private var distanceKm = ""
    @State private var notes = ""
    @State private var lifts: [LiftEntry] = []
    @State private var newLiftName = ""
    @State private var newSets = 3
    @State private var newReps = 5
    @State private var newWeight = 100.0

    var body: some View {
        Form {
            Section("Session") {
                Picker("Type", selection: $modality) {
                    ForEach(Modality.allCases) { Label($0.display, systemImage: $0.symbol).tag($0) }
                }
                DatePicker("Started", selection: $start)
                Stepper("\(minutes) minutes", value: $minutes, in: 5...300, step: 5)
            }

            Section {
                Stepper("RPE \(rpe) — \(rpeLabel)", value: $rpe, in: 1...10)
            } header: {
                Text("Effort")
            } footer: {
                Text("How hard the whole session felt, judged about 30 minutes after finishing. This is what prices strength work into your load — without it, lifting barely registers.")
            }

            Section("Optional detail") {
                TextField("Average heart rate", text: $avgHR)
                    .keyboardType(.numberPad)
                if modality.isEndurance {
                    TextField("Distance (km)", text: $distanceKm)
                        .keyboardType(.decimalPad)
                }
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
            }

            if modality == .strength {
                Section("Lifts") {
                    ForEach(lifts) { lift in
                        HStack {
                            Text(lift.name)
                            Spacer()
                            Text("\(lift.sets)×\(lift.reps) @ \(Int(lift.weightKg))kg")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { lifts.remove(atOffsets: $0) }

                    VStack(spacing: 8) {
                        TextField("Lift name", text: $newLiftName)
                        HStack {
                            Stepper("\(newSets) sets", value: $newSets, in: 1...12)
                            Stepper("\(newReps) reps", value: $newReps, in: 1...30)
                        }
                        HStack {
                            Text("\(Int(newWeight)) kg")
                            Slider(value: $newWeight, in: 10...300, step: 2.5)
                        }
                        Button("Add lift") {
                            guard !newLiftName.isEmpty else { return }
                            lifts.append(LiftEntry(name: newLiftName, sets: newSets, reps: newReps, weightKg: newWeight))
                            newLiftName = ""
                        }
                        .disabled(newLiftName.isEmpty)
                    }
                }
            }

            Section {
                LabeledContent("Estimated load", value: "\(Int(estimatedLoad))")
                if !lifts.isEmpty {
                    LabeledContent("Tonnage", value: "\(Int(lifts.reduce(0) { $0 + $1.tonnage })) kg")
                }
            }
        }
        .navigationTitle("Log session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .onAppear(perform: applyPrefill)
    }

    private var rpeLabel: String {
        switch rpe {
        case 1...2: return "very easy"
        case 3...4: return "easy"
        case 5...6: return "moderate"
        case 7...8: return "hard"
        default: return "maximal"
        }
    }

    private var estimatedLoad: Double {
        var record = draftRecord()
        let result = TrainingLoadEngine.load(for: record, profile: state.profile)
        record.load = result.value
        return record.load
    }

    private func applyPrefill() {
        guard let prefill else { return }
        modality = prefill.modality
        minutes = max(5, prefill.effectiveDurationMin)
        start = prefill.date
        rpe = prefill.effectiveIntent.isHard ? 8 : 5
    }

    private func draftRecord() -> WorkoutRecord {
        WorkoutRecord(
            id: prefill.map { "manual-\($0.id.uuidString)" } ?? "manual-\(UUID().uuidString)",
            start: start,
            end: start.addingTimeInterval(Double(minutes) * 60),
            modality: modality,
            sourceName: "Manual entry",
            durationSec: Double(minutes) * 60,
            distanceMeters: Double(distanceKm).map { $0 * 1000 },
            avgHR: Double(avgHR),
            maxHR: nil,
            energyKcal: nil,
            elevationGainM: nil,
            rpe: rpe,
            notes: notes.isEmpty ? nil : notes,
            lifts: lifts
        )
    }

    private func save() {
        state.log(workout: draftRecord())
        dismiss()
    }
}
