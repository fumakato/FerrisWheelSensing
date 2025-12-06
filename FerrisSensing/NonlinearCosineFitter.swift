import Foundation

/// コサインモデルのパラメータ
/// p(t) = a * cos(2π (t - t0) / T) + c
struct CosineParams {
    var a: Double
    var T: Double
    var t0: Double
    var c: Double
}

/// フィット結果
struct CosineFitResult {
    let params: CosineParams
    let r2: Double
    let fitted: [Double]
}

/// Python 側で作ったテスト JSON のフォーマット
struct FerrisFitTestData: Codable {
    let t: [Double]
    let p: [Double]
    let T_ref: Double
    let c0_prior: Double
    let height_m: Double
    let boarding_time: Double
}

/// Python の fit_cosine_bounded() を Swift で移植したクラス。
/// - 高さ・boarding_time・c0_prior をコンストラクタで受け取る
/// - fit() で boarding_time 以降のデータに対して制約付きコサインフィットを行う
/// - 連続呼び出し時には前回の結果を初期値に利用（prevParams）
/// - maybeFit() で MIN_FIT_DURATION_SEC / STEP_SEC に基づき「今フィットすべきか」を判断
final class NonlinearCosineFitter {
    
    // MARK: - 公開設定値（Python と揃えてある）
    
    /// 最初のフィットに必要な最小データ長 [s]
    let minFitDurationSec: Double = 100.0     // MIN_FIT_DURATION_SEC
    
    /// 何秒ごとに再フィットするか [s]
    let stepSec: Double = 6.0                 // STEP_SEC
    
    /// 部分フィットに要求する最小 R^2
    let minR2Partial: Double = 0.96           // MIN_R2_PARTIAL
    
    // MARK: - Python 由来のフィット制約（fit_cosine_bounded と同じ）
    
    /// a のレンジ ±10%
    private let aRangeRatio: Double = 0.1     // 0.9〜1.1
    
    /// T のレンジ ±20%
    private let tRangeRatio: Double = 0.2     // 0.8〜1.2
    
    /// t0 の範囲: boarding_time ± T_ref / 4
    private let t0RangeFraction: Double = 0.25
    
    /// c のレンジ: c0_prior ± 5 [hPa]
    private let cRangeAbs: Double = 5.0
    
    // MARK: - LM 風 最適化パラメータ
    
    /// 最大イテレーション回数
    private let maxIterations = 40
    
    /// LM のダンピング係数（対角に足すλ）
    private let lambdaLM: Double = 1e-3
    
    /// 数値ヤコビアンの差分ステップ
    private let jacobianEps: Double = 1e-4
    
    // MARK: - コンテキスト（Python の引数に対応）
    
    private let heightM: Double
    private let tRef: Double
    private let c0Prior: Double
    private let boardingTime: Double
    
    /// 連続フィット用の前回パラメータ
    private var prevParams: CosineParams?
    
    /// 直近でフィットを実行した t_end（絶対時刻）
    private var lastFitTime: Double?
    
    // MARK: - 初期化
    
    init(heightM: Double,
         tRef: Double,
         c0Prior: Double,
         boardingTime: Double) {
        self.heightM = heightM
        self.tRef = tRef
        self.c0Prior = c0Prior
        self.boardingTime = boardingTime
    }
    
    // MARK: - 公開 API
    
    /// 「今フィットすべきか？」を見て、必要ならフィットして結果を返す。
    ///
    /// - Parameters:
    ///   - times: boarding_time 以降の時刻列（例: t_baro_b）
    ///   - pressures: boarding_time 以降の気圧列（例: p_filt_b）
    ///   - currentTime: 今の絶対時刻（times の最後の値など）
    ///
    /// - Returns: フィット結果（実行した場合）、それ以外は nil
    func maybeFit(times: [Double],
                  pressures: [Double],
                  currentTime: Double) -> CosineFitResult? {
        
        guard let firstTime = times.first,
              let lastTime = times.last,
              times.count == pressures.count,
              times.count >= 4 else {
            return nil
        }
        
        // boarding_time からの経過時間
        let elapsedFromBoarding = lastTime - boardingTime
        // 十分なデータ長が必要
        guard elapsedFromBoarding >= minFitDurationSec else {
            return nil
        }
        
        // 前回フィットから十分時間が経っているか
        if let last = lastFitTime {
            if currentTime - last < stepSec {
                return nil
            }
        }
        
        // 実際にフィットを試みる
        guard let result = fit(times: times, pressures: pressures) else {
            return nil
        }
        
        // R^2 が低すぎる場合は無効
        guard result.r2 >= minR2Partial else {
            return nil
        }
        
        lastFitTime = currentTime
        return result
    }
    
