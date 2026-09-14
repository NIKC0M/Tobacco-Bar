import SwiftUI
import Charts

struct TrendsView: View {
    @EnvironmentObject private var state: AppState
    @State private var window = 42

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Window", selection: $window) {
                        Text("6 weeks").tag(42)
                        Text("3 months").tag(90)
                        Text("6 months").tag(180)
                    }
                    .pickerStyle(.segmented)

                    fitnessChart
                    loadChart
                    recoveryChart
                    splitChart
                    logSection
                }
                .padding()
            }
            .navigationTitle("Trends")
        }
    }

    private var curves: [LoadPoint] { Array(state.curves.suffix(window)) }

    private var days: [DailyMetrics] { Array(state.series.suffix(window)) }

    private var fitnessChart: some View {
        SectionCard(title: "Fitness, fatigue, form", systemImage: "chart.xyaxis.line") {
            Chart {
                ForEach(curves) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Form", point.tsb))
                        .foregroundStyle(point.tsb >= 0
                                         ? Color.green.opacity(0.15)
                                         : Color.red.opacity(0.15))
                    LineMark(x: .value("Date", point.date), y: .value("Fitness", point.ctl))
                        .foregroundStyle(by: .value("Series", "Fitness (CTL)"))
                    LineMark(x: .value("Date", point.date), y: .value("Fatigue", point.atl))
                        .foregroundStyle(by: .value("Series", "Fatigue (ATL)"))
                }
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(.secondary.opacity(0.3))
                    .lineStyle(StrokeStyle(dash: [3, 3]))
            }
            .chartForegroundStyleScale([
                "Fitness (CTL)": Color.blue,
                "Fatigue (ATL)": Color.orange
            ])
            .chartLegend(position: .bottom, spacing: 8)
            .frame(height: 200)

            Text("Fitness is your 42-day load average, fatigue the 7-day. Form is the gap between them: strongly negative means you're buried, positive means you're fresh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var loadChart: some View {
        SectionCard(title: "Daily load", systemImage: "chart.bar.fill") {
            Chart(days) { day in
                BarMark(x: .value("Date", day.date, unit: .day),
                        y: .value("Endurance", day.enduranceLoad))
                    .foregroundStyle(by: .value("Type", "Endurance"))
                BarMark(x: .value("Date", day.date, unit: .day),
                        y: .value("Strength", day.strengthLoad))
                    .foregroundStyle(by: .value("Type", "Strength"))
            }
            .chartForegroundStyleScale([
                "Endurance": Color.teal,
                "Strength": Color.purple
            ])
            .chartLegend(position: .bottom, spacing: 8)
            .frame(height: 160)
        }
    }

    private var recoveryChart: some View {
        SectionCard(title: "Recovery signals", systemImage: "heart.text.square") {
            Chart {
                ForEach(days.filter { $0.hrvSDNNms != nil }) { day in
                    LineMark(x: .value("Date", day.date),
                             y: .value("HRV", day.hrvSDNNms ?? 0),
                             series: .value("Metric", "HRV (ms)"))
                        .foregroundStyle(.pink)
                        .interpolationMethod(.monotone)
                }
                ForEach(days.filter { $0.restingHR != nil }) { day in
                    LineMark(x: .value("Date", day.date),
                             y: .value("RHR", day.restingHR ?? 0),
                             series: .value("Metric", "Resting HR"))
                        .foregroundStyle(.indigo)
                        .interpolationMethod(.monotone)
                }
            }
            .frame(height: 160)

            if days.compactMap(\.hrvSDNNms).isEmpty {
                Text("No HRV in Apple Health yet. Suunto writes it overnight once the Health link is on — check the Watch sync card on Today.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var splitChart: some View {
        SectionCard(title: "Weekly split", systemImage: "scalemass") {
            Chart(weeklyTotals) { row in
                BarMark(x: .value("Week", row.weekStart, unit: .weekOfYear),
                        y: .value("Endurance", row.endurance))
                    .foregroundStyle(Color.teal)
                BarMark(x: .value("Week", row.weekStart, unit: .weekOfYear),
                        y: .value("Strength", row.strength))
                    .foregroundStyle(Color.purple)
            }
            .frame(height: 140)

            Text("Hybrid training lives or dies on this ratio. A target of \(Int((1 - state.profile.strengthEmphasis) * 100))/\(Int(state.profile.strengthEmphasis * 100)) is set in your profile; you're currently at \(Int(state.summary.enduranceShare * 100))/\(Int(state.summary.strengthShare * 100)).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var weeklyTotals: [WeeklyTotal] {
        TrainingLoadEngine.weeklyTotals(from: days)
    }

    private var logSection: some View {
        SectionCard(title: "Coaching history", systemImage: "clock.arrow.circlepath") {
            if state.coachLog.isEmpty {
                Text("No coaching passes yet. Tap the sparkle on Today to run one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.coachLog.prefix(8)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2.weight(.semibold))
                                Spacer()
                                Text(entry.usedClaude ? "Claude" : "Rules")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.summary).font(.caption)
                            Text("Readiness \(Int(entry.readinessScore)) · \(entry.todayAction)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                    }
                }
            }
        }
    }
}
