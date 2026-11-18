import SwiftUI

struct FanControlPickerView: View {
    @ObservedObject var fanControl: FanControlManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine
            if !fanControl.hasFans {
                fanlessNoticeView
            } else {
                modeSwitcherView
                detailContentView
            }
        }
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(fanControl.hasFans ? "\(fanControl.currentRPM) RPM" : "No fans")
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
            Spacer(minLength: 8)
            Text(fanControl.hasFans ? "\(Int(fanControl.currentSensorTemp))°C" : fanControl.modelIdentifier)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var fanlessNoticeView: some View {
        HStack(spacing: 5) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 9))
                .foregroundStyle(.teal)
            Text("Fanless Mac (\(fanControl.modelIdentifier)) · Passive cooling")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var modeSwitcherView: some View {
        HStack(spacing: 4) {
            ForEach(FanControlMode.allCases) { mode in
                let isSelected = fanControl.controlMode == mode
                Button {
                    fanControl.selectControlMode(mode)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 9))
                        Text(mode.label)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity, minHeight: 26)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .background(
                        isSelected ? Color.teal.opacity(0.4) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isSelected ? Color.teal.opacity(0.6) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .suppressesFocusRing()
            }
        }
        .padding(2)
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var detailContentView: some View {
        switch fanControl.controlMode {
        case .auto:
            autoDetailView
        case .curve:
            curveDetailView
        case .constant:
            constantDetailView
        }
    }

    private var autoDetailView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS sets the speed")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }

    private var curveDetailView: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Sensor selector
            VStack(alignment: .leading, spacing: 3) {
                Text("Temperature Sensor")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(ThermalSensorGroup.allCases) { sensor in
                        Button {
                            fanControl.selectedSensor = sensor
                        } label: {
                            Label(sensor.rawValue, systemImage: sensor.icon)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: fanControl.selectedSensor.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.teal)
                        Text(fanControl.selectedSensor.rawValue)
                            .font(.system(size: 10.5, weight: .medium))
                        Spacer()
                        Text("\(Int(fanControl.currentSensorTemp))°C")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.teal)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.white.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
                .suppressesFocusRing()
            }

            // Temperature Thresholds (Start Temp & Max Temp)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Speed starts at")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Button {
                            if fanControl.curveStartTemp > 30 {
                                fanControl.curveStartTemp -= 1
                            }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .suppressesFocusRing()

                        Text("\(fanControl.curveStartTemp)°C")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 38, alignment: .center)

                        Button {
                            if fanControl.curveStartTemp < fanControl.curveMaxTemp - 5 {
                                fanControl.curveStartTemp += 1
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .suppressesFocusRing()
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Max speed at")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Button {
                            if fanControl.curveMaxTemp > fanControl.curveStartTemp + 5 {
                                fanControl.curveMaxTemp -= 1
                            }
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .suppressesFocusRing()

                        Text("\(fanControl.curveMaxTemp)°C")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 38, alignment: .center)

                        Button {
                            if fanControl.curveMaxTemp < 95 {
                                fanControl.curveMaxTemp += 1
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 18, height: 18)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .suppressesFocusRing()
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
            }

            // Live Curve Progress Bar
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Dynamic speed:")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(fanControl.currentSensorTemp))°C → \(fanControl.targetRPM) RPM")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.teal)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 6)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.teal, .cyan, .orange, .red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(
                                width: max(6, geo.size.width * CGFloat(fanControl.curveProgressRatio)),
                                height: 6
                            )
                    }
                }
                .frame(height: 6)
            }
            .padding(7)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private var constantDetailView: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Preset buttons
            HStack(spacing: 5) {
                ForEach(ConstantPreset.allCases) { preset in
                    let isSelected = fanControl.selectedPreset == preset
                    Button {
                        fanControl.selectPreset(preset)
                    } label: {
                        VStack(spacing: 1.5) {
                            Text(preset.label)
                                .font(.system(size: 10, weight: .medium))
                            Text(preset.caption)
                                .font(.system(size: 7.5))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(
                            isSelected ? Color.teal.opacity(0.2) : Color.white.opacity(0.04),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(
                                    isSelected ? Color.teal.opacity(0.5) : Color.white.opacity(0.06)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .suppressesFocusRing()
                }
            }

            // Fine tune slider
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Manual RPM")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(fanControl.targetRPM) RPM")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.teal)
                }
                Slider(
                    value: Binding(
                        get: { Double(fanControl.targetRPM) },
                        set: { fanControl.setCustomRPM(Int($0)) }
                    ),
                    in: Double(fanControl.minRPM)...Double(fanControl.maxRPM),
                    step: 50
                )
                .controlSize(.mini)
            }
            .padding(6)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
