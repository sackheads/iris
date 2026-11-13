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

    nonisolated(unsafe) private static let cachedVengabusBuffer = makeVengabusBuffer(sampleRate: sampleRate)
    nonisolated(unsafe) private static let cachedPowerDownBuffer = makePowerDownBuffer(sampleRate: sampleRate)

    init() {
        engine.attach(player)
        if let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2) {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        try? engine.start()
    }

    @inline(__always)
    private static func polyBLEP(t: Double, dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1.0
        } else if t > 1.0 - dt {
            let x = (t - 1.0) / dt
            return x * x + x + x + 1.0
        }
        return 0.0
    }

    @inline(__always)
    private static func bandlimitedSaw(phase: Double, dt: Double) -> Double {
        (2.0 * phase - 1.0) - polyBLEP(t: phase, dt: dt)
    }

    /// 90s Eurodance Vengabus horn hook at 136 BPM (in Ab Major):
    /// - Tight octave-stacked PolyBLEP synth-brass lead playing the staccato 16th-note melody
    /// - Brass lip-scoop pitch envelope + snappy resonant SVF bandpass/lowpass bite
    /// - 909 four-on-the-floor kick, off-beat open hi-hat ("untz-tss"), 2 & 4 clap, and Ab-Db-Eb bass
    static func makeVengabusBuffer(sampleRate: Double = YoloSynth.sampleRate) -> AVAudioPCMBuffer? {
        let bpm: Double = 136.0
        let beatDur: Double = 60.0 / bpm          // ~0.4412 s per quarter-note beat
        let sixteenth: Double = beatDur / 4.0     // ~0.1103 s per 16th note
        let totalSixteenths = 64                  // Full 4-bar hook (16 beats) ≈ 7.06 s
        let totalDuration = Double(totalSixteenths) * sixteenth
        let totalFrames = AVAudioFrameCount(totalDuration * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else { return nil }

        buffer.frameLength = totalFrames

        // Pitch constants in Ab Major
        let Eb4 = 311.13
        let Ab4 = 415.30
        let Bb4 = 466.16
        let C5  = 523.25
        let Db5 = 554.37
        let Eb5 = 622.25
        let F5  = 698.46

        struct NoteEvent {
            let step: Double      // Position on the 64-step 16th-note grid
            let gateSteps: Double // Audible gate length (shorter than step delta for staccato brass)
            let freq: Double      // Lead melody pitch (Hz)
        }

        let melody: [NoteEvent] = [
            // Bar 1 (Ab Major): C5 - C5 Eb5 C5 Ab4 | C5 - C5 Eb5 C5 Ab4
            NoteEvent(step: 0,  gateSteps: 1.45, freq: C5),
            NoteEvent(step: 2,  gateSteps: 0.75, freq: C5),
            NoteEvent(step: 3,  gateSteps: 0.80, freq: Eb5),
            NoteEvent(step: 4,  gateSteps: 1.45, freq: C5),
            NoteEvent(step: 6,  gateSteps: 1.45, freq: Ab4),

            NoteEvent(step: 8,  gateSteps: 1.45, freq: C5),
            NoteEvent(step: 10, gateSteps: 0.75, freq: C5),
            NoteEvent(step: 11, gateSteps: 0.80, freq: Eb5),
            NoteEvent(step: 12, gateSteps: 1.45, freq: C5),
            NoteEvent(step: 14, gateSteps: 1.45, freq: Ab4),

            // Bar 2 (Db Major -> Eb Major): Db5 - Db5 F5 Eb5 Db5 | C5 Bb4 Ab4 (pickup Eb4)
            NoteEvent(step: 16, gateSteps: 1.45, freq: Db5),
            NoteEvent(step: 18, gateSteps: 0.75, freq: Db5),
            NoteEvent(step: 19, gateSteps: 0.80, freq: F5),
            NoteEvent(step: 20, gateSteps: 1.45, freq: Eb5),
            NoteEvent(step: 22, gateSteps: 1.45, freq: Db5),

            NoteEvent(step: 24, gateSteps: 1.45, freq: C5),
            NoteEvent(step: 26, gateSteps: 1.45, freq: Bb4),
            NoteEvent(step: 28, gateSteps: 2.40, freq: Ab4),
            NoteEvent(step: 31, gateSteps: 0.80, freq: Eb4),

            // Bar 3 (Ab Major): C5 - C5 Eb5 C5 Ab4 | C5 - C5 Eb5 C5 Ab4
            NoteEvent(step: 32, gateSteps: 1.45, freq: C5),
            NoteEvent(step: 34, gateSteps: 0.75, freq: C5),
            NoteEvent(step: 35, gateSteps: 0.80, freq: Eb5),
            NoteEvent(step: 36, gateSteps: 1.45, freq: C5),
            NoteEvent(step: 38, gateSteps: 1.45, freq: Ab4),

            NoteEvent(step: 40, gateSteps: 1.45, freq: C5),
            NoteEvent(step: 42, gateSteps: 0.75, freq: C5),
            NoteEvent(step: 43, gateSteps: 0.80, freq: Eb5),
            NoteEvent(step: 44, gateSteps: 1.45, freq: C5),
            NoteEvent(step: 46, gateSteps: 1.45, freq: Ab4),

            // Bar 4 (Db Major -> Eb Major -> Ab Major resolution)
            NoteEvent(step: 48, gateSteps: 1.45, freq: Db5),
            NoteEvent(step: 50, gateSteps: 0.75, freq: Db5),
            NoteEvent(step: 51, gateSteps: 0.80, freq: F5),
            NoteEvent(step: 52, gateSteps: 1.45, freq: Eb5),
            NoteEvent(step: 54, gateSteps: 0.75, freq: Db5),
            NoteEvent(step: 55, gateSteps: 0.80, freq: C5),

            NoteEvent(step: 56, gateSteps: 1.45, freq: Bb4),
            NoteEvent(step: 58, gateSteps: 1.45, freq: Eb5),
            NoteEvent(step: 60, gateSteps: 3.40, freq: Ab4)
        ]

        // Bass root per quarter-note beat across the 4 bars (16 beats: Ab1, Db2, Eb2)
        let Ab1 = 51.91, Db2 = 69.30, Eb2 = 77.78
        let bassRoots: [Double] = [
            Ab1, Ab1, Ab1, Ab1,
            Db2, Db2, Eb2, Eb2,
            Ab1, Ab1, Ab1, Ab1,
            Db2, Eb2, Ab1, Ab1
        ]

        // Tight Eurodance brass stack:
        // 3 harmonic layers (Sub-octave 0.5x, Unison 1.0x, Fifth 1.498x for brassy bite)
        // × 5 tightly detuned unison voices (±0.45% max so pitch stays laser-focused)
        let layerMults: [Double] = [0.5, 1.0, 1.4983]
        let layerGains: [Double] = [0.55, 1.0, 0.28]
        let detunes: [Double]    = [-0.0045, -0.002, 0.0, 0.002, 0.0045]
        let pans: [Double]       = [-0.70,   -0.35,  0.0, 0.35,  0.70]

        var hornPhases = (0..<15).map { Double(($0 * 41) % 100) / 100.0 }
        var bassPhase: Double = 0.0
        var kickPhase: Double = 0.0
        var rngState: UInt64 = 0xCAFEBABE_19981109

        @inline(__always)
        func whiteNoise() -> Double {
            rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
            let bits = UInt32(truncatingIfNeeded: rngState >> 32)
            return Double(bits) / Double(UInt32.max) * 2.0 - 1.0
        }

        // Filter state
        var lpL: Double = 0.0, bpL: Double = 0.0
        var lpR: Double = 0.0, bpR: Double = 0.0
        var bassLp: Double = 0.0
        var hatLp: Double = 0.0
        var clapBp: Double = 0.0, clapLp: Double = 0.0

        var peak: Float = 0.0

        for frame in 0..<Int(totalFrames) {
            let time = Double(frame) / sampleRate
            let stepPos = time / sixteenth
            let beatIndex = min(15, Int(time / beatDur))
            let posInBeat = (time / beatDur).truncatingRemainder(dividingBy: 1.0)

            // 1. Staccato Synth-Brass Lead
            var hornL: Double = 0.0
            var hornR: Double = 0.0
            var filterEnv: Double = 0.08

            if let active = melody.first(where: {
                stepPos >= $0.step && stepPos < $0.step + $0.gateSteps
            }) {
                let noteElapsed = (stepPos - active.step) * sixteenth
                let noteDur = active.gateSteps * sixteenth
                let noteProgress = noteElapsed / noteDur

                // Snappy brass envelope: 3ms attack, punchy decay, crisp staccato release
                let attack = min(1.0, noteElapsed / 0.003)
                let decay = 0.65 + 0.35 * exp(-noteElapsed / 0.045)
                let release = min(1.0, (1.0 - noteProgress) / 0.18)
                let ampEnv = attack * decay * release

                // Classic 90s brass lip-scoop: starts ~45 cents flat and locks in within 12ms
                let pitchScoop = 1.0 - 0.026 * exp(-noteElapsed / 0.008)
                filterEnv = 0.22 + 0.78 * exp(-noteElapsed / 0.055)

                for lIdx in 0..<3 {
                    let baseF = active.freq * layerMults[lIdx] * pitchScoop
                    let lGain = layerGains[lIdx]
                    for vIdx in 0..<5 {
                        let pIdx = lIdx * 5 + vIdx
                        let f = baseF * (1.0 + detunes[vIdx])
                        let dt = f / sampleRate
                        hornPhases[pIdx] += dt
                        if hornPhases[pIdx] >= 1.0 { hornPhases[pIdx] -= 1.0 }

                        // Mix saw + square-ish pulse for nasal Eurodance trumpet/horn bite
                        let saw = bandlimitedSaw(phase: hornPhases[pIdx], dt: dt)
                        let pulsePhase = (hornPhases[pIdx] + 0.42).truncatingRemainder(dividingBy: 1.0)
                        let pulse = saw - bandlimitedSaw(phase: pulsePhase, dt: dt)
                        let osc = (0.65 * saw + 0.35 * pulse) * lGain

                        let pan = pans[vIdx]
                        hornL += osc * 0.5 * (1.0 - pan)
                        hornR += osc * 0.5 * (1.0 + pan)
                    }
                }
                hornL *= ampEnv * 0.16
                hornR *= ampEnv * 0.16
            }

            // Brassy resonant SVF (blends low-pass body + band-pass horn formant around 1.1..5.0 kHz)
            let cutoffHz = 950.0 + 4100.0 * filterEnv
            let fCoeff = min(0.78, 2.0 * sin(.pi * cutoffHz / sampleRate))
            let qCoeff = 0.48
            let hpL = hornL - lpL - qCoeff * bpL
            bpL += fCoeff * hpL
            lpL += fCoeff * bpL
            let hpR = hornR - lpR - qCoeff * bpR
            bpR += fCoeff * hpR
            lpR += fCoeff * bpR

            let brassL = lpL * 0.75 + bpL * 0.55
            let brassR = lpR * 0.75 + bpR * 0.55

            // 2. Four-on-the-floor 909 Kick Drum
            let kickTime = posInBeat * beatDur
            var kickSample: Double = 0.0
            if kickTime < 0.18 {
                let kickFreq = 50.0 + 130.0 * exp(-kickTime / 0.018)
                kickPhase += kickFreq / sampleRate
                if kickPhase >= 1.0 { kickPhase -= 1.0 }
                let kickEnv = min(1.0, kickTime / 0.0015) * exp(-kickTime / 0.062)
                kickSample = sin(2.0 * .pi * kickPhase) * kickEnv * 0.62
            } else {
                kickPhase = 0.0
            }

            // 3. Off-beat Eurodance Octave Bass (pumps on the "&" of every beat)
            var bassSample: Double = 0.0
            if posInBeat >= 0.46 && posInBeat < 0.94 {
                let bassTime = (posInBeat - 0.46) * beatDur
                let bassFreq = bassRoots[beatIndex] * 2.0
                let dt = bassFreq / sampleRate
                bassPhase += dt
                if bassPhase >= 1.0 { bassPhase -= 1.0 }
                let rawBass = bandlimitedSaw(phase: bassPhase, dt: dt)
                let bassEnv = min(1.0, bassTime / 0.004) * exp(-bassTime / 0.085)
                bassLp += 0.26 * (rawBass - bassLp)
                bassSample = bassLp * bassEnv * 0.44
            }

            // 4. 909 Off-Beat Open Hi-Hat ("untz-tss")
            var hatSample: Double = 0.0
            if posInBeat >= 0.48 && posInBeat < 0.88 {
                let hatTime = (posInBeat - 0.48) * beatDur
                let noise = whiteNoise()
                hatLp += 0.35 * (noise - hatLp)
                let hpNoise = noise - hatLp
                let hatEnv = min(1.0, hatTime / 0.003) * exp(-hatTime / 0.055)
                hatSample = hpNoise * hatEnv * 0.16
            }

            // 5. 909 Handclap on Beats 2 and 4 (beatIndex % 2 == 1)
            var clapSample: Double = 0.0
            if beatIndex % 2 == 1 && kickTime < 0.11 {
                let noise = whiteNoise()
                let cHp = noise - clapLp - 0.4 * clapBp
                clapBp += 0.28 * cHp
                clapLp += 0.28 * clapBp
                // Multi-burst flam in the first 25ms + reverb tail
                let burst = kickTime < 0.024 ? (0.6 + 0.4 * sin(kickTime * 950.0)) : 1.0
                let clapEnv = burst * exp(-kickTime / 0.032)
                clapSample = clapBp * clapEnv * 0.22
            }

            // Duck the horn slightly under the kick transient for that club pump
            let duck = 1.0 - 0.28 * exp(-kickTime / 0.045)

            let globalProgress = Double(frame) / Double(totalFrames)
            let masterFade = globalProgress > 0.92 ? pow((1.0 - globalProgress) / 0.08, 1.3) : 1.0

            let mixL = Float(tanh(((brassL + bassSample) * duck + kickSample + hatSample + clapSample) * 1.2) * masterFade)
            let mixR = Float(tanh(((brassR + bassSample) * duck + kickSample + hatSample + clapSample) * 1.2) * masterFade)

            leftChannel[frame] = mixL
            rightChannel[frame] = mixR
            peak = max(peak, max(abs(mixL), abs(mixR)))
        }

        if peak > 0 {
            let scale: Float = 0.24 / peak
            for i in 0..<Int(totalFrames) {
                leftChannel[i] *= scale
                rightChannel[i] *= scale
            }
        }
        return buffer
    }

    /// Turntable brake spin-down from an Ab Major triad + sub-bass sine anchor with closing SVF.
    static func makePowerDownBuffer(sampleRate: Double = YoloSynth.sampleRate) -> AVAudioPCMBuffer? {
        let duration: Double = 1.6
        let totalFrames = AVAudioFrameCount(duration * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else { return nil }

        buffer.frameLength = totalFrames

        let startChord: [Double] = [415.30, 523.25, 622.25] // Ab4, C5, Eb5
        let detunes: [Double] = [-0.008, 0.0, 0.008]
        let pans: [Double] = [-0.6, 0.0, 0.6]

        var phases = (0..<9).map { Double(($0 * 37) % 100) / 100.0 }
        var subPhase: Double = 0.0
        var lpL: Double = 0.0, bpL: Double = 0.0
        var lpR: Double = 0.0, bpR: Double = 0.0
        var peak: Float = 0.0

        for i in 0..<Int(totalFrames) {
            let progress = Double(i) / Double(totalFrames)
            let pitchMult = pow(0.07, pow(progress, 1.3))

            var sumL: Double = 0.0
            var sumR: Double = 0.0

            for nIdx in 0..<3 {
                for vIdx in 0..<3 {
                    let pIdx = nIdx * 3 + vIdx
                    let f = startChord[nIdx] * pitchMult * (1.0 + detunes[vIdx])
                    let dt = f / sampleRate
                    phases[pIdx] += dt
                    if phases[pIdx] >= 1.0 { phases[pIdx] -= 1.0 }
                    let saw = bandlimitedSaw(phase: phases[pIdx], dt: dt)
                    let pan = pans[vIdx]
                    sumL += saw * 0.5 * (1.0 - pan)
                    sumR += saw * 0.5 * (1.0 + pan)
                }
            }

            let subFreq = 207.65 * pow(32.0 / 207.65, pow(progress, 1.25))
            subPhase += subFreq / sampleRate
            if subPhase >= 1.0 { subPhase -= 1.0 }
            let subSine = sin(2.0 * .pi * subPhase) * 0.55

            let cutoffHz = 3800.0 * pow(75.0 / 3800.0, pow(progress, 0.9))
            let fCoeff = min(0.75, 2.0 * sin(.pi * cutoffHz / sampleRate))
            let qCoeff = 0.55
            let hpL = (sumL * 0.18) - lpL - qCoeff * bpL
            bpL += fCoeff * hpL
            lpL += fCoeff * bpL
            let hpR = (sumR * 0.18) - lpR - qCoeff * bpR
            bpR += fCoeff * hpR
            lpR += fCoeff * bpR

            let attack = min(1.0, progress * 35.0)
            let release = pow(1.0 - progress, 1.15)
            let env = attack * release

            let outL = Float(tanh((lpL + subSine) * env * 1.4))
            let outR = Float(tanh((lpR + subSine) * env * 1.4))
            leftChannel[i] = outL
            rightChannel[i] = outR
            peak = max(peak, max(abs(outL), abs(outR)))
        }

        if peak > 0 {
            let scale: Float = 0.28 / peak
            for i in 0..<Int(totalFrames) {
                leftChannel[i] *= scale
                rightChannel[i] *= scale
            }
        }
        return buffer
    }

    func playVengabusYolo() {
        guard let buffer = Self.cachedVengabusBuffer else { return }
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }

    func playPowerDown() {
        guard let buffer = Self.cachedPowerDownBuffer else { return }
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }
}
