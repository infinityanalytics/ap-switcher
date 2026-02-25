import SwiftUI

struct MenuBarView: View {
    @ObservedObject var monitor: WiFiMonitor
    @StateObject var locationManager = LocationManager()
    @State private var showSettings = false
    @AppStorage("popoverHeight") private var popoverHeight: Double = 600
    @State private var dragStartHeight: Double?
    @State private var contentHeight: Double = .greatestFiniteMagnitude
    
    var body: some View {
        VStack(spacing: 0) {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Text("AP Switcher")
                    .font(.headline)
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { monitor.monitoringEnabled },
                    set: { monitor.setMonitoringEnabled($0) }
                ))
                    .labelsHidden()
                    .toggleStyle(GreenSwitchStyle())
            }
            
            Divider()

            let enabled = monitor.monitoringEnabled

            let dimOpacity: Double = enabled ? 1 : 0.15

            VStack(alignment: .leading, spacing: 10) {
                // Current connection
                VStack(alignment: .leading, spacing: 6) {
                if monitor.isRoaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Switching to best AP...")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .foregroundColor(Color(red: 0.36, green: 0.22, blue: 0.78))
                }
                
                HStack {
                    Text("Network:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(monitor.ssid)
                        .fontWeight(.medium)
                }
                
                HStack {
                    Text("Signal:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(monitor.signalStrength) dBm")
                        .fontWeight(.medium)
                        .foregroundColor(signalColor)
                    Text("(\(monitor.signalQuality))")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }

                HStack {
                    Text("Differential:")
                        .foregroundColor(.secondary)
                    Spacer()
                    if let delta = monitor.bestVsNextBestDelta {
                        Text("\(delta > 0 ? "+" : "")\(delta) dB")
                            .fontWeight(.medium)
                            .monospacedDigit()
                            .foregroundColor(differentialColor(delta))
                    } else {
                        Text("--")
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                }
                
                HStack {
                    Text("Channel:")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(monitor.channel) (\(monitor.channelBand))")
                        .font(.caption)
                    Spacer().frame(width: 8)
                    Text("SNR:")
                        .foregroundColor(.secondary)
                    Text("\(monitor.snr) dB")
                        .font(.caption)
                }
                }
                .font(.system(size: 12))
            
            // Signal History Graph
            if !monitor.signalHistory.isEmpty {
                Divider()
                SignalHistoryGraph(samples: monitor.signalHistory)
                    .frame(height: 80)
            }
            
            // Access Points
            Divider()
            
            if !monitor.locationAuthorized {
                // No location access -- prompt
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.caption)
                        Text("Access Points")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Text("0 networks")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Button(action: { locationManager.requestPermission() }) {
                        HStack {
                            Image(systemName: "location.circle")
                            Text("Grant Location to see access points")
                            Spacer()
                            Image(systemName: "arrow.right.circle")
                        }
                        .font(.caption)
                        .padding(8)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                    Text("Access Points")
                        .font(.caption)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(monitor.sameNetworkAPs.count) on this network")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                APGraphView(monitor: monitor)
            }
            
            // Recent activity
            if !monitor.roamHistory.isEmpty {
                Divider()
                
                Text("Recent Activity")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ForEach(monitor.roamHistory.prefix(3)) { event in
                    HStack {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("Roamed: \(monitor.acronymForBSSID(event.fromBSSID))→\(monitor.acronymForBSSID(event.toBSSID))  \(event.signalBefore)→\(event.signalAfter) dBm")
                            .font(.caption2)
                        Spacer()
                        Text(event.date, style: .time)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            }
            .disabled(!enabled)
            .opacity(dimOpacity)
            .saturation(enabled ? 1 : 0)
            .grayscale(enabled ? 0 : 1)

            Divider()
            
            DisclosureGroup(isExpanded: $showSettings) {
                SettingsSection(monitor: monitor)
            } label: {
                HStack {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
                .font(.caption)
            }

            Divider()

            VStack(spacing: 8) {
                if !monitor.betterAPs.isEmpty {
                    Button(action: {
                        if let best = monitor.betterAPs.first {
                            monitor.manualRoamTo(best)
                        }
                    }) {
                        HStack(spacing: 6) {
                            if monitor.isRoaming {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.swap")
                            }
                            Text(monitor.isRoaming ? "Switching..." : "Switch to Best AP")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.36, green: 0.22, blue: 0.78))
                    .controlSize(.small)
                    .disabled(monitor.isRoaming || !enabled)
                }

                HStack(spacing: 8) {
                    ActionButton(title: "Scan APs", icon: "antenna.radiowaves.left.and.right", action: { monitor.scanForAPs() })
                        .disabled(!enabled || monitor.isRoaming)

                    ActionButton(title: "Restart WiFi", icon: "arrow.clockwise", action: { monitor.manualRestart() })
                }
            }
            .opacity(enabled ? 1 : 0.25)
            .saturation(enabled ? 1 : 0)
            .grayscale(enabled ? 0 : 1)

            Divider()

            HStack(spacing: 0) {
                Button(action: {
                    let bundlePath = Bundle.main.bundleURL.path
                    let pid = String(ProcessInfo.processInfo.processIdentifier)
                    let script = """
                        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                        open "$2"
                        """
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/sh")
                    task.arguments = ["-c", script, "--", pid, bundlePath]
                    try? task.run()
                    NSApplication.shared.terminate(nil)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Restart")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("Quit")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
            .padding()
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .scrollIndicators(.automatic)
        .fixedSize(horizontal: false, vertical: !showSettings)
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }

        if showSettings {
            ResizeHandle()
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if dragStartHeight == nil { dragStartHeight = popoverHeight }
                            let newHeight = (dragStartHeight ?? popoverHeight) + value.translation.height
                            popoverHeight = min(max(newHeight, 300), contentHeight)
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
        }
        }
        .frame(width: 320, height: showSettings ? popoverHeight : nil)
        .animation(.easeInOut(duration: 0.2), value: showSettings)
    }
    
    var statusColor: Color {
        if !monitor.isConnected { return .gray }
        if monitor.signalStrength < -80 { return .red }
        if monitor.signalStrength < -70 { return .yellow }
        return .green
    }
    
    var signalColor: Color {
        switch monitor.signalStrength {
        case -50...0: return .green
        case -60...(-51): return .green
        case -70...(-61): return .yellow
        case -80...(-71): return .orange
        default: return .red
        }
    }
    
    func differentialColor(_ delta: Int) -> Color {
        switch delta {
        case 15...: return .green
        case 8...14: return .yellow
        case 1...7: return .orange
        default: return .red
        }
    }
}

// MARK: - Signal History Graph

struct SignalHistoryGraph: View {
    let samples: [WiFiMonitor.SignalSample]
    
    let minDBm: Double = -90
    let maxDBm: Double = -20
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Signal History")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                
                ZStack(alignment: .topLeading) {
                    ForEach([-30, -50, -70, -90], id: \.self) { level in
                        let y = yPosition(for: level, height: h)
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(Color.gray.opacity(0.15), lineWidth: 0.5)
                        
                        Text("\(level)")
                            .font(.system(size: 7))
                            .foregroundColor(.gray.opacity(0.5))
                            .position(x: 12, y: y - 6)
                    }
                    
                    let barWidth = max(2, (w / CGFloat(60)) - 1)
                    let displaySamples = Array(samples.suffix(60))
                    
                    ForEach(Array(displaySamples.enumerated()), id: \.element.id) { index, sample in
                        let x = w - CGFloat(displaySamples.count - index) * (barWidth + 1)
                        let barH = (Double(sample.rssi) - minDBm) / (maxDBm - minDBm) * Double(h)
                        let clampedH = max(1, min(barH, Double(h)))
                        
                        RoundedRectangle(cornerRadius: 1)
                            .fill(barColor(for: sample.rssi))
                            .frame(width: barWidth, height: CGFloat(clampedH))
                            .position(x: x + barWidth / 2, y: h - CGFloat(clampedH) / 2)
                    }
                }
            }
            
            HStack {
                Text("5m ago")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
                Spacer()
                Text("now")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
            }
        }
    }
    
    func yPosition(for dBm: Int, height: CGFloat) -> CGFloat {
        let normalized = (Double(dBm) - minDBm) / (maxDBm - minDBm)
        return height * (1 - CGFloat(normalized))
    }
    
    func barColor(for rssi: Int) -> Color {
        switch rssi {
        case -50...0: return .green
        case -60...(-51): return .green.opacity(0.8)
        case -70...(-61): return .yellow
        case -80...(-71): return .orange
        default: return .red
        }
    }
}

// MARK: - AP Graph View (same-network only, with dBm labels on bars)

struct APGraphView: View {
    @ObservedObject var monitor: WiFiMonitor
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let aps = monitor.sameNetworkAPs
            
            if !aps.isEmpty {
                ForEach(aps) { ap in
                    APBarRow(ap: ap, monitor: monitor)
                }
            } else {
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(.secondary)
                        Text("Scanning for access points...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
    }
}

struct APBarRow: View {
    let ap: WiFiMonitor.AccessPoint
    @ObservedObject var monitor: WiFiMonitor
    
    var friendlyName: String? {
        monitor.nameForAP(ap)
    }
    
    var displayRSSI: Int {
        ap.isCurrent ? monitor.signalStrength : ap.rssi
    }
    
    var barFraction: Double {
        min(max((Double(displayRSSI) + 90) / 70.0, 0.03), 1.0)
    }
    
    private func promptForName() {
        let currentName = friendlyName ?? ""
        let bssid = ap.bssid
        let channel = ap.channel
        let band = ap.band
        
        monitor.pauseTimers()
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Name Access Point"
            alert.informativeText = "Ch \(channel) \(band) — \(bssid)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            field.stringValue = currentName
            field.placeholderString = "e.g. Office, Kitchen, Upstairs…"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            
            NSApp.activate(ignoringOtherApps: true)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                let name = field.stringValue
                monitor.setName(name, forBSSID: bssid)
            }
            
            monitor.resumeTimers()
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Label row
            HStack(spacing: 4) {
                if ap.isCurrent {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "circle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.3))
                }
                
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        if let name = friendlyName {
                            Text(name)
                                .font(.system(size: 10, weight: ap.isCurrent ? .bold : .semibold))
                                .foregroundColor(ap.isCurrent ? .primary : .primary.opacity(0.8))
                        }
                        
                        Text("Ch \(ap.channel)")
                            .font(.system(size: friendlyName != nil ? 9 : 10, weight: friendlyName != nil ? .regular : (ap.isCurrent ? .bold : .regular)))
                            .foregroundColor(friendlyName != nil ? .secondary.opacity(0.6) : (ap.isCurrent ? .primary : .secondary))
                        
                        Text(ap.band)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.7))
                        
                        if ap.isCurrent {
                            Text("connected")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundColor(.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Button(action: { promptForName() }) {
                            Text(friendlyName != nil ? "rename" : "name this AP")
                                .font(.system(size: 8))
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                Spacer()
                
                if !ap.isCurrent {
                    EmptyView()
                }
            }
            
            // Signal bar with dBm label overlaid
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.12))
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geo.size.width * barFraction)
                    
                    let barW = geo.size.width * barFraction
                    let label = "\(displayRSSI) dBm"
                    
                    if barW > 60 {
                        Text(label)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 0)
                            .position(x: barW - 26, y: geo.size.height / 2)
                    } else {
                        Text(label)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .position(x: barW + 28, y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 16)
        }
        .padding(.vertical, 1)
    }
    
    var barColor: Color {
        let rssi = displayRSSI
        if ap.isCurrent {
            switch rssi {
            case -50...0: return .green
            case -60...(-51): return .green.opacity(0.8)
            case -70...(-61): return .yellow
            case -80...(-71): return .orange
            default: return .red
            }
        }
        switch rssi {
        case -50...0: return .blue
        case -60...(-51): return .blue.opacity(0.8)
        case -70...(-61): return .blue.opacity(0.6)
        case -80...(-71): return .blue.opacity(0.4)
        default: return .blue.opacity(0.3)
        }
    }
}

