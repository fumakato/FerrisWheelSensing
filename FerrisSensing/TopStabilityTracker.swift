// TopStabilityTracker.swift

import Foundation

struct CosineFitSnapshot {
    let elapsedSinceBoarding: TimeInterval
    let tTop: TimeInterval   // t0 + T/2
    let period: TimeInterval // T
    let r2: Double
}

final class TopStabilityTracker {
    // パラメータ（Python 側とだいたい合わせる）
    private let minElapsedForCheck: TimeInterval = 180.0   // 3分以降で収束判定開始
    private let r2Threshold: Double = 0.998
    private let stdTTopMax: Double = 3.0                   // 頂上時刻の許容ブレ [s]
    private let stdTMax: Double = 20.0                     // 周期の許容ブレ [s]
    private let historyMaxCount: Int = 10                  // 履歴最大
    private let windowForStd: Int = 5                      // 直近何件で std を見るか
    
    private(set) var isTopStable: Bool = false
    private var history: [CosineFitSnapshot] = []
    
    func reset() {
        history.removeAll()
        isTopStable = false
    }
    
    /// 新しいフィット結果を追加し、頂上安定かどうかを更新して返す
    func addFit(elapsedSinceBoarding: TimeInterval,
                tTop: TimeInterval,
                period: TimeInterval,
                r2: Double) -> Bool {
        
        let snap = CosineFitSnapshot(
            elapsedSinceBoarding: elapsedSinceBoarding,
            tTop: tTop,
            period: period,
            r2: r2
        )
        history.append(snap)
        if history.count > historyMaxCount {
            history.removeFirst(history.count - historyMaxCount)
        }
        
        guard !isTopStable else {
            // 一度安定と判断したら true を維持（Python と同じ考え方）
            return true
        }
        
        // そもそもチェック開始条件に満たないなら false
        guard elapsedSinceBoarding >= minElapsedForCheck else { return false }
        guard r2 >= r2Threshold else { return false }
        guard history.count >= windowForStd else { return false }
        
        let recent = history.suffix(windowForStd)
        let tTops = recent.map { $0.tTop }
        let periods = recent.map { $0.period }
        
        let stdTTop = Self.std(of: tTops)
        let stdT = Self.std(of: periods)
        
        if stdTTop <= stdTTopMax && stdT <= stdTMax {
            isTopStable = true
        }
        return isTopStable
    }
    
    private static func std(of xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let varSum = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sqrt(varSum / Double(xs.count))
    }
}
