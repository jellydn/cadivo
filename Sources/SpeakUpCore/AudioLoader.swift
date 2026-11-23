@preconcurrency import AVFoundation

public enum AudioLoaderError: Error {
    case cannotConvert
}

public enum AudioLoader {
    /// Reads any file AVFoundation can open and converts it to 16 kHz mono Float32.
    public static func load(_ url: URL, sampleRate: Double = 16_000) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url)
        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: file.processingFormat, to: target),
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw AudioLoaderError.cannotConvert }
        try file.read(into: input)

        let ratio = sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw AudioLoaderError.cannotConvert
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let channel = output.floatChannelData?[0] else { throw AudioLoaderError.cannotConvert }
        return AudioClip(
            samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))),
            sampleRate: sampleRate)
    }
}
