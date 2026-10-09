// Captures macOS system audio with ScreenCaptureKit and writes it to stdout as
// raw 16-bit little-endian mono PCM. No virtual audio device needed.
//
// Usage: syscap [sample_rate]   (8000, 16000, 24000 or 48000; default 48000)
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("syscap: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let sampleRate = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 48000 : 48000

final class AudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let stdout = FileHandle.standardOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else {
            fail("unexpected audio format: \(asbd)")
        }
        try? sampleBuffer.withAudioBufferList { abl, _ in
            // Downmix every channel (interleaved or not) to mono and convert to Int16.
            var mix: [Float] = []
            var channels = 0
            for buf in abl {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let nc = Int(buf.mNumberChannels)
                let frames = Int(buf.mDataByteSize) / 4 / nc
                if mix.isEmpty { mix = [Float](repeating: 0, count: frames) }
                for i in 0..<min(frames, mix.count) {
                    for c in 0..<nc { mix[i] += data[i * nc + c] }
                }
                channels += nc
            }
            guard channels > 0 else { return }
            let pcm = mix.map { Int16(max(-1, min(1, $0 / Float(channels))) * 32767) }
            pcm.withUnsafeBytes { stdout.write(Data($0)) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fail("capture stopped: \(error.localizedDescription)")
    }
}

_ = CGMainDisplayID()  // connect to the window server before asking for shareable content

let content: SCShareableContent
do {
    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
} catch {
    fail("""
        \(error.localizedDescription)
        Grant Screen Recording permission to your terminal app in
        System Settings > Privacy & Security > Screen & System Audio Recording, then restart it.
        """)
}
guard let display = content.displays.first else { fail("no display found") }

let config = SCStreamConfiguration()
config.capturesAudio = true
config.excludesCurrentProcessAudio = true
config.sampleRate = sampleRate
config.channelCount = 1
// Video can't be switched off, so make it as cheap as possible.
config.width = 2
config.height = 2
config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

let output = AudioOutput()
let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
let stream = SCStream(filter: filter, configuration: config, delegate: output)
do {
    try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "syscap.audio"))
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        stream.startCapture { error in
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        }
    }
} catch {
    fail("could not start capture: \(error.localizedDescription)")
}

while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
