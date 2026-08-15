import SwiftUI

struct AntiSleepTabView: View {
    @ObservedObject var antiSleep: AntiSleepManager

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Main Switch Card
                GlassCard {
                    VStack(spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Anti-Sleep Mode")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.primary)

                                Text(
                                    antiSleep.isActive
                                        ? "Preventing Mac from sleeping (\(antiSleep.statusText))"
                                        : "Mac will follow system sleep preferences"
                                )
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            }

                            Spacer()

                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { antiSleep.isActive },
                                    set: { _ in antiSleep.toggle() }
                                )
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                        }

                        if antiSleep.isActive {
                            HStack {
                                Image(systemName: "timer")
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                                Text("Time Remaining: \(antiSleep.statusText)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.orange)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12))
                            .cornerRadius(6)
                        }
                    }
                }

                // Duration Presets
                VStack(alignment: .leading, spacing: 6) {
                    Text("TIMER DURATION")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                    HStack(spacing: 6) {
                        ForEach(AntiSleepManager.durations, id: \.seconds) { dur in
                            Button(action: {
                                antiSleep.selectDuration(dur.seconds)
                            }) {
                                Text(dur.label)
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(
                                                antiSleep.selectedDuration == dur.seconds
                                                    ? Color.accentColor : Color.white.opacity(0.04))
                                    )
                                    .foregroundColor(antiSleep.selectedDuration == dur.seconds ? .white : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Options Card
                VStack(alignment: .leading, spacing: 6) {
                    Text("OPTIONS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keep Display Awake")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Prevents screen from turning off")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $antiSleep.preventDisplaySleep)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(8)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Prevent Lid-Closed Sleep")
                                    .font(.system(size: 12, weight: .medium))
                                Text("Requires sudo pmset privileges")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $antiSleep.preventLidSleep)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.02))
                        .cornerRadius(8)
                    }
                }
            }
            .padding(14)
        }
    }
}
