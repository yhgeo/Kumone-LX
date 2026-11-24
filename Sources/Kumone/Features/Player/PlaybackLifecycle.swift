import SwiftUI

struct PlaybackLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            // 定制版不启用 iCloud 同步，不再启动 SyncService。
            #if os(macOS)
            .onChange(of: scenePhase) { _, _ in
                PlayerService.shared.checkpointPlayback()
            }
            #else
            .onChange(of: scenePhase) { _ in
                PlayerService.shared.checkpointPlayback()
            }
            #endif
    }
}