    /// Python の fit_cosine_bounded に対応するメソッド。
    ///
    /// - Parameters:
    ///   - times: boarding_time 以降の全データの時刻列
    ///   - pressures: boarding_time 以降の全データの気圧列
    ///
    /// - Returns: フィット結果（a,T,t0,c, fitted, r2）。収束しなければ nil。
    func fit(times t: [Double],
             pressures p: [Double]) -> CosineFitResult? {
        
        guard t.count == p.count, t.count >= 4 else { return nil }
        
        // 1. 初期値の決定（prevParams があればそれを使う）
        let initialParams: CosineParams
        
        if let prev = prevParams {
            initialParams = prev
        } else {
            // Python と同じ:
            // delta_p_pa = height_m * 11.4
            // a0 = (delta_p_pa/100)/2
            let deltaPPa = heightM * 11.4
            let deltaPHpa = deltaPPa / 100.0
            let a0 = deltaPHpa / 2.0
            let T0 = tRef
            let t0_0 = boardingTime
            let c0 = c0Prior
            initialParams = CosineParams(a: a0, T: T0, t0: t0_0, c: c0)
            
            print("===== Cosine Fit Initial Params =====")
            print(String(format: "a0  = %.4f hPa", a0))
            print(String(format: "T0  = %.4f s", T0))
            print(String(format: "t0_0= %.4f s", t0_0))
            print(String(format: "c0  = %.4f hPa", c0))
        }
        
        // 2. bounds の設定（Python と同じ式）
        let boundsMin = CosineParams(
            a: (1.0 - aRangeRatio) * initialParams.a,    // 0.9 a0
            T: (1.0 - tRangeRatio) * tRef,               // 0.8 T_ref
            t0: boardingTime - tRef * t0RangeFraction,   // boarding - T_ref/4
            c: c0Prior - cRangeAbs                       // c0_prior - 5
        )
        
        let boundsMax = CosineParams(
            a: (1.0 + aRangeRatio) * initialParams.a,    // 1.1 a0
            T: (1.0 + tRangeRatio) * tRef,               // 1.2 T_ref
            t0: boardingTime + tRef * t0RangeFraction,   // boarding + T_ref/4
            c: c0Prior + cRangeAbs                       // c0_prior + 5
        )
        
        print("===== Cosine Fit Bounds =====")
        print(String(format: "a in [%.4f, %.4f]", boundsMin.a, boundsMax.a))
        print(String(format: "T in [%.4f, %.4f]", boundsMin.T, boundsMax.T))
        print(String(format: "t0 in [%.4f, %.4f]", boundsMin.t0, boundsMax.t0))
        print(String(format: "c in [%.4f, %.4f]", boundsMin.c, boundsMax.c))
        
        // 3. LM 風最適化ループ
        var params = clamp(initialParams, min: boundsMin, max: boundsMax)
        
        for _ in 0..<maxIterations {
            // 残差 r = y - f(t; params)
            let residuals = residualVector(times: t, pressures: p, params: params)
            let rssOld = residuals.reduce(0.0) { $0 + $1 * $1 }
            
            // J^T J, J^T r を計算
            var (JTJ, JTr) = buildNormalEquations(times: t,
                                                  params: params,
                                                  residuals: residuals)
            
            // LM のダンピング（対角成分に λ を足す）
            for i in 0..<4 {
                JTJ[i][i] += lambdaLM
            }
            
            // 4x4 の連立方程式を解いて Δparams を求める
            guard let delta = solve4x4(A: JTJ, b: JTr) else {
                break
            }
            
            var newParams = CosineParams(
                a: params.a + delta[0],
                T: params.T + delta[1],
                t0: params.t0 + delta[2],
                c: params.c + delta[3]
            )
            
            // bounds に投影
            newParams = clamp(newParams, min: boundsMin, max: boundsMax)
            
            // 新しい RSS を計算
            let newResiduals = residualVector(times: t, pressures: p, params: newParams)
            let rssNew = newResiduals.reduce(0.0) { $0 + $1 * $1 }
            
            // 改善していれば更新、していなければ早期終了
            if rssNew < rssOld {
                params = newParams
            } else {
                break
            }
        }
        
        // 4. 最終結果
        let fitted = t.map { cosineModel(time: $0, params: params) }
        let r2 = rSquared(yTrue: p, yPred: fitted)
        
        print("===== Cosine Fit Result =====")
        print(String(format: "a_fit  = %.4f hPa", params.a))
        print(String(format: "T_fit  = %.4f s", params.T))
        print(String(format: "t0_fit = %.4f s", params.t0))
        print(String(format: "c_fit  = %.4f hPa", params.c))
        print(String(format: "R^2    = %.6f", r2))
        print("===================================")
        
        prevParams = params
        return CosineFitResult(params: params, r2: r2, fitted: fitted)
    }
    
