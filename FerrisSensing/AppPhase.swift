import Foundation
import SwiftUI

enum AppPhase {
    case locating          // 1. 位置情報取得中
    case preparing         // 1. 位置が取れた or 高さ40m にフォールバック
    case detectingBoarding // 4. 乗車判定中
    case estimatingTop     // 5. 頂上推定中
    case topApproaching    // 6. 頂上到達中（10秒前〜通過）
    case estimatingTwoThird // 7. 2/3経過推定中
    case twoThirdApproaching // 8. 2/3経過到達中（10秒前〜通過）
    
    var title: String {
        switch self {
        case .locating:            return "位置情報取得中"
        case .preparing:           return "観覧車推定開始準備中"
        case .detectingBoarding:   return "乗車判定中"
        case .estimatingTop:       return "頂上推定中"
        case .topApproaching:      return "頂上到達中"
        case .estimatingTwoThird:  return "2/3経過推定中"
        case .twoThirdApproaching: return "2/3経過到達中"
        }
    }
    /// UI 側から使うための説明文（今は title と同じで OK）
    var description: String {
        return title
    }
    
    var backgroundColor: Color {
        switch self {
        case .locating:
            return Color.blue.opacity(0.2)
        case .preparing:
            return Color.blue.opacity(0.2)
        case .detectingBoarding:
            return Color.green.opacity(0.2)
        case .estimatingTop:
            return Color.yellow.opacity(0.2)
        case .topApproaching:
            return Color.red.opacity(0.2)
        case .estimatingTwoThird:
            return Color.yellow.opacity(0.2)
        case .twoThirdApproaching:
            return Color.red.opacity(0.2)
        }
    }
    
}



