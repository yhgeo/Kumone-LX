import AVFoundation
import CryptoKit
import Foundation

enum OfflineAudioValidator {
    /// Read both encoded bytes and decoded frames. An HTTP 200 or a playable
    /// header is insufficient evidence that the complete song arrived.
    static func validate(url: URL, descriptor: OfflineAudioDescriptor) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size.map(Int64.init) == descriptor.byteCount else { throw OfflineAudioError.incomplete }
        // LX 自定义音源的 URL 没有官方 MD5：contentMD5 只是 URL 的稳定标识，
        // 不能用来校验文件内容。这类文件靠下面的完整解码 + 时长验证保证完整性。
        if !descriptor.identity.source.hasPrefix("lx·") {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = Insecure.MD5()
            while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty { digest.update(data: data) }
            let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard checksum == descriptor.identity.contentMD5.lowercased() else { throw OfflineAudioError.checksumMismatch }
        }
        do {
            let audio = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_384),
                  audio.processingFormat.sampleRate > 0 else { throw OfflineAudioError.invalidAudio }
            var frames: Int64 = 0
            while audio.framePosition < audio.length {
                let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), audio.length - audio.framePosition))
                try audio.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw OfflineAudioError.invalidAudio }
                frames += Int64(buffer.frameLength)
            }
            let duration = Double(frames) / audio.processingFormat.sampleRate
            guard frames > 0, abs(duration - descriptor.duration) <= max(2, descriptor.duration * 0.03) else {
                throw OfflineAudioError.invalidAudio
            }
        } catch { throw OfflineAudioError.invalidAudio }
    }
}