    // MARK: - 内部ヘルパー
    
    /// p(t) = a * cos(2π (t - t0) / T) + c
    private func cosineModel(time t: Double, params p: CosineParams) -> Double {
        return p.a * cos(2.0 * Double.pi * (t - p.t0) / p.T) + p.c
    }
    
    /// 残差ベクトル r_i = y_i - f(t_i; params)
    private func residualVector(times t: [Double],
                                pressures y: [Double],
                                params p: CosineParams) -> [Double] {
        zip(t, y).map { (ti, yi) in
            yi - cosineModel(time: ti, params: p)
        }
    }
    
    /// R^2 を計算
    private func rSquared(yTrue: [Double], yPred: [Double]) -> Double {
        let mean = yTrue.reduce(0.0, +) / Double(yTrue.count)
        let ssTot = yTrue.reduce(0.0) { $0 + pow($1 - mean, 2.0) }
        let ssRes = zip(yTrue, yPred).reduce(0.0) { acc, pair in
            let (yi, fi) = pair
            return acc + pow(yi - fi, 2.0)
        }
        if ssTot == 0 {
            return Double.nan
        }
        return 1.0 - ssRes / ssTot
    }
    
    /// パラメータを bounds にクランプ
    private func clamp(_ p: CosineParams,
                       min minB: CosineParams,
                       max maxB: CosineParams) -> CosineParams {
        return CosineParams(
            a: min(max(p.a, minB.a), maxB.a),
            T: min(max(p.T, minB.T), maxB.T),
            t0: min(max(p.t0, minB.t0), maxB.t0),
            c: min(max(p.c, minB.c), maxB.c)
        )
    }
    
    /// 数値ヤコビアンで J^T J, J^T r を構成する
    ///
    /// パラメータ順序: [a, T, t0, c]
    private func buildNormalEquations(times t: [Double],
                                      params p: CosineParams,
                                      residuals r: [Double])
    -> ([[Double]], [Double]) {
        
        // J: N×4, 正規方程式用に 4×4 と 4×1 だけを構成する
        var JTJ = Array(
            repeating: Array(repeating: 0.0, count: 4),
            count: 4
        )
        var JTr = Array(repeating: 0.0, count: 4)
        
        for (i, ti) in t.enumerated() {
            // 各点での数値微分
            let jacRow = numericalJacobianAt(time: ti, params: p)
            
            // J^T J += jacRow^T * jacRow
            for j in 0..<4 {
                for k in 0..<4 {
                    JTJ[j][k] += jacRow[j] * jacRow[k]
                }
            }
            
            // J^T r += jacRow^T * r_i
            let ri = r[i]
            for j in 0..<4 {
                JTr[j] += jacRow[j] * ri
            }
        }
        
        return (JTJ, JTr)
    }
    
