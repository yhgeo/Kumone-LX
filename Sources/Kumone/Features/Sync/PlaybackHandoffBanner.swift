import SwiftUI

/// iCloud 跨设备播放接力横幅。
/// 定制版（TrollStore）不启用 iCloud 同步：保留类型以避免改动所有调用点，
/// 但永远不显示任何内容。
struct PlaybackHandoffBanner: View {
    var body: some View {
        EmptyView()
    }
}
