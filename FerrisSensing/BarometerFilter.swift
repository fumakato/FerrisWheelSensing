import Foundation

/// 観覧車センシング用の気圧フィルタ
/// - Hampel フィルタ（過去窓）で外れ値除去
/// - 因果移動平均
/// - slew-limit（1秒あたりの変化量制限）
/// - 頂上確定までは「上方向への跳ね上がり」を前値で抑制
final class BarometerFilter {
    
    // 1 サンプル
    private struct Sample {
        let t: Double  // [s]
        let p: Double  // [hPa]
    }
    
    // === パラメータ ===
    /// Hampel フィルタの時間窓 [s]（過去だけを見る）
    let hampelWindowSec: Double
    
    /// Hampel のしきい値（何 σ 以上離れていたら外れ値扱いにするか）
    let hampelSigmas: Double
    
    /// 移動平均の時間窓 [s]（過去だけ）
    let movingAverageWindowSec: Double
    
    /// slew-limit の上限 [hPa/s]（nil なら無効）
    let slewLimitPerSec: Double?
    
    /// true の間は「上方向の変化は前値で止める」モード（頂上確定まで有効にする想定）
    /// Python 版の「頂上が安定するまでは上昇禁止」に相当
    var clampUpwardUntilTop: Bool
    
    // === 内部状態 ===
    private var rawWindow: [Sample] = []     // Hampel 用の過去窓
    private var maWindow: [Sample] = []      // 移動平均用の過去窓
    private var lastOutput: Double? = nil    // 最後に出力した値
    private var lastTime: Double? = nil      // 最後に出力した時刻
    
    // MARK: - 初期化
    
    init(
        hampelWindowSec: Double = 10.0,
        hampelSigmas: Double = 2.0,
        movingAverageWindowSec: Double = 6.0,
        slewLimitPerSec: Double? = nil,
        clampUpwardUntilTop: Bool = true
    ) {
        self.hampelWindowSec = hampelWindowSec
        self.hampelSigmas = hampelSigmas
        self.movingAverageWindowSec = movingAverageWindowSec
        self.slewLimitPerSec = slewLimitPerSec
        self.clampUpwardUntilTop = clampUpwardUntilTop
    }
    
    // フィルタ状態をリセット（新しい乗車ログを処理するときなど）
    func reset() {
        rawWindow.removeAll()
        maWindow.removeAll()
        lastOutput = nil
        lastTime = nil
    }
    
    /// 頂上判定が終わったら呼ぶ想定。
    /// 以降は「上方向抑制（前値固定）」を解除する。
    func finishTopDetection() {
        clampUpwardUntilTop = false
    }
    
    // MARK: - メイン処理（リアルタイム向け）
    
    /// 1 サンプルずつ処理する。
    /// - Parameters:
    ///   - time: ログ開始からの経過時間 [s]
    ///   - pressure: 生の気圧 [hPa]
    /// - Returns: フィルタ後の気圧 [hPa]
    func processSample(time: Double, pressure: Double) -> Double {
        // --- 1) Hampel フィルタ用の窓を更新 ---
        appendToRawWindow(time: time, pressure: pressure)
        
        // --- 2) Hampel フィルタ（外れ値 → 局所中央値） ---
        let pHampel = applyHampel(currentPressure: pressure)
        
        // --- 3) 因果移動平均 ---
        let pMA = applyMovingAverage(time: time, pressure: pHampel)
        
        // --- 4) slew-limit（1秒あたりの変化量制限） ---
        let pSlewLimited = applySlewLimit(time: time, targetPressure: pMA)
        
        // --- 5) 頂上安定までは「上方向抑制」 ---
        let pFinal: Double
        if clampUpwardUntilTop, let last = lastOutput, pSlewLimited > last {
            // 上方向には行かせない（= 前回値で止める）
            pFinal = last
        } else {
            pFinal = pSlewLimited
        }
        
        // 最終出力を記録
        lastOutput = pFinal
        lastTime = time
        
        return pFinal
    }
    
    // 配列一括処理（オフライン検証用）
    func processSeries(times: [Double], pressures: [Double]) -> [Double] {
        reset()
        var result: [Double] = []
        let count = min(times.count, pressures.count)
        result.reserveCapacity(count)
        for i in 0..<count {
            let y = processSample(time: times[i], pressure: pressures[i])
            result.append(y)
        }
        return result
    }
    
    // MARK: - 内部: Hampel フィルタ
    
    private func appendToRawWindow(time: Double, pressure: Double) {
        rawWindow.append(Sample(t: time, p: pressure))
        if hampelWindowSec > 0 {
            let tMin = time - hampelWindowSec
            // 時間窓より古いものは捨てる
            rawWindow.removeAll { $0.t < tMin }
        }
    }
    
    /// Hampel フィルタを適用し、外れ値なら局所中央値に置き換える。
    private func applyHampel(currentPressure: Double) -> Double {
        guard !rawWindow.isEmpty else {
            return currentPressure
        }
        
        let values = rawWindow.map { $0.p }
        let median = computeMedian(of: values)
        
        // 中央値からの絶対偏差
        let absDevs = values.map { abs($0 - median) }
        let mad = computeMedian(of: absDevs)
        
        // MAD がほぼ 0 なら判定が意味を持たないので、そのまま返す
        if mad < 1e-9 {
            return currentPressure
        }
        
        // Hampel のしきい値
        let k = 1.4826 * mad
        let threshold = hampelSigmas * k
        
        if abs(currentPressure - median) > threshold {
            // 外れ値 → 局所中央値に置き換え
            return median
        } else {
            return currentPressure
        }
    }
    
    // MARK: - 内部: 因果移動平均
    
    private func appendToMAWindow(time: Double, pressure: Double) {
        maWindow.append(Sample(t: time, p: pressure))
        if movingAverageWindowSec > 0 {
            let tMin = time - movingAverageWindowSec
            maWindow.removeAll { $0.t < tMin }
        }
    }
    
    private func applyMovingAverage(time: Double, pressure: Double) -> Double {
        appendToMAWindow(time: time, pressure: pressure)
        guard !maWindow.isEmpty else {
            return pressure
        }
        let sum = maWindow.reduce(0.0) { $0 + $1.p }
        return sum / Double(maWindow.count)
    }
    
    // MARK: - 内部: slew-limit
    
    private func applySlewLimit(time: Double, targetPressure: Double) -> Double {
        guard
            let limit = slewLimitPerSec,
            let lastY = lastOutput,
            let lastT = lastTime
        else {
            return targetPressure
        }
        
        let dt = time - lastT
        if dt <= 0 {
            return targetPressure
        }
        
        let maxStep = limit * dt
        let diff = targetPressure - lastY
        
        if abs(diff) <= maxStep {
            return targetPressure
        } else {
            // 変化量を制限
            return lastY + (diff > 0 ? maxStep : -maxStep)
        }
    }
    
    // MARK: - ユーティリティ
    
    private func computeMedian(of xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0.0 }
        let sorted = xs.sorted()
        let n = sorted.count
        if n % 2 == 1 {
            return sorted[n / 2]
        } else {
            let i = n / 2
            return 0.5 * (sorted[i - 1] + sorted[i])
        }
    }
}