    /// 1 点でのヤコビアン行（∂f/∂a, ∂f/∂T, ∂f/∂t0, ∂f/∂c）を数値微分で計算
    private func numericalJacobianAt(time t: Double,
                                     params p: CosineParams) -> [Double] {
        
        // 現在の値
        let f0 = cosineModel(time: t, params: p)
        
        // ∂f/∂a
        var pA = p
        pA.a += jacobianEps
        let fA = cosineModel(time: t, params: pA)
        let dfdA = (fA - f0) / jacobianEps
        
        // ∂f/∂T
        var pT = p
        pT.T += jacobianEps
        let fT = cosineModel(time: t, params: pT)
        let dfdT = (fT - f0) / jacobianEps
        
        // ∂f/∂t0
        var pT0 = p
        pT0.t0 += jacobianEps
        let fT0 = cosineModel(time: t, params: pT0)
        let dfdT0 = (fT0 - f0) / jacobianEps
        
        // ∂f/∂c = 1
        let dfdC = 1.0
        
        return [dfdA, dfdT, dfdT0, dfdC]
    }
    
    /// 4×4 行列 A と長さ 4 のベクトル b について、A x = b をガウス消去で解く
    private func solve4x4(A: [[Double]], b: [Double]) -> [Double]? {
        var M = A
        var rhs = b
        let n = 4
        
        // 前進消去
        for k in 0..<n {
            // ピボット選択（単純な部分ピボット）
            var pivot = k
            var maxVal = abs(M[k][k])
            for i in (k+1)..<n {
                let val = abs(M[i][k])
                if val > maxVal {
                    maxVal = val
                    pivot = i
                }
            }
            
            if maxVal < 1e-12 {
                return nil // 特異行列とみなす
            }
            
            if pivot != k {
                M.swapAt(k, pivot)
                rhs.swapAt(k, pivot)
            }
            
            let diag = M[k][k]
            for i in (k+1)..<n {
                let factor = M[i][k] / diag
                rhs[i] -= factor * rhs[k]
                for j in k..<n {
                    M[i][j] -= factor * M[k][j]
                }
            }
        }
        
        // 後退代入
        var x = Array(repeating: 0.0, count: n)
        for i in stride(from: n-1, through: 0, by: -1) {
            var s = rhs[i]
            for j in (i+1)..<n {
                s -= M[i][j] * x[j]
            }
            x[i] = s / M[i][i]
        }
        return x
    }
    
    // MARK: - バンドル JSON を使ったテスト
    
    /// Python 側で作成した fit_test_higashiyama_15.json を読み込んで
    /// Swift 側フィットが正しく動くか確認するテスト
    static func runCosineFitTestFromBundle() {
        // 1. JSON 読み込み
        guard let url = Bundle.main.url(forResource: "fit_test_higashiyama_15",
                                        withExtension: "json") else {
            print("[TEST] JSON not found in bundle")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let testData = try decoder.decode(FerrisFitTestData.self, from: data)
            
            // 2. Fitter を初期化（Python と同様のパラメータ）
            let fitter = NonlinearCosineFitter(
                heightM: testData.height_m,
                tRef: testData.T_ref,
                c0Prior: testData.c0_prior,
                boardingTime: testData.boarding_time
            )
            
            // 3. boarding_time 以降のデータでフィット
            if let result = fitter.fit(times: testData.t, pressures: testData.p) {
                let p = result.params
                print("[Swift fit result]")
                print(String(format: "a   = %.4f", p.a))
                print(String(format: "T   = %.4f", p.T))
                print(String(format: "t0  = %.4f", p.t0))
                print(String(format: "c   = %.4f", p.c))
                print(String(format: "R^2 = %.6f", result.r2))
            } else {
                print("[TEST] Fit failed in Swift")
            }
            
        } catch {
            print("[TEST] Error loading/decoding JSON: \(error)")
        }
    }
}
