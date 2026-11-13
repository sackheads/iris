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
        if let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        try? engine.start()
    }

    /// PolyBLEP antialiasing residual for a sawtooth wave with phase in `0..<1` and phase
    /// increment `dt = freq / sampleRate`. Eliminates the harsh piezo buzzing of raw modulo saws.
    @inline(__always)
    private static func polyBLEP(phase: Double, dt: Double) -> Double {
        guard dt > 0 else { return 0 }
        if phase < dt {
            let t = phase / dt
            return t + t - t * t - 1.0
        } else if phase > 1.0 - dt {
            let t = (phase - 1.0) / dt
            return t * t + t + t + 1.0
        }
        return 0.0
    }

    @inline(__always)
    private static func bandlimitedSaw(phase: Double, dt: Double) -> Double {
        (2.0 * phase - 1.0) - polyBLEP(phase: phase, dt: dt)
    }

    /// 90s Eurodance Vengabus horn hook at 136 BPM (#1104):
    /// - 7-voice stereo-spread PolyBLEP supersaw playing triad brass chord stabs through a
    ///   2-pole resonant low-pass filter with a brassy filter envelope + warm tanh saturation
    /// - Four-on-the-floor 909 kick drum (pitch-swept sine + punchy body)
    /// - Classic off-beat Eurodance octave bassline
    static func makeVengabusBuffer(sampleRate: Double = YoloSynth.sampleRate) -> AVAudioPCMBuffer? {
        let bpm: Double = 136.0
        let beatDur: Double = 60.0 / bpm          // ~0.4412 s per quarter-note beat
        let sixteenth: Double = beatDur / 4.0     // ~0.1103 s per 16th note
        let totalSixteenths = 32                  // 2 bars (8 beats) ≈ 3.53 s
        let totalDuration = Double(totalSixteenths) * sixteenth
        let totalFrames = AVAudioFrameCount(totalDuration * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else { return nil }

        buffer.frameLength = totalFrames

        // Syncopated 2-bar Eurodance brass horn riff in C Major / A Minor (16th-note grid):
        // (startSixteenth, lengthInSixteenths, chordFrequenciesHz, bassRootHz)
        struct Stab {
            let startStep: Int
            let lengthSteps: Double
            let chord: [Double]
        }

        // Triad voicings for the horn hook:
        // C5 major (G4, C5, E5), D5/G (G4, B4, D5), A4 minor (E4, A4, C5), G4 major (D4, G4, B4)
        let cMaj: [Double] = [392.00, 523.25, 659.25]
        let dMaj: [Double] = [440.00, 587.33, 739.99]
        let aMin: [Double] = [329.63, 440.00, 523.25]
        let gMaj: [Double] = [293.66, 392.00, 493.88]

        let stabs: [Stab] = [
            // Bar 1: "We like to par-ty!" syncopated horn stabs
            Stab(startStep: 0,  lengthSteps: 1.8, chord: cMaj),
            Stab(startStep: 2,  lengthSteps: 1.8, chord: aMin),
            Stab(startStep: 4,  lengthSteps: 1.8, chord: cMaj),
            Stab(startStep: 6,  lengthSteps: 2.6, chord: dMaj),
            Stab(startStep: 9,  lengthSteps: 2.6, chord: cMaj),
            Stab(startStep: 12, lengthSteps: 1.8, chord: aMin),
            Stab(startStep: 14, lengthSteps: 1.8, chord: gMaj),

            // Bar 2: answer phrase resolving to the high C5/E5 horn hold
            Stab(startStep: 16, lengthSteps: 1.8, chord: aMin),
            Stab(startStep: 18, lengthSteps: 1.8, chord: gMaj),
            Stab(startStep: 20, lengthSteps: 1.8, chord: aMin),
            Stab(startStep: 22, lengthSteps: 1.8, chord: cMaj),
            Stab(startStep: 24, lengthSteps: 2.6, chord: dMaj),
            Stab(startStep: 27, lengthSteps: 4.5, chord: cMaj)
        ]

        // Bass progression per 4-step beat (C2 -> A1 -> F1 -> G1)
        let bassRoots: [Double] = [
            65.41, 65.41, 55.00, 55.00,
            43.65, 43.65, 49.00, 65.41
        ]

        // 7-voice JP-8000 style supersaw detune ratios and stereo pan positions (-1 = L, +1 = R)
        let detunes: [Double] = [-0.019, -0.011, -0.0045, 0.0, 0.0045, 0.011, 0.019]
        let pans: [Double]    = [-0.85,  -0.55,  -0.25,   0.0, 0.25,   0.55,  0.85]
        let gains: [Double]   = [ 0.45,   0.65,   0.85,   1.0, 0.85,   0.65,  0.45]

        // Continuous phase accumulators for 3 chord notes × 7 unison voices (21 oscillators)
        var hornPhases = [Double](repeating: 0.0, count: 21)
        for idx in 0..<21 {
            // Deterministic initial phase offsets so unison voices don't start in a single spike
            hornPhases[idx] = Double((idx * 37) % 100) / 100.0
        }
        var bassPhase: Double = 0.0
        var kickPhase: Double = 0.0

        // 2-pole state-variable low-pass filter state (Left & Right)
        var lpL: Double = 0.0, bpL: Double = 0.0
        var lpR: Double = 0.0, bpR: Double = 0.0
        var bassLp: Double = 0.0

        var peak: Float = 0.0

        for frame in 0..<Int(totalFrames) {
            let time = Double(frame) / sampleRate
            let stepPos = time / sixteenth
            let beatIndex = min(7, Int(time / beatDur))
            let posInBeat = (time / beatDur).truncatingRemainder(dividingBy: 1.0)

            // 1. Supersaw Horn Chord Stabs
            var hornL: Double = 0.0
            var hornR: Double = 0.0
            var filterEnv: Double = 0.2

            if let active = stabs.first(where: {
                let s = Double($0.startStep)
                return stepPos >= s && stepPos < s + $0.lengthSteps
            }) {
                let stabElapsed = (stepPos - Double(active.startStep)) * sixteenth
                let stabDuration = active.lengthSteps * sixteenth
                let stabProgress = stabElapsed / stabDuration

                // Punchy brass ADSR envelope: 8ms attack, snappy decay to 0.72 sustain, smooth release
                let attack = min(1.0, stabElapsed / 0.008)
                let decay = 0.72 + 0.28 * exp(-stabElapsed / 0.065)
                let release = min(1.0, (1.0 - stabProgress) / 0.14)
                let ampEnv = attack * decay * release
                filterEnv = 0.30 + 0.70 * exp(-stabElapsed / 0.085)

                for (nIdx, baseFreq) in active.chord.enumerated() {
                    for vIdx in 0..<7 {
                        let pIdx = nIdx * 7 + vIdx
                        let f = baseFreq * (1.0 + detunes[vIdx])
                        let dt = f / sampleRate
                        hornPhases[pIdx] += dt
                        if hornPhases[pIdx] >= 1.0 { hornPhases[pIdx] -= 1.0 }

                        let sample = bandlimitedSaw(phase: hornPhases[pIdx], dt: dt) * gains[vIdx]
                        let pan = pans[vIdx]
                        let gainL = 0.5 * (1.0 - pan)
                        let gainR = 0.5 * (1.0 + pan)
                        hornL += sample * gainL
                        hornR += sample * gainR
                    }
                }
                hornL *= ampEnv * 0.14
                hornR *= ampEnv * 0.14
            }

            // 2-pole SVF resonant low-pass filter on the horn bus (sweeps 1.2 kHz .. 4.6 kHz)
            let cutoffHz = 1200.0 + 3400.0 * filterEnv
            let fCoeff = min(0.75, 2.0 * sin(.pi * cutoffHz / sampleRate))
            let qCoeff = 0.55 // Warm brass resonance
            let hpL = hornL - lpL - qCoeff * bpL
            bpL += fCoeff * hpL
            lpL += fCoeff * bpL
            let hpR = hornR - lpR - qCoeff * bpR
            bpR += fCoeff * hpR
            lpR += fCoeff * bpR

            // 2. Four-on-the-floor 909 Kick Drum (every quarter-note beat)
            let kickTime = posInBeat * beatDur
            var kickSample: Double = 0.0
            if kickTime < 0.18 {
                let kickFreq = 48.0 + 115.0 * exp(-kickTime / 0.022)
                kickPhase += kickFreq / sampleRate
                if kickPhase >= 1.0 { kickPhase -= 1.0 }
                let kickEnv = min(1.0, kickTime / 0.002) * exp(-kickTime / 0.065)
                kickSample = sin(2.0 * .pi * kickPhase) * kickEnv * 0.55
            } else {
                kickPhase = 0.0
            }

            // 3. Off-beat Eurodance Octave Bass (second half of every beat)
            var bassSample: Double = 0.0
            if posInBeat >= 0.48 && posInBeat < 0.95 {
                let bassTime = (posInBeat - 0.48) * beatDur
                let bassFreq = bassRoots[beatIndex] * 2.0
                let dt = bassFreq / sampleRate
                bassPhase += dt
                if bassPhase >= 1.0 { bassPhase -= 1.0 }
                let rawBass = bandlimitedSaw(phase: bassPhase, dt: dt)
                let bassEnv = min(1.0, bassTime / 0.005) * exp(-bassTime / 0.09)
                bassLp += 0.22 * (rawBass - bassLp)
                bassSample = bassLp * bassEnv * 0.42
            }

            // Smooth tail fade on the final quarter-note
            let globalProgress = Double(frame) / Double(totalFrames)
            let masterFade = globalProgress > 0.86 ? pow((1.0 - globalProgress) / 0.14, 1.3) : 1.0

            let mixL = Float(tanh((lpL + kickSample + bassSample) * 1.15) * masterFade)
            let mixR = Float(tanh((lpR + kickSample + bassSample) * 1.15) * masterFade)

            leftChannel[frame] = mixL
            rightChannel[frame] = mixR
            peak = max(peak, max(abs(mixL), abs(mixR)))
        }

        // Normalize to target peak 0.24 (within the 0.05..0.26 ear-safe window)
        if peak > 0 {
            let scale: Float = 0.24 / peak
            for i in 0..<Int(totalFrames) {
                leftChannel[i] *= scale
                rightChannel[i] *= scale
            }
        }
        return buffer
    }

    /// 1.6-second stereo supersaw turntable brake & sub-bass spin-down for `/yolo off` (#1104).
    static func makePowerDownBuffer(sampleRate: Double = YoloSynth.sampleRate) -> AVAudioPCMBuffer? {
        let duration: Double = 1.6
        let totalFrames = AVAudioFrameCount(duration * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else { return nil }

        buffer.frameLength = totalFrames

        // Start on a rich C-major chord (C4, G4, C5) and brake exponentially down into a 32 Hz sub drop
        let baseNotes: [Double] = [261.63, 392.00, 523.25]
        let detunes: [Double] = [-0.014, -0.006, 0.0, 0.006, 0.014]
        let pans: [Double]    = [-0.75,  -0.35,  0.0, 0.35,  0.75]

        var phases = (0..<15).map { Double(($0 * 29) % 100) / 100.0 }
        var subPhase: Double = 0.0
        var lpL: Double = 0.0, bpL: Double = 0.0
        var lpR: Double = 0.0, bpR: Double = 0.0
        var peak: Float = 0.0

        for i in 0..<Int(totalFrames) {
            let progress = Double(i) / Double(totalFrames)
            // Turntable brake curve: pitch ratios drop from 1.0 down to 0.07
            let pitchRatio = pow(0.07, pow(progress, 1.3))

            var sumL: Double = 0.0
            var sumR: Double = 0.0

            for (nIdx, noteFreq) in baseNotes.enumerated() {
                for vIdx in 0..<5 {
                    let idx = nIdx * 5 + vIdx
                    let freq = noteFreq * pitchRatio * (1.0 + detunes[vIdx])
                    let dt = freq / sampleRate
                    phases[idx] += dt
                    if phases[idx] >= 1.0 { phases[idx] -= 1.0 }
                    let s = bandlimitedSaw(phase: phases[idx], dt: dt)
                    let pan = pans[vIdx]
                    sumL += s * 0.5 * (1.0 - pan)
                    sumR += s * 0.5 * (1.0 + pan)
                }
            }

            // Deep sub-bass sine anchor that carries the bottom end as the saws filter out
            let subFreq = 130.81 * pitchRatio + 28.0 * (1.0 - progress)
            subPhase += subFreq / sampleRate
            if subPhase >= 1.0 { subPhase -= 1.0 }
            let sub = sin(2.0 * .pi * subPhase) * 0.65

            // Resonant low-pass filter closing from 3800 Hz down to 75 Hz
            let cutoffHz = 75.0 + 3725.0 * pow(1.0 - progress, 1.6)
            let fCoeff = min(0.75, 2.0 * sin(.pi * cutoffHz / sampleRate))
            let qCoeff = 0.65
            let inL = sumL * 0.12 + sub
            let inR = sumR * 0.12 + sub

            let hpL = inL - lpL - qCoeff * bpL
            bpL += fCoeff * hpL
            lpL += fCoeff * bpL

            let hpR = inR - lpR - qCoeff * bpR
            bpR += fCoeff * hpR
            lpR += fCoeff * bpR

            let attack = min(1.0, progress * 40.0)
            let release = pow(1.0 - progress, 1.15)
            let env = attack * release

            let outL = Float(tanh(lpL * 1.2) * env)
            let outR = Float(tanh(lpR * 1.2) * env)
            leftChannel[i] = outL
            rightChannel[i] = outR
            peak = max(peak, max(abs(outL), abs(outR)))
        }

        if peak > 0 {
            let scale: Float = 0.34 / peak
            for i in 0..<Int(totalFrames) {
                leftChannel[i] *= scale
                rightChannel[i] *= scale
            }
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