// MARK: - Settings Section

struct SettingsSection: View {
    @ObservedObject var monitor: WiFiMonitor
    @StateObject private var loginItem = LoginItemManager()
    @State private var roamThresholdValue: Double = 10
    @State private var pollIntervalValue: Double = 5
    @State private var scanIntervalValue: Double = 30
    @State private var scanOnWeakSignalEnabled: Bool = true
    @State private var weakSignalThresholdValue: Double = -70
    @State private var autoRoamEnabledValue: Bool = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { loginItem.isEnabled },
                set: { _ in loginItem.toggle() }
            )) {
                Text("Run at startup")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            
            Divider()

            Toggle(isOn: $autoRoamEnabledValue) {
                HStack {
                    Text("Auto-switch to better AP")
                        .font(.caption)
                    Text("(+\(monitor.roamThreshold)dB)")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: autoRoamEnabledValue) { _, newValue in
                monitor.autoRoamEnabled = newValue
                monitor.saveSettings()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Roam threshold:")
                        .font(.caption)
                    Spacer()
                    Text("+\(Int(roamThresholdValue)) dB")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                
                Slider(value: $roamThresholdValue, in: 5...25, step: 5)
                    .controlSize(.small)
                    .onChange(of: roamThresholdValue) { oldValue, newValue in
                        monitor.roamThreshold = Int(newValue)
                        monitor.saveSettings()
                    }
                
                Text("Switch AP if another is this much stronger")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Poll interval:")
                        .font(.caption)
                    Spacer()
                    Text("\(Int(pollIntervalValue))s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                
                Slider(value: $pollIntervalValue, in: 1...10, step: 1)
                    .controlSize(.small)
                    .onChange(of: pollIntervalValue) { _, newValue in
                        monitor.applyIntervals(pollInterval: newValue, scanInterval: scanIntervalValue)
                    }
                
                Text("How often to read signal/noise (lower = more responsive)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Scan interval:")
                        .font(.caption)
                    Spacer()
                    Text("\(Int(scanIntervalValue))s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
                
                Slider(value: $scanIntervalValue, in: 10...120, step: 10)
                    .controlSize(.small)
                    .onChange(of: scanIntervalValue) { _, newValue in
                        monitor.applyIntervals(pollInterval: pollIntervalValue, scanInterval: newValue)
                    }
                
                Text("How often to scan for access points (higher = less battery use)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            Toggle(isOn: $scanOnWeakSignalEnabled) {
                Text("Scan when signal is weak")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: scanOnWeakSignalEnabled) { _, newValue in
                monitor.scanOnWeakSignalEnabled = newValue
                monitor.saveSettings()
            }
            
            if scanOnWeakSignalEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weak signal threshold:")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(weakSignalThresholdValue)) dBm")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    
                    Slider(value: $weakSignalThresholdValue, in: -90...(-50), step: 5)
                        .controlSize(.small)
                        .onChange(of: weakSignalThresholdValue) { _, newValue in
                            monitor.weakSignalThreshold = Int(newValue)
                            monitor.saveSettings()
                        }
                    
                    Text("When current signal drops below this, trigger an immediate scan (rate-limited)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            HStack(spacing: 8) {
                SignalDot(color: .green, label: ">-60")
                SignalDot(color: .yellow, label: "-60–70")
                SignalDot(color: .orange, label: "-70–80")
                SignalDot(color: .red, label: "<-80")
            }
            .font(.caption2)
            
            Divider()
            
            Text("Build: \(monitor.appBuildInfo)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
        .padding(.top, 6)
        .onAppear {
            roamThresholdValue = Double(monitor.roamThreshold)
            pollIntervalValue = Double(max(1, monitor.pollInterval))
            scanIntervalValue = Double(max(10, monitor.scanInterval))
            scanOnWeakSignalEnabled = monitor.scanOnWeakSignalEnabled
            weakSignalThresholdValue = Double(monitor.weakSignalThreshold)
            autoRoamEnabledValue = monitor.autoRoamEnabled
        }
    }
}

struct ActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct GreenSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 8)
                .fill(isOn ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 32, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
                        .frame(width: 14, height: 14)
                        .padding(2)
                }
                .animation(.easeInOut(duration: 0.15), value: isOn)
        }
        .onTapGesture { configuration.isOn.toggle() }
    }
}

struct ResizeHandle: View {
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 3)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: Double = 0
    static func reduce(value: inout Double, nextValue: () -> Double) {
        value = max(value, nextValue())
    }
}

struct SignalDot: View {
    let color: Color
    let label: String
    
    var body: some View {
        HStack(spacing: 2) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundColor(.secondary)
        }
    }
}
