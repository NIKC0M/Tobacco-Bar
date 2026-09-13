import SwiftUI

/// A labelled number with an optional caption. Used across Today and Trends so
/// the same metric always reads the same way.
struct MetricTile: View {
    var title: String
    var value: String
    var caption: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Circular readiness gauge. The ring is deliberately desaturated at low
/// confidence — a number the app doesn't trust shouldn't look authoritative.
struct ReadinessRing: View {
    var score: Double
    var band: ReadinessBand
    var confidence: Double

    private var color: Color {
        let base: Color
        switch band {
        case .primed: base = .green
        case .ready: base = .mint
        case .moderate: base = .orange
        case .compromised: base = .red
        }
        return base.opacity(0.45 + 0.55 * min(max(confidence, 0), 1))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.01, score / 100))
                .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: score)
            VStack(spacing: 2) {
                Text("\(Int(score.rounded()))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text(band.display)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 140, height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Readiness \(Int(score.rounded())) out of 100, \(band.display)")
    }
}

struct SectionCard<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct AdjustmentBadge: View {
    var action: AdjustmentAction

    private var tint: Color {
        switch action {
        case .keep: return .secondary
        case .reduce, .rest: return .orange
        case .increase: return .green
        case .swap, .move: return .blue
        }
    }

    var body: some View {
        Text(action.display)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

extension Double {
    var oneDecimal: String { String(format: "%.1f", self) }
    var signedInt: String { String(format: "%+.0f", self) }
}
