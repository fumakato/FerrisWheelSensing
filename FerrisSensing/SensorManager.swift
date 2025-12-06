import Foundation
import CoreMotion
import CoreLocation
import UIKit


// パラメータ（あとで調整しやすいようにまとめておく）
fileprivate let ACC_STD_WINDOW_SEC: TimeInterval = 2.0      // 加速度ノルムの標準偏差を取る時間窓
fileprivate let ACC_STD_THRESH: Double = 0.06               // 静止とみなす標準偏差の上限
fileprivate let ACC_MIN_INTERVAL_SEC: TimeInterval = 5.0    // 静止区間として採用する最小長さ

fileprivate let MAX_WAIT_BEFORE_MOVE: TimeInterval = 60.0   // 座ってから動くまでの最大許容時間
fileprivate let T_MOVE_MARGIN_SEC: TimeInterval = 5.0       // t_move が静止区間終端から何秒先まで許容するか

fileprivate let BARO_MA_WINDOW_SEC: TimeInterval = 6.0      // 気圧の簡易移動平均窓（秒）

// MARK: - 内部用構造体

private struct AccSample {
    let t: TimeInterval
    let norm: Double
}

private struct StationaryInterval {
    let start: TimeInterval
    let end: TimeInterval
    
    var duration: TimeInterval {
        end - start
    }
}

private struct BaroSample {
    let t: TimeInterval
    let pressure: Double
}

private let topTracker = TopStabilityTracker()

private let baroFilter = BarometerFilter()




final class SensorManager: ObservableObject {
    @Published var isTopStable: Bool = false   // これを追加
    @Published var estimatedTopTimeSec: Double? = nil// ★ 追加
    
    static let shared = SensorManager()
    
    // CoreMotion / Barometer
    private let motionManager = CMMotionManager()
    private let altimeter = CMAltimeter()
    
    // 表示用（UI バインド用）
    @Published var latestAccNorm: Double = 0.0
    @Published var latestPressure_hPa: Double = 0.0
    
    @Published var appPhase: AppPhase = .locating
    @Published var currentWheelName: String = ""
    @Published var currentWheelHeight: Double = 40.0  // デフォルト 40m
    
    // 乗車判定の結果をUI・ログから見られるように公開
    @Published var boardingTimeSec: Double?
    @Published var tMoveSec: Double?
    
    // 内部状態
    private var startDate: Date?
    
    // 加速度関連
    private var accBuffer: [AccSample] = []                 // 標準偏差計算用バッファ
    private var stationaryIntervals: [StationaryInterval] = [] // 検出済みの静止区間
    private var isCurrentlyStill: Bool = false
    private var currentStillStart: TimeInterval?
    
    // 気圧関連
    private var baroBuffer: [BaroSample] = []               // 移動平均用
    private var lastFilteredPressure: Double?
    private var lastFilteredTime: TimeInterval?
    
    private var estimatedPeriodSec: TimeInterval = 600.0    // 高さから推定した周期
    private var dpdtThreshold: Double = 0.008               // dp/dt 閾値 [hPa/s]
    
    private var tMoveCandidates: [TimeInterval] = []        // dp/dt 閾値を超えた候補
    private var tMoveSelected: TimeInterval?                // 最終的に採用した t_move
    private var boardingDetected: Bool = false
    
    
    
    private init() {}
    
    // MARK: - 公開 API
    
    /// 観覧車の高さと表示名を設定
    func configure(height: Double, displayName: String) {
        currentWheelHeight = height
        currentWheelName = displayName
        
        // 高さから周期を推定： T = 12.33 * H + 98.2
        let T = 12.33 * height + 98.2
        estimatedPeriodSec = T
        
        // 高さから気圧振幅をざっくり推定（約 0.057 hPa/m）
        let ampRef = 0.057 * height
        
        // 1周のうち、上昇にかかる時間をざっくり T/2 と見て dp/dt の目安を計算
        // dp/dt ≈ amp / (T/2)
        dpdtThreshold = ampRef / (0.5 * T)
        
        print("=== FerrisWheel configure ===")
        print("name         :", displayName)
        print("height       :", height)
        print("estimated T  :", estimatedPeriodSec)
        print("ampRef       :", ampRef, "hPa")
        print("dpdtThreshold:", dpdtThreshold, "hPa/s")
    }
        
