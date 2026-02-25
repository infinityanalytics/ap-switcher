import AppKit
import CoreLocation
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []
    let monitor = WiFiMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstanceLock.shared.acquire() else {
            if let bundleID = Bundle.main.bundleIdentifier,
               let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                existing.activate(options: [.activateAllWindows])
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }

        locationManager.delegate = self
        locationManager.requestWhenInUseAuthorization()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "AP Switcher"
        }

        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = NSHostingView(rootView: MenuBarView(monitor: monitor))

        monitor.objectWillChange
            .receive(on: DispatchQueue.main)
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshStatusItem() }
            }
            .store(in: &cancellables)

        refreshStatusItem()
    }

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }

        let color = signalColor()

        let wifiSymbol: String
        if !monitor.monitoringEnabled {
            wifiSymbol = "wifi.slash"
        } else if monitor.isRoaming {
            wifiSymbol = "arrow.triangle.2.circlepath"
        } else {
            wifiSymbol = monitor.signalIcon
        }
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let config = colorConfig.applying(sizeConfig)
        if let img = NSImage(systemSymbolName: wifiSymbol, accessibilityDescription: "AP Switcher")?
            .withSymbolConfiguration(config) {
            img.isTemplate = false
            button.image = img
            button.imagePosition = .imageLeading
        }

        let text: String
        if !monitor.monitoringEnabled {
            text = ""
        } else if !monitor.isConnected {
            text = ""
        } else if monitor.isRoaming {
            text = ""
        } else if let name = monitor.apNames[monitor.bssid], !name.isEmpty {
            text = String(name.prefix(3)).uppercased()
        } else {
            text = "\(monitor.signalStrength)"
        }

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: font
        ]
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func signalColor() -> NSColor {
        if !monitor.monitoringEnabled { return .gray }
        if monitor.isRoaming { return NSColor(red: 0.36, green: 0.22, blue: 0.78, alpha: 1.0) }
        if !monitor.isConnected { return .gray }
        switch monitor.signalStrength {
        case -50...0: return NSColor(srgbRed: 0.30, green: 0.78, blue: 0.30, alpha: 1.0)
        case -60...(-51): return NSColor(srgbRed: 0.30, green: 0.78, blue: 0.30, alpha: 1.0)
        case -70...(-61): return NSColor(srgbRed: 0.92, green: 0.80, blue: 0.20, alpha: 1.0)
        case -80...(-71): return NSColor(srgbRed: 0.95, green: 0.55, blue: 0.15, alpha: 1.0)
        default: return NSColor(srgbRed: 0.95, green: 0.25, blue: 0.22, alpha: 1.0)
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
