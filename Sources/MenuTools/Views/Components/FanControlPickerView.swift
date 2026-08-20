import SwiftUI

struct FanControlPickerView: View {
    @ObservedObject var fanControl: FanControlManager
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            MacToolsCard(padding: 14, cornerRadius: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    headerView

                    if !fanControl.hasFans {
                        fanlessNoticeView
                    } else {
                        modeSwitcherView
                        detailContentView
                    }
                }
            }
            .frame(width: 320)
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.96),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .shadow(color: .black.opacity(0.35), radius: 25, y: 10)
        }
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "fan.fill")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.teal)
                .frame(width: 30, height: 30)
                .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1.5) {
                Text("Fan Control & Curve")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .medium))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private var headerSubtitle: String {
        guard fanControl.hasFans else {
            return "No Fans detected (\(fanControl.modelIdentifier))"
        }
        let tempStr = "\(Int(fanControl.currentSensorTemp))°C"
        if fanControl.controlMode == .auto {
            return "Actual: \(fanControl.currentRPM) RPM · \(tempStr) (Auto)"
        }
        let isRamping = abs(fanControl.targetRPM - fanControl.currentRPM) > 120
        if isRamping {
            return "Actual: \(fanControl.currentRPM) ↗ \(fanControl.targetRPM) RPM · \(tempStr)"
        }
        return "Speed: \(fanControl.currentRPM) RPM · \(tempStr)"
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
            Text("macOS Automatic Thermal Policy")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
            Text("The system dynamically regulates fan speeds via thermalmonitord.")
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
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
