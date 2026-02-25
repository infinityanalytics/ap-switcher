import Foundation
import Combine
import CoreWLAN
import Security
import CoreLocation

class WiFiMonitor: ObservableObject {
    @Published var signalStrength: Int = 0
    @Published var noiseLevel: Int = 0
    @Published var ssid: String = "Unknown"
    @Published var bssid: String = ""
    @Published var channel: Int = 0
    @Published var channelBand: String = ""
    @Published var isConnected: Bool = false
    @Published var hasLocationAccess: Bool = false
    @Published var locationAuthorized: Bool = false
    /// Master enable switch. When false, all polling/scanning/roaming halts.
    @Published var monitoringEnabled: Bool = true
    @Published var autoRoamEnabled: Bool = true
    @Published var isRoaming: Bool = false
    @Published var roamThreshold: Int = 10
    @Published var pollInterval: TimeInterval = 5
    @Published var scanInterval: TimeInterval = 30
    @Published var scanOnWeakSignalEnabled: Bool = true
    /// Trigger an immediate scan when current RSSI is <= this threshold.
    @Published var weakSignalThreshold: Int = -70
    /// If enabled, the app may read the Wi‑Fi password from Keychain as a fallback during roaming.
    /// Disabled by default to avoid password prompts on launch.
    @Published var allowKeychainPasswordFallback: Bool = false
    @Published var roamHistory: [RoamEvent] = []
    @Published var availableAPs: [AccessPoint] = []
    @Published var signalHistory: [SignalSample] = []
    @Published var lastCheckTime: Date = Date()
    @Published var lastScanTime: Date = Date()
    
    
    private var timer: Timer?
    private var scanTimer: Timer?
    private var roamCooldownUntil: Date = Date.distantPast
    private let roamCooldownDuration: TimeInterval = 30
    private let wifiClient = CWWiFiClient.shared()
    private let clLocationManager = CLLocationManager()
    private let historyWindow: TimeInterval = 5 * 60
    private var didKickoffScanAfterLocation = false
    private var scanGeneration: Int = 0
    private let weakSignalScanCooldown: TimeInterval = 15
    private var lastWeakSignalScanRequest: Date = .distantPast
    private var lastScanNetworksByBSSID: [String: CWNetwork] = [:]
    
    private struct DifferentialSnapshot {
        let date: Date
        let ssid: String
        let bestBSSID: String
        let bestRSSI: Int
        let secondBSSID: String
        let secondRSSI: Int
    }
    
    private var differentialSnapshot: DifferentialSnapshot?
    
    var maxHistorySamples: Int {
        max(1, Int(historyWindow / max(1, pollInterval)))
    }

