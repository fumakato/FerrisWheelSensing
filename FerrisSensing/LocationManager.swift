import CoreLocation
import Combine

struct FerrisWheelInfo: Decodable {
    let park: String
    let name: String
    let height_m: Double
    let lat: Double
    let lon: Double
}

struct FerrisWheelInfoRaw: Decodable {
    let park: String
    let name: String
    let height_m: Double?
    let lat: Double?
    let lon: Double?
}


final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentLocation: CLLocation?
    
    private let manager = CLLocationManager()
    private(set) var ferrisWheels: [FerrisWheelInfo] = []
    
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        
        loadFerrisWheelJSON()
    }
    
    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }
    
    // 位置取得コールバック
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        currentLocation = locations.last
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Location] error:", error)
    }
    
    // JSON 読み込み（ferriswheels.json をバンドルしておく）
    private func loadFerrisWheelJSON() {
        guard let url = Bundle.main.url(forResource: "ferriswheels", withExtension: "json") else {
            print("[FW] ferriswheels.json not found in bundle")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            
            // ① まずは全部 Optional で受ける
            let rawList = try JSONDecoder().decode([FerrisWheelInfoRaw].self, from: data)
            
            var valid: [FerrisWheelInfo] = []
            var skipped = 0
            
            for raw in rawList {
                // ② 必須項目がそろっていないレコードはスキップ
                guard
                    let h = raw.height_m,
                    let lat = raw.lat,
                    let lon = raw.lon
                else {
                    skipped += 1
                    print("[FW] skip invalid record:",
                          "\(raw.park) - \(raw.name)",
                          "height=\(String(describing: raw.height_m))",
                          "lat=\(String(describing: raw.lat))",
                          "lon=\(String(describing: raw.lon))")
                    continue
                }
                
                valid.append(
                    FerrisWheelInfo(
                        park: raw.park,
                        name: raw.name,
                        height_m: h,
                        lat: lat,
                        lon: lon
                    )
                )
            }
            
            self.ferrisWheels = valid
            print("[FW] loaded ferriswheels valid=\(valid.count) skipped=\(skipped)")
            
        } catch {
            print("[FW] failed to decode ferriswheels.json:", error)
        }
    }

    
    /// 距離制限なしで「最寄りの観覧車 + 距離」を返す
    func nearestFerrisWheelAny() -> (FerrisWheelInfo, CLLocationDistance)? {
        guard let loc = currentLocation, !ferrisWheels.isEmpty else { return nil }
        
        var best: FerrisWheelInfo?
        var bestDist: CLLocationDistance = .greatestFiniteMagnitude
        
        for fw in ferrisWheels {
            let fwLoc = CLLocation(latitude: fw.lat, longitude: fw.lon)
            let d = loc.distance(from: fwLoc)
            if d < bestDist {
                bestDist = d
                best = fw
            }
        }
        if let best = best {
            return (best, bestDist)
        }
        return nil
    }
    
    /// 「maxDistance m 以内にあればその最寄りを返す」ヘルパー
    func nearestFerrisWheel(within maxDistance: CLLocationDistance) -> (FerrisWheelInfo, CLLocationDistance)? {
        guard let (fw, dist) = nearestFerrisWheelAny() else { return nil }
        return dist <= maxDistance ? (fw, dist) : nil
    }
}
