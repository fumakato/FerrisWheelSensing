import Foundation
import CoreLocation

struct FerrisWheel: Codable, Identifiable {
    let id = UUID()
    let name: String
    let park: String
    let pref: String
    let status: String
    let height_m: Double
    let lat: Double?
    let lon: Double?
    
    var coordinate: CLLocationCoordinate2D? {
        guard let lat = lat, let lon = lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

final class FerrisWheelStore {
    static let shared = FerrisWheelStore()
    
    let wheels: [FerrisWheel]
    
    private init() {
        if let url = Bundle.main.url(forResource: "ferriswheels", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            do {
                let decoded = try JSONDecoder().decode([FerrisWheel].self, from: data)
                self.wheels = decoded
            } catch {
                print("FerrisWheel JSON decode error:", error)
                self.wheels = []
            }
        } else {
            print("FerrisWheel JSON not found in bundle.")
            self.wheels = []
        }
    }
}