    var appBuildInfo: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
        let ts = (Bundle.main.object(forInfoDictionaryKey: "BuildTimestamp") as? String)
        let suffix = ts.map { " (\($0))" } ?? ""
        return "\(version) (\(build))\(suffix)"
    }
    
    struct SignalSample: Identifiable {
        let id = UUID()
        let date: Date
        let rssi: Int
        let noise: Int
    }
    
    struct RoamEvent: Identifiable {
        let id = UUID()
        let date: Date
        let fromBSSID: String
        let toBSSID: String
        let signalBefore: Int
        let signalAfter: Int
    }
    
    struct AccessPoint: Identifiable, Equatable {
        var id: String { bssid }
        let ssid: String
        let bssid: String
        let rssi: Int
        let channel: Int
        let band: String
        let isCurrent: Bool
    }
    
    var signalIcon: String {
        if !isConnected { return "wifi.slash" }
        switch signalStrength {
        case -50...0: return "wifi"
        case -65...(-51): return "wifi"
        case -75...(-66): return "wifi.exclamationmark"
        default: return "wifi.exclamationmark"
        }
    }

    /// Menu bar icon. Swaps to an "in progress" icon during roaming.
    var menuBarIcon: String {
        if isRoaming { return "arrow.triangle.2.circlepath" }
        return signalIcon
    }
    
    var signalText: String {
        if !isConnected { return "--" }
        return "\(signalStrength)"
    }
    
    /// Short label for the menu bar: AP name (max 3 chars) or dBm number
    var menuBarLabel: String {
        if !isConnected { return "--" }
        if isRoaming { return "🔄" }
        if let name = apNames[bssid], !name.isEmpty {
            return String(name.prefix(3))
        }
        return "\(signalStrength)"
    }
    
    var signalQuality: String {
        if !isConnected { return "Disconnected" }
        switch signalStrength {
        case -30...0: return "Excellent"
        case -50...(-31): return "Very Good"
        case -60...(-51): return "Good"
        case -70...(-61): return "Fair"
        case -80...(-71): return "Weak"
        default: return "Very Weak"
        }
    }
    
    var snr: Int {
        signalStrength - noiseLevel
    }
    
    /// Only returns APs matching the current SSID. Returns empty if no location access.
    var sameNetworkAPs: [AccessPoint] {
        guard hasLocationAccess else { return [] }
        if ssid != "Unknown" && ssid != "Not Connected" && !ssid.hasPrefix("WiFi (") {
            return availableAPs.filter { $0.ssid == ssid }
        }
        return []
    }
    
    var betterAPs: [AccessPoint] {
        guard isConnected else { return [] }
        return sameNetworkAPs
            .filter { !$0.isCurrent && $0.rssi > signalStrength + roamThreshold }
            .sorted { $0.rssi > $1.rssi }
    }

    /// Delta (dB) between best and next-best AP on this network.
    ///
    /// This is a hybrid value:
    /// - best/next-best are snapped from the last full scan
    /// - the connected AP's RSSI is live-updated from `checkWiFi()`
    ///
    /// This makes the displayed differential "tick" with current RSSI changes even
    /// when we aren't scanning continuously.
    var bestVsNextBestDelta: Int? {
        guard let snap = differentialSnapshot else { return nil }
        // Ensure we don't show a stale snapshot for a different SSID.
        guard snap.ssid == ssid else { return nil }
        
        var best = snap.bestRSSI
        var second = snap.secondRSSI
        
        // If the current connection is one of the top-2 from the last scan, use the
        // live RSSI for that entry so the delta changes as signalStrength changes.
        if bssid == snap.bestBSSID {
            best = signalStrength
        } else if bssid == snap.secondBSSID {
            second = signalStrength
        }
        
        return best - second
    }
    
    init() {
        UserDefaults.standard.register(defaults: [
            "monitoringEnabled": true,
            "autoRoamEnabled": true,
            "scanOnWeakSignalEnabled": true,
            "allowKeychainPasswordFallback": false
        ])
        loadSettings()
        if monitoringEnabled {
            startMonitoring()
        }
    }
    
    func startMonitoring() {
        guard monitoringEnabled else { return }
        checkWiFi()
        scanForAPs()
        rescheduleTimers()
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        scanTimer?.invalidate()
        scanTimer = nil
        scanGeneration &+= 1
    }
    
    func pauseTimers() {
        timer?.invalidate()
        timer = nil
        scanTimer?.invalidate()
        scanTimer = nil
    }
    
    func resumeTimers() {
        if monitoringEnabled {
            rescheduleTimers()
        }
    }
    
    private func rescheduleTimers() {
        guard monitoringEnabled else { return }
        let poll = max(1, pollInterval)
        let scan = max(5, scanInterval)
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: poll, repeats: true) { [weak self] _ in
            self?.checkWiFi()
        }
        
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scan, repeats: true) { [weak self] _ in
            self?.scanForAPs()
        }
    }
    
    func applyIntervals(pollInterval: TimeInterval, scanInterval: TimeInterval) {
        self.pollInterval = max(1, pollInterval)
        self.scanInterval = max(5, scanInterval)
        saveSettings()
        if monitoringEnabled {
            rescheduleTimers()
        }
    }
    
    func setMonitoringEnabled(_ enabled: Bool) {
        monitoringEnabled = enabled
        saveSettings()
        if enabled {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }
    
    func checkWiFi() {
        guard monitoringEnabled else { return }
        lastCheckTime = Date()

        let auth = clLocationManager.authorizationStatus
        locationAuthorized = (auth == .authorizedAlways || auth == .authorized || auth.rawValue == 4)
        
        guard let interface = wifiClient.interface() else {
            isConnected = false
            ssid = "No WiFi Interface"
            signalStrength = 0
            return
        }
        
        let rssi = interface.rssiValue()
        let noise = interface.noiseMeasurement()
        let ch = interface.wlanChannel()
        
        if rssi == 0 && ch == nil {
            isConnected = false
            ssid = "Not Connected"
            signalStrength = 0
            noiseLevel = 0
            channel = 0
            return
        }
        
        signalStrength = rssi
        noiseLevel = noise
        isConnected = true
        
        if let wlanCh = ch {
            channel = wlanCh.channelNumber
            channelBand = bandName(for: wlanCh)
        }
        
        // SSID/BSSID require Location Services
        if let currentSSID = interface.ssid() {
            ssid = currentSSID
            hasLocationAccess = true
        } else {
            hasLocationAccess = false
            didKickoffScanAfterLocation = false
            if ssid == "Unknown" || ssid == "Not Connected" {
                ssid = "WiFi (\(channelBand))"
            }
        }
        
        if let currentBSSID = interface.bssid() {
            bssid = currentBSSID
        }

        // Intentionally do NOT touch Keychain automatically on launch.
        
        // As soon as Location access becomes available, kick off a scan immediately
        // (don't wait for the next scan timer tick).
        if monitoringEnabled && hasLocationAccess && !didKickoffScanAfterLocation {
            didKickoffScanAfterLocation = true
            scanForAPs()
        }
        
        // If signal is weak, trigger a scan immediately (rate-limited) so we can
        // re-evaluate other AP strengths without waiting for the next scan tick.
        if monitoringEnabled,
           scanOnWeakSignalEnabled,
           hasLocationAccess,
           isConnected,
           signalStrength <= weakSignalThreshold {
            let now = Date()
            if now.timeIntervalSince(lastWeakSignalScanRequest) >= weakSignalScanCooldown,
               now.timeIntervalSince(lastScanTime) >= weakSignalScanCooldown {
                lastWeakSignalScanRequest = now
                scanForAPs()
            }
        }
        
        // Record signal history
        let sample = SignalSample(date: Date(), rssi: rssi, noise: noise)
        signalHistory.append(sample)
        if signalHistory.count > maxHistorySamples {
            signalHistory.removeFirst(signalHistory.count - maxHistorySamples)
        }
        
        refreshCurrentAPFlag()
        
        // Auto-roam check
        if monitoringEnabled && autoRoamEnabled && isConnected && !isRoaming && Date() > roamCooldownUntil {
            if let bestAP = betterAPs.first {
                roamToAP(bestAP)
            }
        }
    }
    
    private func bandName(for channel: CWChannel) -> String {
        let chNum = channel.channelNumber
        if chNum <= 14 { return "2.4GHz" }
        if chNum <= 177 && chNum >= 36 {
            if channel.channelBand == .band6GHz { return "6GHz" }
            return "5GHz"
        }
        return "\(chNum)"
    }
    
    func scanForAPs() {
        guard monitoringEnabled else { return }
        lastScanTime = Date()
        
        let auth = clLocationManager.authorizationStatus
        locationAuthorized = (auth == .authorizedAlways || auth == .authorized || auth.rawValue == 4 || hasLocationAccess)
        guard locationAuthorized else { return }
        guard let interface = wifiClient.interface() else { return }
        
        let generation = scanGeneration
        let capturedSSID = ssid
        let capturedSignal = signalStrength
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Always use a passive (nil) scan. Directed scans
                // (scanForNetworks(withName:)) send probe requests for a
                // specific SSID, but many routers/APs silently ignore them
                // and return 0 results. A passive scan listens for beacons
                // from all networks and reliably finds nearby APs.
                let networks = try interface.scanForNetworks(withName: nil)
                let currentBSSID = interface.bssid() ?? ""
                let currentChannel = interface.wlanChannel()?.channelNumber ?? 0
                
                var aps: [AccessPoint] = []
                var networksByBSSID: [String: CWNetwork] = [:]
                
                for network in networks {
                    if let bssid = network.bssid, !bssid.isEmpty {
                        networksByBSSID[bssid] = network
                    }
                    let ch = network.wlanChannel
                    let chNum = ch?.channelNumber ?? 0
                    let band: String
                    if let c = ch {
                        band = self.bandName(for: c)
                    } else {
                        band = "?"
                    }
                    
                    let isCurrent: Bool
                    if !currentBSSID.isEmpty, let nBSSID = network.bssid, !nBSSID.isEmpty {
                        isCurrent = nBSSID == currentBSSID
                    } else {
                        isCurrent = chNum == currentChannel && network.rssiValue == capturedSignal
                    }
                    
                    let ap = AccessPoint(
                        ssid: network.ssid ?? "Hidden",
                        bssid: network.bssid ?? "Unknown",
                        rssi: network.rssiValue,
                        channel: chNum,
                        band: band,
                        isCurrent: isCurrent
                    )
                    aps.append(ap)
                }
                
                // Deduplicate by BSSID (keep strongest signal)
                var seen: [String: Int] = [:]
                var deduped: [AccessPoint] = []
                for ap in aps {
                    if let idx = seen[ap.bssid] {
                        if ap.rssi > deduped[idx].rssi {
                            deduped[idx] = ap
                        }
                    } else {
                        seen[ap.bssid] = deduped.count
                        deduped.append(ap)
                    }
                }
                aps = deduped
                
                aps.sort {
                    if $0.channel != $1.channel {
                        return $0.channel < $1.channel
                    }
                    return $0.bssid < $1.bssid
                }
                
                DispatchQueue.main.async {
                    guard self.monitoringEnabled, self.scanGeneration == generation else { return }
                    self.availableAPs = aps
                    self.lastScanNetworksByBSSID = networksByBSSID
                    
                    // Update differential snapshot from the scan results (same-network only).
                    let same = aps.filter { $0.ssid == self.ssid }
                        .sorted { $0.rssi > $1.rssi }
                    if same.count >= 2,
                       let bestBSSID = same[0].bssid as String?,
                       let secondBSSID = same[1].bssid as String? {
                        self.differentialSnapshot = DifferentialSnapshot(
                            date: Date(),
                            ssid: self.ssid,
                            bestBSSID: bestBSSID,
                            bestRSSI: same[0].rssi,
                            secondBSSID: secondBSSID,
                            secondRSSI: same[1].rssi
                        )
                    } else {
                        self.differentialSnapshot = nil
                    }

                    // If auto-roam is enabled, evaluate immediately after a scan completes.
                    // This avoids waiting up to `pollInterval` for the next check tick and
                    // ensures the decision uses the freshest AP scan results.
                    if self.monitoringEnabled,
                       self.autoRoamEnabled,
                       self.isConnected,
                       !self.isRoaming,
                       Date() > self.roamCooldownUntil,
                       let best = self.betterAPs.first {
                        self.roamToAP(best)
                    }
                }
            } catch {
                print("Scan error: \(error)")
            }
        }
    }
    
    func roamToAP(_ ap: AccessPoint) {
        guard let interface = wifiClient.interface() else { return }
        
        // Called from UI or auto-roam; update immediately so menu bar reflects action.
        if isRoaming { return }
        isRoaming = true
        
        if !ap.bssid.isEmpty, ap.bssid != "Unknown", ap.bssid == bssid {
            // Defensive: don't "roam" to the current AP.
            isRoaming = false
            return
        }

        let oldBSSID = bssid
        let oldSignal = signalStrength
        let expectedToBSSID = ap.bssid
        
        let cachedTargetNetwork: CWNetwork? = {
            guard !ap.bssid.isEmpty, ap.bssid != "Unknown" else { return nil }
            return lastScanNetworksByBSSID[ap.bssid]
        }()
        
        roamCooldownUntil = Date().addingTimeInterval(roamCooldownDuration)
        let capturedSSID = ssid
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                let targetNetwork: CWNetwork
                if let cached = cachedTargetNetwork {
                    targetNetwork = cached
                } else {
                    let networks = try interface.scanForNetworks(withName: capturedSSID.hasPrefix("WiFi (") ? nil : capturedSSID)
                    
                    guard let found = networks.first(where: {
                        if !ap.bssid.isEmpty && ap.bssid != "Unknown" {
                            return $0.bssid == ap.bssid
                        }
                        return $0.wlanChannel?.channelNumber == ap.channel && $0.rssiValue == ap.rssi
                    }) else {
                        print("Could not find target AP")
                        DispatchQueue.main.async {
                            self.isRoaming = false
                        }
                        return
                    }
                    targetNetwork = found
                }

                do {
                    try self.associatePreferSavedCredentials(interface: interface, network: targetNetwork, ssid: capturedSSID)
                    
                    DispatchQueue.main.async {
                        self.checkWiFi()
                        self.refreshCurrentAPFlag()
                        let actualToBSSID = self.bssid
                        if !actualToBSSID.isEmpty, actualToBSSID == oldBSSID {
                            // No-op roam; don't pollute history.
                            self.isRoaming = false
                            return
                        }
                        let event = RoamEvent(
                            date: Date(),
                            fromBSSID: oldBSSID,
                            toBSSID: actualToBSSID.isEmpty ? expectedToBSSID : actualToBSSID,
                            signalBefore: oldSignal,
                            signalAfter: self.signalStrength
                        )
                        self.roamHistory.insert(event, at: 0)
                        if self.roamHistory.count > 20 {
                            self.roamHistory = Array(self.roamHistory.prefix(20))
                        }
                        self.scanForAPs()
                        self.isRoaming = false
                    }
                } catch {
                    print("Roam error: \(error)")
                    DispatchQueue.main.async {
                        self.isRoaming = false
                    }
                }
            } catch {
                print("Roam error: \(error)")
                DispatchQueue.main.async {
                    self.isRoaming = false
                }
            }
        }
    }
    
    private func refreshCurrentAPFlag() {
        let currentBSSID = bssid
        availableAPs = availableAPs.map { ap in
            AccessPoint(
                ssid: ap.ssid,
                bssid: ap.bssid,
                rssi: ap.bssid == currentBSSID ? signalStrength : ap.rssi,
                channel: ap.channel,
                band: ap.band,
                isCurrent: ap.bssid == currentBSSID
            )
        }
    }

    func manualRoamTo(_ ap: AccessPoint) {
        roamCooldownUntil = Date.distantPast
        roamToAP(ap)
    }
    
    private func getWiFiPassword(for ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "AirPort",
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
    
    private func associatePreferSavedCredentials(interface: CWInterface, network: CWNetwork, ssid: String) throws {
        // First try roaming without any password. For a network we're already on,
        // credentials should already be saved and macOS can roam without prompting.
        var firstError: Error?
        do {
            try interface.associate(to: network, password: nil)
            return
        } catch {
            // Fall back to cached/passworded association if needed.
            firstError = error
        }
        
        guard allowKeychainPasswordFallback else {
            if let firstError { throw firstError }
            try interface.associate(to: network, password: nil)
            return
        }
        
        if let password = getWiFiPassword(for: ssid) {
            try interface.associate(to: network, password: password)
            return
        }
        
        // Last resort: rethrow an error from a passwordless attempt
        if let firstError { throw firstError }
        try interface.associate(to: network, password: nil)
    }
    
    func restartWiFi() {
        var interfaceName = "en0"
        if let interface = wifiClient.interface(), let name = interface.interfaceName {
            interfaceName = name
        }
        
        let offTask = Process()
        offTask.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        offTask.arguments = ["-setairportpower", interfaceName, "off"]
        
        do {
            try offTask.run()
            offTask.waitUntilExit()
            Thread.sleep(forTimeInterval: 2)
            
            let onTask = Process()
            onTask.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            onTask.arguments = ["-setairportpower", interfaceName, "on"]
            try onTask.run()
            onTask.waitUntilExit()
        } catch {
            print("Error restarting WiFi: \(error)")
        }
    }
    
    func manualRestart() {
        restartWiFi()
    }
    
    // MARK: - AP Naming
    
    /// Map of BSSID -> friendly name, persisted in UserDefaults
    @Published var apNames: [String: String] = [:]
    
    func nameForAP(_ ap: AccessPoint) -> String? {
        apNames[ap.bssid]
    }
    
    func setName(_ name: String, forBSSID bssid: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespaces).prefix(64))
        if trimmed.isEmpty {
            apNames.removeValue(forKey: bssid)
        } else {
            apNames[bssid] = trimmed
        }
        saveSettings()
    }
    
    func acronymForBSSID(_ bssid: String, maxLen: Int = 4) -> String {
        let limit = max(1, maxLen)
        if let name = apNames[bssid], !name.isEmpty {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(limit)).uppercased()
            }
        }
        if bssid.isEmpty { return "--" }
        // Fallback: last 4 hex chars of BSSID (e.g. ":A1B2")
        let cleaned = bssid.replacingOccurrences(of: ":", with: "")
        return String(cleaned.suffix(min(limit, cleaned.count))).uppercased()
    }
    
    // MARK: - Settings Persistence
    
    private func loadSettings() {
        monitoringEnabled = UserDefaults.standard.bool(forKey: "monitoringEnabled")
        autoRoamEnabled = UserDefaults.standard.bool(forKey: "autoRoamEnabled")
        scanOnWeakSignalEnabled = UserDefaults.standard.bool(forKey: "scanOnWeakSignalEnabled")
        allowKeychainPasswordFallback = UserDefaults.standard.bool(forKey: "allowKeychainPasswordFallback")
        if let saved = UserDefaults.standard.object(forKey: "roamThreshold") as? Int {
            roamThreshold = saved
        }
        if let saved = UserDefaults.standard.dictionary(forKey: "apNames") as? [String: String] {
            apNames = saved
        }
        if let savedPoll = UserDefaults.standard.object(forKey: "pollInterval") as? Double {
            pollInterval = max(1, savedPoll)
        }
        if let savedScan = UserDefaults.standard.object(forKey: "scanInterval") as? Double {
            scanInterval = max(5, savedScan)
        }
        if let savedWeak = UserDefaults.standard.object(forKey: "weakSignalThreshold") as? Int {
            weakSignalThreshold = savedWeak
        }
    }
    
    func saveSettings() {
        UserDefaults.standard.set(monitoringEnabled, forKey: "monitoringEnabled")
        UserDefaults.standard.set(roamThreshold, forKey: "roamThreshold")
        UserDefaults.standard.set(autoRoamEnabled, forKey: "autoRoamEnabled")
        UserDefaults.standard.set(apNames, forKey: "apNames")
        UserDefaults.standard.set(pollInterval, forKey: "pollInterval")
        UserDefaults.standard.set(scanInterval, forKey: "scanInterval")
        UserDefaults.standard.set(scanOnWeakSignalEnabled, forKey: "scanOnWeakSignalEnabled")
        UserDefaults.standard.set(weakSignalThreshold, forKey: "weakSignalThreshold")
        UserDefaults.standard.set(allowKeychainPasswordFallback, forKey: "allowKeychainPasswordFallback")
    }
}
