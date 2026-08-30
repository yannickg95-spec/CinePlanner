//
//  OnSetLiveActivityWidget.swift
//  The Lock Screen banner + Dynamic Island for On-Set Mode. Renders purely from
//  the Activity's ContentState; the ‹ › buttons run OnSetStepIntent in the app.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct OnSetLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OnSetActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            OnSetLockScreenView(state: context.state)
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                // Expanded (long-press) — kept small: current setup + progress.
                DynamicIslandExpandedRegion(.leading) {
                    Text(s.current?.num ?? "—")
                        .font(.system(size: 15, weight: .heavy)).monospacedDigit()
                        .foregroundStyle(.tint)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(s.doneCount)/\(s.total)")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(s.current.map { line($0) } ?? "Day wrapped")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressBar(progress: s.progress)
                }
            } compactLeading: {
                Text(s.current?.num ?? "✓")
                    .font(.system(size: 13, weight: .heavy)).monospacedDigit()
                    .foregroundStyle(.tint)
            } compactTrailing: {
                Text("\(s.doneCount)/\(s.total)")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.secondary)
            } minimal: {
                RingView(progress: s.progress)
            }
            .keylineTint(.accentColor)
        }
    }

    private func line(_ s: OnSetSetup) -> String {
        [s.name, s.spec].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Lock Screen

private struct OnSetLockScreenView: View {
    let state: OnSetActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Project · day, then progress line.
            Text("\(state.projectName) · \(state.dayLabel)")
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            Text("\(state.doneCount) / \(state.total) setups · \(state.scenesCleared) of \(state.totalScenes) scenes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)

            // Progress bar flanked by step controls.
            HStack(spacing: 8) {
                StepButton(forward: false, disabled: state.doneCount == 0)
                ProgressBar(progress: state.progress)
                StepButton(forward: true, disabled: state.wrapped)
            }
            .padding(.top, 8)

            if let current = state.current {
                SetupRow(setup: current, eyebrow: "Now · \(current.scene)", accent: true)
                    .padding(.top, 8)
                if let next = state.upcoming.first {
                    CompactRow(setup: next, eyebrow: "Next")
                        .padding(.top, 6)
                }
            } else {
                SetupRow.wrapped
                    .padding(.top, 8)
            }
        }
    }
}

private struct SetupRow: View {
    let num: String
    let eyebrow: String
    let name: String
    let spec: String
    let accent: Bool
    let doneMark: Bool

    init(setup: OnSetSetup, eyebrow: String, accent: Bool) {
        self.num = setup.num; self.eyebrow = eyebrow
        self.name = setup.name; self.spec = setup.spec
        self.accent = accent; self.doneMark = false
    }
    private init(num: String, eyebrow: String, name: String, spec: String, accent: Bool, doneMark: Bool) {
        self.num = num; self.eyebrow = eyebrow; self.name = name
        self.spec = spec; self.accent = accent; self.doneMark = doneMark
    }

    static let wrapped = SetupRow(num: "✓", eyebrow: "Day wrapped",
                                  name: "All setups shot — nice work", spec: "",
                                  accent: true, doneMark: true)

    var body: some View {
        HStack(spacing: 9) {
            Text(num)
                .font(.system(size: 10.5, weight: .heavy)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((accent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.16)),
                            in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(eyebrow)
                    .font(.system(size: 9, weight: .heavy)).textCase(.uppercase)
                    .foregroundStyle(accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                nameLine
            }
            Spacer(minLength: 0)
        }
    }

    private var nameLine: some View {
        let hasName = !name.isEmpty, hasSpec = !spec.isEmpty
        return HStack(spacing: 4) {
            if hasName {
                Text(name).foregroundStyle(accent ? .primary : .secondary)
            }
            if hasSpec {
                Text(hasName ? "· \(spec)" : spec)
                    .foregroundStyle(accent ? .secondary : .tertiary)
            }
            if !hasName && !hasSpec {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12.5, weight: accent ? .bold : .semibold))
        .lineLimit(1)
    }
}

/// A single-line upcoming setup: badge · eyebrow · name/spec, all on one row so
/// two of them stack without pushing the banner past its height limit.
private struct CompactRow: View {
    let setup: OnSetSetup
    let eyebrow: String

    var body: some View {
        HStack(spacing: 8) {
            Text(setup.num)
                .font(.system(size: 10, weight: .heavy)).monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Color.secondary.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
            Text(eyebrow)
                .font(.system(size: 9, weight: .heavy)).textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Text(line)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var line: String {
        let parts = [setup.name, setup.spec].filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

private struct StepButton: View {
    let forward: Bool
    let disabled: Bool
    var body: some View {
        Button(intent: OnSetStepIntent(forward: forward)) {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 14, weight: .heavy))
                .frame(width: 34, height: 34)
                .foregroundStyle(.tint)
                .background(Color.accentColor.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }
}

private struct ProgressBar: View {
    let progress: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(.tint)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: 7)
    }
}

private struct RingView: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 18, height: 18)
    }
}
