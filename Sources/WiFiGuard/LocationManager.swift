import CoreLocation
import Foundation

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    
    override init() {
        super.init()
        manager.delegate = self
        authorizationStatus = manager.authorizationStatus
    }
    
    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }
    
    var isAuthorized: Bool {
        let raw = authorizationStatus.rawValue
        // .authorizedAlways (3), .authorized (3), .authorizedWhenInUse (4, unavailable in macOS SDK
        // but returned at runtime on macOS 14+ when requestWhenInUseAuthorization() was used)
        return raw == 3 || raw == 4
    }
}
