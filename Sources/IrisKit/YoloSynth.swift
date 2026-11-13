import AVFoundation
import Foundation

protocol YoloAudioPlaying: Sendable {
    func playVengabusYolo()
    func playPowerDown()
}

struct YoloAudioHooks: YoloAudioPlaying, @unchecked Sendable {
    let playOn: () -> Void
    let playOff: () -> Void

    func playVengabusYolo() { playOn() }
    func playPowerDown() { playOff() }
}

struct NoOpYoloAudio: YoloAudioPlaying {
    func playVengabusYolo() {}
    func playPowerDown() {}
}

final class YoloSynth: YoloAudioPlaying, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    static let sampleRate: Double = 44100.0

    init() {
        engine.attach(player)
        if let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        try? engine.start()
    }

    static func makeVengabusBuffer(sampleRate: Double = YoloSynth.sampleRate) -> AVAudioPCMBuffer? {
        // Melody notes: (Frequency in Hz, Duration in seconds)
        // Iconic Vengabus hook in C Major / A Minor
        let notes: [(freq: Double, dur: Double)] = [
            (523.25, 0.22), // C5 ("We")
            (440.00, 0.22), // A4 ("like")
            (523.25, 0.22), // C5 ("to")
            (587.33, 0.33), // D5 ("par-")
            (523.25, 0.33), // C5 ("ty")
            (0.0,    0.15), // Brief rest

            (440.00, 0.22), // A4 ("We")
            (392.00, 0.22), // G4 ("like,")
            (440.00, 0.22), // A4 ("we")
            (523.25, 0.22), // C5 ("like")
            (587.33, 0.33), // D5 ("to")
            (523.25, 0.33), // C5 ("par-")
            (440.00, 0.45), // A4 ("ty")
            (0.0,    0.15), // Brief rest

            // Second pass fading out
            (523.25, 0.22), // C5
            (440.00, 0.22), // A4
            (523.25, 0.22), // C5
            (587.33, 0.33), // D5
            (523.25, 0.60)  // C5
        ]

        let totalDuration = notes.reduce(0.0) { $0 + $1.dur }
        let totalFrames = AVAudioFrameCount(totalDuration * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let channelData = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = totalFrames
        var currentFrame = 0

        for (freq, dur) in notes {
            let noteFrames = Int(dur * sampleRate)
            for i in 0..<noteFrames {
                guard currentFrame < Int(totalFrames) else { break }

                if freq == 0.0 {
                    channelData[currentFrame] = 0.0
                } else {
                    let t = Double(i) / sampleRate
                    let phase = (t * freq).truncatingRemainder(dividingBy: 1.0)

                    // Blend sawtooth (brassy) + square (punchy) for 90s Eurodance horn vibe
                    let saw = Float(2.0 * phase - 1.0)
                    let square: Float = phase < 0.5 ? 1.0 : -1.0
                    let rawWave = (saw * 0.65) + (square * 0.35)

                    // Short per-note attack/decay envelope to avoid clicks
                    let noteProgress = Double(i) / Double(noteFrames)
                    let attack = min(1.0, noteProgress * 15.0)
                    let release = min(1.0, (1.0 - noteProgress) * 8.0)
                    let noteEnvelope = Float(attack * release)

                    // Overall fade-out across the entire clip
                    let globalProgress = Float(currentFrame) / Float(totalFrames)
                    let globalFadeOut = pow(1.0 - globalProgress, 1.5)

                    // Master volume set to 0.25 so it doesn't blow out your ears
                    channelData[currentFrame] = rawWave * noteEnvelope * globalFadeOut * 0.25
                }
                currentFrame += 1
            }
        }
        return buffer
    }

    static func makePowerDownBuffer(sampleRate: Double = YoloSynth.sampleRate) -> AVAudioPCMBuffer? {
        let duration: Double = 1.6 // Punchy 1.6-second spin-down
        let totalFrames = AVAudioFrameCount(duration * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let channelData = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = totalFrames

        let startFreq: Double = 523.25 // Matches C5 from Vengabus
        let endFreq: Double = 36.0     // Deep sub-bass rumble

        var phase: Double = 0.0
        var filteredSample: Float = 0.0

        for i in 0..<Int(totalFrames) {
            let progress = Double(i) / Double(totalFrames)

            // Exponential frequency drop (mimics a physical motor or tape slowing down)
            let currentFreq = startFreq * pow(endFreq / startFreq, pow(progress, 1.35))

            // Accumulate phase smoothly so continuous pitch bends don't click
            phase += currentFreq / sampleRate
            if phase >= 1.0 { phase -= 1.0 }

            // Blend sub-bass sine wave + gritty sawtooth wave
            let sine = Float(sin(2.0 * .pi * phase))
            let saw = Float(2.0 * phase - 1.0)
            let rawWave = (sine * 0.65) + (saw * 0.35)

            // Simple low-pass filter that closes as the pitch drops
            let cutoff = Float(max(0.03, 0.45 * (1.0 - progress)))
            filteredSample += cutoff * (rawWave - filteredSample)

            // Smooth attack and tail fade-out
            let attack = Float(min(1.0, progress * 30.0))
            let release = Float(pow(1.0 - progress, 1.2))
            let envelope = attack * release

            channelData[i] = filteredSample * envelope * 0.35
        }
        return buffer
    }

    func playVengabusYolo() {
        guard let buffer = Self.makeVengabusBuffer(sampleRate: Self.sampleRate) else { return }
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }

    func playPowerDown() {
        guard let buffer = Self.makePowerDownBuffer(sampleRate: Self.sampleRate) else { return }
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }
}
