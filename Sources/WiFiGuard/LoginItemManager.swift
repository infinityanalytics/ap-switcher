import Foundation
import ServiceManagement

class LoginItemManager: ObservableObject {
    @Published var isEnabled: Bool = false
    
    init() {
        let status = SMAppService.mainApp.status
        if status == .notRegistered && !UserDefaults.standard.bool(forKey: "loginItemConfigured") {
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
            do {
                try SMAppService.mainApp.register()
                isEnabled = true
            } catch {
                print("Auto-register login item error: \(error)")
                isEnabled = false
            }
        } else {
            isEnabled = status == .enabled
        }
    }
    
    func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
                isEnabled = false
            } else {
                try SMAppService.mainApp.register()
                isEnabled = true
            }
        } catch {
            print("Login item error: \(error)")
        }
    }
    
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
