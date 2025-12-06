import Foundation

func testBarometerFilterOffline() {
    // 1. バンドルから CSV を探す
    guard let url = Bundle.main.url(forResource: "Barometer", withExtension: "csv") else {
        print("[TEST] CSV not found in bundle")
        return
    }
    
    // 2. CSV を読み込んで time, pressure 配列を作る
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        print("[TEST] Failed to read CSV text")
        return
    }
    
    var times: [Double] = []
    var pressures: [Double] = []
    
    let lines = text.components(separatedBy: .newlines)
    var isFirstLine = true
    
    for line in lines {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            continue
        }
        if isFirstLine {
            // ヘッダ行ならスキップ（列名が入っている前提）
            isFirstLine = false
            continue
        }
        let cols = line.split(separator: ",")
        // ここは CSV の列順に合わせてください
        // 例: 0列目: time[s], 1列目: pressure[hPa] なら:
        guard cols.count >= 2,
              let t = Double(cols[0]),
              let p = Double(cols[1]) else {
            continue
        }
        times.append(t)
        pressures.append(p)
    }
    
    print("[TEST] loaded \(times.count) samples")
    
    // 3. BarometerFilter を作成（Python と同じパラメータに合わせる）
    let filter = BarometerFilter(
        hampelWindowSec: 10.0,
        hampelSigmas: 2.0,
        movingAverageWindowSec: 6.0,
        slewLimitPerSec: 0.03,  // ← Python 側の値に合わせて
        clampUpwardUntilTop: true
    )
    
    // 4. 一括処理（オフライン用メソッド）
    let pFilteredSwift = filter.processSeries(times: times, pressures: pressures)
    
    // 5. Documents に CSV として保存
    let rows = zip(zip(times, pressures), pFilteredSwift).map { pair -> String in
        let (tp, pf) = pair
        let (t, p) = tp
        return "\(t),\(p),\(pf)"
    }
    let header = "t,p_raw,p_filt_swift"
    let csvOut = ([header] + rows).joined(separator: "\n")
    
    do {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        print("[TEST] Documents dir:", docs.path)
        let outURL = docs.appendingPathComponent("baro_filtered_swift.csv")
        try csvOut.write(to: outURL, atomically: true, encoding: .utf8)
        print("[TEST] Saved Swift filtered CSV to:", outURL.path)
    } catch {
        print("[TEST] Failed to write CSV:", error)
    }
}