    /// センサ計測開始（乗車判定スタート）
    func startSensing() {
        startDate = Date()
        accBuffer.removeAll()
        stationaryIntervals.removeAll()
        isCurrentlyStill = false
        currentStillStart = nil
        
        baroBuffer.removeAll()
        lastFilteredPressure = nil
        lastFilteredTime = nil
        tMoveCandidates.removeAll()
        tMoveSelected = nil
        boardingDetected = false
        
        boardingTimeSec = nil
        tMoveSec = nil
        
        // ★ 追加：フィルタ & 頂上安定判定のリセット
        baroFilter.reset()
        baroFilter.clampUpwardUntilTop = true
        topTracker.reset()
        isTopStable = false
        
        appPhase = .detectingBoarding
        print("=== startSensing: boarding detection phase started ===")
    }
    
//    // Cosine フィットを行ったあと (Python のリアルタイム版と同じ場所) で:
//    func handleCosineFitResult(t0: TimeInterval, T: TimeInterval, c: Double, r2: Double) {
//        guard let boardingTimeSec = boardingTimeSec else { return }
//        let now = nowElapsed()
//        let elapsedSinceBoarding = now - boardingTimeSec
//        let tTop = t0 + T / 2.0
//        
//        let stable = topTracker.addFit(
//            elapsedSinceBoarding: elapsedSinceBoarding,
//            tTop: tTop,
//            period: T,
//            r2: r2
//        )
//        if stable && !isTopStable {
//            print("[TOP] 頂上安定になりました (tTop≈\(tTop), T≈\(T), R²=\(r2))")
//        }
//        isTopStable = stable
//    }
    
    // Cosine フィット結果を受け取って、頂上推定と安定判定を更新
    /// NonlinearCosineFitter からフィット結果が返ってきたときに呼ぶ
    private func handleCosineFitResult(
        t0: TimeInterval,
        T: TimeInterval,
        c: Double,
        r2: Double
    ) {
        guard let boardingTimeSec = boardingTimeSec else { return }
        
        // 乗車からの経過時間（リアルタイムループの時刻系と同じ秒）
        let now = Date().timeIntervalSince1970
        let elapsed = now - boardingTimeSec
        
        // 頂上時刻（乗車からの相対時間）
        let tTop = t0 + T / 2.0
        
        // トップ安定性トラッカーに登録
        let isStable = topTracker.addFit(
            elapsedSinceBoarding: elapsed,
            tTop: tTop,
            period: T,
            r2: r2
        )
        
        DispatchQueue.main.async {
            self.estimatedTopTimeSec = tTop
            self.isTopStable = isStable
            // ここで appPhase を .topApproaching に変えるなども可
        }
    }

    
    func stopSensing() {
        motionManager.stopAccelerometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        print("=== stopSensing ===")
    }
    
    // MARK: - センサ開始
    
