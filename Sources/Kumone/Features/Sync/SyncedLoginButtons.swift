import SwiftUI

/// iCloud 同步登录按钮。定制版（TrollStore）不启用 iCloud，恒为空。
/// 保留 onStart/onFinished 属性以兼容现有调用点。
struct SyncedLoginButtons: View {
    var onStart: () -> Void = {}
    var onFinished: (Bool) -> Void = { _ in }

    var body: some View {
        EmptyView()
    }
}
