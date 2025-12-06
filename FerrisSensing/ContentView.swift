import SwiftUI

struct ContentView: View {
    @StateObject private var locationManager = LocationManager()
    @StateObject private var sensorManager = SensorManager.shared
    
    @State private var heightInfoText: String = "高さ: 未設定"
    @State private var locationInfoText: String = "位置情報取得中"
    @State private var nearestInfoText: String = "最寄り観覧車: 探索中..."
    
    // 位置情報リトライ用
    @State private var appLaunchTime: Date = Date()
    
    var body: some View {
        
//        //フィッティングできてるかテスト
//        Text("Ferris Test")
//            .onAppear {
//                NonlinearCosineFitter.runCosineFitTestFromBundle()
//        }

        ZStack {
            sensorManager.appPhase.backgroundColor
                .ignoresSafeArea()
            
            VStack(spacing: 16) {
                Text("観覧車センシング")
                    .font(.largeTitle)
                    .padding(.top, 32)
                
                Text(locationInfoText)
                    .font(.headline)
                
                Text(sensorManager.appPhase.title)
                    .font(.title2)
                    .padding(.bottom, 8)
                
                Text(heightInfoText)
                    .font(.subheadline)
                
                Text(nearestInfoText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                
                Divider().padding(.vertical, 16)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("センサ値（簡易表示）")
                        .font(.headline)
                    Text(String(format: "加速度ノルム: %.3f m/s²", sensorManager.latestAccNorm))
                    Text(String(format: "気圧: %.2f hPa", sensorManager.latestPressure_hPa))
                    
                    Text("状態: \(sensorManager.appPhase.description)")
                    Text("観覧車: \(sensorManager.currentWheelName)")
                    Text(String(format: "高さ: %.1f m", sensorManager.currentWheelHeight))
                    
                    // ★ 推定頂上時刻
                    if let tTop = sensorManager.estimatedTopTimeSec {
                        Text(String(format: "推定頂上時刻（乗車から）: %.1f s", tTop))
                    } else {
                        Text("推定頂上時刻（乗車から）: -- s")
                    }
                    
                    // ★ 頂上安定フラグ
                    Text("頂上安定: \(sensorManager.isTopStable ? "はい" : "いいえ")")
                }
                .padding()
                .background(Color.white.opacity(0.6))
                .cornerRadius(12)
                
                Spacer()
                
                Text("※高さが決まると自動で乗車判定を開始します")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal)
        }
        .onAppear {
            sensorManager.appPhase = .locating
            appLaunchTime = Date()
            
            // 最初の位置情報リクエスト
            locationManager.requestLocation()
            // 5秒間は位置情報をリトライし続ける
            scheduleLocationRetry()
        }
        .onChange(of: locationManager.currentLocation) { _ in
            // 位置が取れたらすぐに高さを決めて乗車判定へ
            decideFerrisWheelAndStart(forceFallback: false)
        }
    }
    
    /// 位置情報が取れない場合、アプリ起動から 5 秒間は再リクエストし続ける
    private func scheduleLocationRetry() {
        // すでに乗車判定フェーズに進んでいれば何もしない
        guard sensorManager.appPhase == .locating else { return }
        
        // もう位置が取れていればリトライ不要
        if locationManager.currentLocation != nil {
            return
        }
        
        let elapsed = Date().timeIntervalSince(appLaunchTime)
        if elapsed >= 5.0 {
            // 5秒経過しても位置が取れない → ここでフォールバック開始
            decideFerrisWheelAndStart(forceFallback: true)
            return
        }
        
        // まだ5秒以内 → 1秒後に再度 requestLocation + 再スケジュール
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // 再度位置情報リクエスト
            self.locationManager.requestLocation()
            // もう一度様子を見る
            self.scheduleLocationRetry()
        }
    }
    
    /// 一番近い観覧車を表示しつつ、
    /// 高さ設定は「1000m以内ならその観覧車」「なければ 40m」にする
    /// - forceFallback: true の場合は位置がなくても 40m で強制開始
    private func decideFerrisWheelAndStart(forceFallback: Bool) {
        // 一度開始したら二度目は実行しない
        guard sensorManager.appPhase == .locating else { return }
        
        // 位置がない & フォールバックも許可されていない → まだ待つ
        if locationManager.currentLocation == nil && !forceFallback {
            return
        }
        
        // まず「距離制限なし」で最寄り候補を求めて表示
        if let (nearest, dist) = locationManager.nearestFerrisWheelAny() {
            let name = "\(nearest.park) - \(nearest.name)"
            nearestInfoText = String(
                format: "最寄り候補: %@（約 %.0f m）", name, dist
            )
            
            // ★ ここを 300.0 → 1000.0 に変更 ★
            if dist <= 1000.0 {
                // 1000m 以内 → この観覧車を採用
                sensorManager.configure(height: nearest.height_m, displayName: name)
                heightInfoText = String(format: "高さ: %.1f m（最寄り観覧車）", nearest.height_m)
                locationInfoText = "観覧車: " + name
            } else {
                // 1000m より遠い → 高さ 40m の仮観覧車
                sensorManager.configure(height: 40.0, displayName: "不明な観覧車（仮:40m）")
                heightInfoText = "高さ: 40 m（近くに観覧車なし → デフォルト）"
                if let loc = locationManager.currentLocation {
                    locationInfoText = String(
                        format: "緯度: %.4f 経度: %.4f（最寄りは %.0f m 先）",
                        loc.coordinate.latitude, loc.coordinate.longitude, dist
                    )
                } else {
                    locationInfoText = "位置情報取得に失敗（観覧車データは読み込み済み）"
                }
            }
        } else {
            // 最寄り候補すら求められない（JSON 読み込み失敗など）
            nearestInfoText = "最寄り観覧車: 不明（観覧車データなし）"
            sensorManager.configure(height: 40.0, displayName: "不明な観覧車（仮:40m）")
            heightInfoText = "高さ: 40 m（デフォルト）"
            if locationManager.currentLocation == nil {
                locationInfoText = "位置情報取得に失敗 / 観覧車データなし"
            } else {
                locationInfoText = "観覧車データなし（ferriswheels.json 読み込み失敗）"
            }
        }
        
        // 高さが決まったら即、乗車判定フェーズへ
        sensorManager.startSensing()
    }
}