    private func startAccelerometer() {
        guard motionManager.isAccelerometerAvailable else {
            print("[WARN] Accelerometer not available")
            return
        }
        motionManager.accelerometerUpdateInterval = 1.0 / 50.0 // 50 Hz 程度
        
        motionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self, let data = data, error == nil else { return }
            let ax = data.acceleration.x * 9.81
            let ay = data.acceleration.y * 9.81
            let az = data.acceleration.z * 9.81
            let norm = sqrt(ax * ax + ay * ay + az * az)
            self.latestAccNorm = norm
            
            self.handleAccelerometerSample(norm: norm)
        }
    }
    
    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            print("[WARN] Barometer not available")
            return
        }
        
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, let data = data, error == nil else { return }
            // CMAltitudeData.pressure は kPa → hPa に変換
            let pressure_hPa = data.pressure.doubleValue * 10.0
            self.latestPressure_hPa = pressure_hPa
            
            self.handleBarometerSample(pressure: pressure_hPa)
        }
    }
    
    // MARK: - 時間管理
    
    private func nowElapsed() -> TimeInterval {
        guard let start = startDate else { return 0 }
        return Date().timeIntervalSince(start)
    }
    
    // MARK: - 加速度サンプル処理（静止区間検出）
    
    private func handleAccelerometerSample(norm: Double) {
        let t = nowElapsed()
        let sample = AccSample(t: t, norm: norm)
        accBuffer.append(sample)
        
        // 古いサンプルを削除（時間窓より前のもの）
        let cutoff = t - ACC_STD_WINDOW_SEC
        accBuffer.removeAll { $0.t < cutoff }
        
        // 十分なデータがたまっていない場合は何もしない
        guard let first = accBuffer.first else { return }
        let windowDuration = t - first.t
        if windowDuration < ACC_STD_WINDOW_SEC * 0.8 {
            return
        }
        
        // 標準偏差を計算
        let values = accBuffer.map { $0.norm }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let std = sqrt(variance)
        
        let stillNow = std < ACC_STD_THRESH
        
        if stillNow && !isCurrentlyStill {
            // 静止状態に入った
            isCurrentlyStill = true
            currentStillStart = t
            // print("[ACC] still start @", t, " std=", std)
        } else if !stillNow && isCurrentlyStill {
            // 静止状態から抜けた
            isCurrentlyStill = false
            if let start = currentStillStart {
                let dur = t - start
                if dur >= ACC_MIN_INTERVAL_SEC {
                    let interval = StationaryInterval(start: start, end: t)
                    stationaryIntervals.append(interval)
                    print(String(format: "[ACC] stationary interval detected: %.2fs - %.2fs (dur=%.2fs)",
                                 start, t, dur))
                }
            }
            currentStillStart = nil
        }
    }
    
    // MARK: - 気圧サンプル処理（t_move + boarding_time）
    private func handleBarometerSample(pressure: Double) {
        let t = nowElapsed()
        
        // --- (1) Python 版相当のフィルタ処理 ---
        // 頂上安定していない間は「上方向抑制」をオンにしておく
        baroFilter.clampUpwardUntilTop = !isTopStable
        
        let pFilt = baroFilter.processSample(time: t, pressure: pressure)
        latestPressure_hPa = pFilt
        
        // --- (2) dp/dt 計算 ---
        var dpdt: Double? = nil
        if let lastP = lastFilteredPressure,
           let lastT = lastFilteredTime {
            let dt = t - lastT
            if dt > 0 {
                dpdt = (pFilt - lastP) / dt
            }
        }
        lastFilteredPressure = pFilt
        lastFilteredTime = t
        
        // boarding 検出フェーズ以外ならここで終了
        guard appPhase == .detectingBoarding else {
            return
        }
        
        // --- (3) dp/dt 閾値判定 → t_move 候補 ---
        if let dpdt = dpdt {
            if dpdt <= -dpdtThreshold {
                print(String(
                    format: "[BARO] dp/dt=%.5f hPa/s @ t=%.2f (threshold=%.5f)",
                    dpdt, t, dpdtThreshold
                ))
                tMoveCandidates.append(t)
                trySelectBoardingTime()
            }
        }
    }

    
    // MARK: - boarding_time の決定ロジック
    
    /// t_move 候補が増えるたびに呼ばれ、静止区間と組み合わせて boarding_time を決める
    private func trySelectBoardingTime() {
        guard !boardingDetected else { return }
        guard !tMoveCandidates.isEmpty else { return }
        guard !stationaryIntervals.isEmpty else {
            // まだ静止区間が検出されていない
            print("[BOARD] no stationary intervals yet, postpone boarding detection")
            return
        }
        
        print("[BOARD] trying to determine boarding_time using t_move candidates...")
        
        // Python 版と同じイメージで、
        // 早い順に t_move 候補を試していく
        for tMove in tMoveCandidates {
            if let interval = findStationaryInterval(around: tMove) {
                // 採用
                boardingDetected = true
                boardingTimeSec = interval.start
                tMoveSelected = tMove
                tMoveSec = tMove
                
                print(String(format: "[BOARD] boarding_time decided: %.2f s (t_move=%.2f s, interval=%.2f-%.2f)",
                             interval.start, tMove, interval.start, interval.end))
                
                // ここから先は頂上推定フェーズへ
                appPhase = .estimatingTop
                return
            } else {
                print(String(format: "[BOARD] t_move=%.2f に対応する静止区間が見つからず", tMove))
            }
        }
        
        print("[BOARD] no valid boarding_time candidate yet")
    }
    
    /// 条件:
    ///   ts <= t_move <= te + T_MOVE_MARGIN_SEC
    ///   かつ
    ///   (t_move - ts) <= MAX_WAIT_BEFORE_MOVE
    private func findStationaryInterval(around tMove: TimeInterval) -> StationaryInterval? {
        // 条件を満たす interval をすべて集めて、一番「それっぽいもの」（ここでは開始時刻が一番遅いもの）を採用
        let candidates = stationaryIntervals.filter { iv in
            let cond1 = iv.start <= tMove && tMove <= iv.end + T_MOVE_MARGIN_SEC
            let cond2 = (tMove - iv.start) <= MAX_WAIT_BEFORE_MOVE
            return cond1 && cond2
        }
        
        guard !candidates.isEmpty else { return nil }
        
        // Python 版に合わせて「最後の静止区間」を優先（start が最大のもの）
        let best = candidates.max(by: { $0.start < $1.start })!
        return best
    }
    
    // MARK: - バイブレーション（乗車判定段階では未使用）
    
    private func vibrate() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
}
