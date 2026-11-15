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

    /// 90s Eurodance Vengabus dominant synth horn hook at 136 BPM (#1143):
    /// - Exact tab transcription: G-F-G-F-G -> C-C (x2), then G-F-G-F-G -> high Ab-Ab / Bb-C (x2)
    /// - Layered over C minor / Ab Major backing stabs, 909 kick, off-beat bass, and open hi-hat
    static func makeVengabusBuffer(sampleRate: Double = YoloSynth.sampleRate) -> AVAudioPCMBuffer? {
        let bpm: Double = 136.0
        let beatDur: Double = 60.0 / bpm          // ~0.4412 s per quarter-note beat
        let sixteenth: Double = beatDur / 4.0     // ~0.1103 s per 16th note
        let pickupSteps = 2                       // "& of 4" pickup before Bar 1
        let totalSixteenths = 64 + pickupSteps    // pickup + 4 bars (16 beats) ≈ 7.28 s
        let totalDuration = Double(totalSixteenths) * sixteenth
        let totalFrames = AVAudioFrameCount(totalDuration * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else { return nil }

        buffer.frameLength = totalFrames

        // Exact pitches for the dominant 2:55 synth lead:
        // G|-12-10-12-10-12-| D|-10-10-| (G - F - G - F - G -> C - C)
        // and B|-8-8-| (G - G)
        let C5  = 523.25
        let F5  = 698.46
        let G5  = 783.99

        struct LeadNote {
            let step: Double
            let gateSteps: Double
            let freq: Double
            let accent: Double
        }

        // "di-du-di-du-di-daaa daa / di-du-di-du-di-daaa daa"
        // 8th-note hook with "& of 4" pickup:
        //   & of 4 (step -2/14): G5 ("di")
        //   1      (step 0):     F5 ("du")
        //   & of 1 (step 2):     G5 ("di")
        //   2      (step 4):     F5 ("du")
        //   & of 2 (step 6):     G5 ("di")
        //   3      (step 8):     C5 / G5 ("daaa", quarter note)
        //   4      (step 12):    C5 / G5 ("daa", 8th note before next pickup)
        let leadMelody: [LeadNote] = [
            // --- Bar 1: (G) -> F-G-F-G -> C-C ---
            LeadNote(step: -2.0, gateSteps: 0.95, freq: G5, accent: 1.05), // pickup (& of 4)
            LeadNote(step: 0.0,  gateSteps: 0.95, freq: F5, accent: 0.95),
            LeadNote(step: 2.0,  gateSteps: 0.95, freq: G5, accent: 1.05),
            LeadNote(step: 4.0,  gateSteps: 0.95, freq: F5, accent: 0.95),
            LeadNote(step: 6.0,  gateSteps: 0.95, freq: G5, accent: 1.05),
            LeadNote(step: 8.0,  gateSteps: 2.90, freq: C5, accent: 1.25), // "daaa" (beat 3)
            LeadNote(step: 12.0, gateSteps: 1.35, freq: C5, accent: 1.15), // "daa"  (beat 4)

            // --- Bar 2: (G) -> F-G-F-G -> C-C ---
            LeadNote(step: 14.0, gateSteps: 0.95, freq: G5, accent: 1.05), // pickup (& of 4)
            LeadNote(step: 16.0, gateSteps: 0.95, freq: F5, accent: 0.95),
            LeadNote(step: 18.0, gateSteps: 0.95, freq: G5, accent: 1.05),
            LeadNote(step: 20.0, gateSteps: 0.95, freq: F5, accent: 0.95),
            LeadNote(step: 22.0, gateSteps: 0.95, freq: G5, accent: 1.05),
            LeadNote(step: 24.0, gateSteps: 2.90, freq: C5, accent: 1.25),
            LeadNote(step: 28.0, gateSteps: 1.35, freq: C5, accent: 1.15),

            // --- Bar 3: (G) -> F-G-F-G -> G-G ---
            LeadNote(step: 30.0, gateSteps: 0.95, freq: G5, accent: 1.05), // pickup (& of 4)
            LeadNote(step: 32.0, gateSteps: 0.95, freq: F5, accent: 0.95),
            LeadNote(step: 34.0, gateSteps: 0.95, freq: G5, accent: 1.05),
            LeadNote(step: 36.0, gateSteps: 0.95, freq: F5, accent: 0.95),
            LeadNote(step: 38.0, gateSteps: 0.95, freq: G5, accent: 1.05),
            LeadNote(step: 40.0, gateSteps: 2.90, freq: G5, accent: 1.25),
            LeadNote(step: 44.0, gateSteps: 1.35, freq: G5, accent: 1.15),

            // --- Bar 4: (G) -> F-G-F-G -> G-G ---
            LeadNote(step: 46.0, gateSteps: 0.95, freq: G5, accent: 1.05), // pickup (& of 4)
            LeadNote(step: 48.0, gateSteps: 0.95, freq: F5, accent: 0.95),
            LeadNote(step: 50.0, gateSteps: 0.95, freq: G5, accent: 1.05),
            LeadNote(step: 52.0, gateSteps: 0.95, freq: F5, accent: 0.95),
            LeadNote(step: 54.0, gateSteps: 0.95, freq: G5, accent: 1.05),
            LeadNote(step: 56.0, gateSteps: 2.90, freq: G5, accent: 1.25),
            LeadNote(step: 60.0, gateSteps: 2.90, freq: G5, accent: 1.20)
        ]

        // Backing chords in C minor (Cm -> Cm -> Bb -> Cm)
        let cMin: [Double] = [261.63, 311.13, 392.00]
        let bbMaj: [Double] = [233.08, 293.66, 349.23]
        let barChords: [[Double]] = [cMin, cMin, bbMaj, cMin]
        let bassBarRoots: [Double] = [65.41, 65.41, 58.27, 65.41]

        // Lead synth-horn unison voices (tight detune so pitch is razor-sharp)
        let leadDetunes: [Double] = [-0.003, -0.001, 0.0, 0.001, 0.003]
        let leadPans: [Double]    = [-0.50,  -0.25,  0.0, 0.25,  0.50]

        // Background chord detunes
        let padDetunes: [Double]  = [-0.012, 0.0, 0.012]
        let padPans: [Double]     = [-0.80,  0.0, 0.80]

        var leadPhases = (0..<10).map { Double(($0 * 43) % 100) / 100.0 }
        var padPhases  = (0..<9).map  { Double(($0 * 29) % 100) / 100.0 }
        var bassPhase: Double = 0.0
        var kickPhase: Double = 0.0
        var rngState: UInt64 = 0xCAFEBABE_19981109

        @inline(__always)
        func whiteNoise() -> Double {
            rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
            let bits = UInt32(truncatingIfNeeded: rngState >> 32)
            return Double(bits) / Double(UInt32.max) * 2.0 - 1.0
        }

        var leadLpL: Double = 0.0, leadBpL: Double = 0.0
        var leadLpR: Double = 0.0, leadBpR: Double = 0.0
        var padLpL: Double = 0.0,  padLpR: Double = 0.0
        var bassLp: Double = 0.0
        var hatLp: Double = 0.0
        var peak: Float = 0.0

        for frame in 0..<Int(totalFrames) {
            let time = Double(frame) / sampleRate
            let stepPos = (time / sixteenth) - Double(pickupSteps)

            // 1. DOMINANT SYNTH-HORN HOOK (G5-F5-G5-F5-G5 -> C5-C5)
            var leadL: Double = 0.0
            var leadR: Double = 0.0
            var leadFilterEnv: Double = 0.15

            if let note = leadMelody.first(where: {
                stepPos >= $0.step && stepPos < $0.step + $0.gateSteps
            }) {
                let elapsed = (stepPos - note.step) * sixteenth
                let dur = note.gateSteps * sixteenth
                let prog = elapsed / dur

                let attack = min(1.0, elapsed / 0.002)
                let decay = 0.70 + 0.30 * exp(-elapsed / 0.04)
                let relFrac = min(1.0, max(0.0, (1.0 - prog) / 0.30))
                let release = relFrac * relFrac * (3.0 - 2.0 * relFrac)
                let ampEnv = attack * decay * release * note.accent

                // Slight brass attack scoop
                let scoop = 1.0 - 0.015 * exp(-elapsed / 0.005)
                let baseFreq = note.freq * scoop
                leadFilterEnv = (0.40 + 0.60 * exp(-elapsed / 0.07)) * note.accent

                for vIdx in 0..<5 {
                    let fMain = baseFreq * (1.0 + leadDetunes[vIdx])
                    let dtMain = fMain / sampleRate
                    leadPhases[vIdx] += dtMain
                    if leadPhases[vIdx] >= 1.0 { leadPhases[vIdx] -= 1.0 }

                    // Octave-down brass body layer (plays G4-F4-G4-F4-G4 -> C4-C4 underneath)
                    let dtSub = dtMain * 0.5
                    leadPhases[vIdx + 5] += dtSub
                    if leadPhases[vIdx + 5] >= 1.0 { leadPhases[vIdx + 5] -= 1.0 }

                    let sawMain = bandlimitedSaw(phase: leadPhases[vIdx], dt: dtMain)
                    let pulsePhase = (leadPhases[vIdx] + 0.40).truncatingRemainder(dividingBy: 1.0)
                    let pulseMain = sawMain - bandlimitedSaw(phase: pulsePhase, dt: dtMain)
                    let subSaw = bandlimitedSaw(phase: leadPhases[vIdx + 5], dt: dtSub)

                    let voice = (0.55 * sawMain + 0.45 * pulseMain) + 0.50 * subSaw
                    let pan = leadPans[vIdx]
                    leadL += voice * 0.5 * (1.0 - pan)
                    leadR += voice * 0.5 * (1.0 + pan)
                }
                // Dominant lead level so it unmistakably sits on top of the mix
                leadL *= ampEnv * 0.24
                leadR *= ampEnv * 0.24
            } else {
                leadBpL *= 0.96
                leadBpR *= 0.96
            }

            let leadCutoff = min(6800.0, 1500.0 + 4000.0 * leadFilterEnv)
            let fLead = min(0.82, 2.0 * sin(.pi * leadCutoff / sampleRate))
            let qLead = 0.45
            let hpL = leadL - leadLpL - qLead * leadBpL
            leadBpL += fLead * hpL
            leadLpL += fLead * leadBpL
            let hpR = leadR - leadLpR - qLead * leadBpR
            leadBpR += fLead * hpR
            leadLpR += fLead * leadBpR

            let trumpetOutL = leadLpL * 0.75 + leadBpL * 0.65
            let trumpetOutR = leadLpR * 0.75 + leadBpR * 0.65

            // 2. BACKGROUND GROOVE (909 Kick, Off-Beat Bass, Hi-Hat & Backing Stabs)
            var backingL: Double = 0.0
            var backingR: Double = 0.0
            var kickSample: Double = 0.0
            var bassSample: Double = 0.0
            var hatSample: Double = 0.0

            if stepPos >= 0.0 {
                let beatIndex = Int(stepPos / 4.0)
                let barIndex = min(3, beatIndex / 4)
                let posInBeat = (stepPos / 4.0).truncatingRemainder(dividingBy: 1.0)
                let kickTime = posInBeat * beatDur

                // Subtle off-beat chord stabs
                let chord = barChords[barIndex]
                let stabGate = posInBeat >= 0.50 && posInBeat < 0.90
                let stabEnv = stabGate ? exp(-(posInBeat - 0.50) * beatDur / 0.08) : 0.0
                if stabEnv > 0.001 {
                    for (nIdx, cFreq) in chord.enumerated() {
                        for vIdx in 0..<3 {
                            let idx = nIdx * 3 + vIdx
                            let dt = (cFreq * (1.0 + padDetunes[vIdx])) / sampleRate
                            padPhases[idx] += dt
                            if padPhases[idx] >= 1.0 { padPhases[idx] -= 1.0 }
                            let s = bandlimitedSaw(phase: padPhases[idx], dt: dt) * stabEnv * 0.045
                            backingL += s * 0.5 * (1.0 - padPans[vIdx])
                            backingR += s * 0.5 * (1.0 + padPans[vIdx])
                        }
                    }
                }
                padLpL += 0.22 * (backingL - padLpL)
                padLpR += 0.22 * (backingR - padLpR)

                // 909 Kick
                if kickTime < 0.18 {
                    let kickFreq = 48.0 + 125.0 * exp(-kickTime / 0.019)
                    kickPhase += kickFreq / sampleRate
                    if kickPhase >= 1.0 { kickPhase -= 1.0 }
                    let kickEnv = min(1.0, kickTime / 0.0015) * exp(-kickTime / 0.062)
                    kickSample = sin(2.0 * .pi * kickPhase) * kickEnv * 0.50
                } else {
                    kickPhase = 0.0
                }

                // Off-beat Bass
                if posInBeat >= 0.50 && posInBeat < 0.95 {
                    let bassTime = (posInBeat - 0.50) * beatDur
                    let bassFreq = bassBarRoots[barIndex] * 2.0
                    let dt = bassFreq / sampleRate
                    bassPhase += dt
                    if bassPhase >= 1.0 { bassPhase -= 1.0 }
                    let rawBass = bandlimitedSaw(phase: bassPhase, dt: dt)
                    let bassEnv = min(1.0, bassTime / 0.004) * exp(-bassTime / 0.085)
                    bassLp += 0.24 * (rawBass - bassLp)
                    bassSample = bassLp * bassEnv * 0.35
                } else {
                    bassPhase = 0.0
                }

                // 909 Off-Beat Open Hat
                if posInBeat >= 0.50 && posInBeat < 0.88 {
                    let hatTime = (posInBeat - 0.50) * beatDur
                    let noise = whiteNoise()
                    hatLp += 0.35 * (noise - hatLp)
                    let hpNoise = noise - hatLp
                    let hatEnv = min(1.0, hatTime / 0.002) * exp(-hatTime / 0.055)
                    hatSample = hpNoise * hatEnv * 0.12
                }
            }

            let globalProgress = Double(frame) / Double(totalFrames)
            let masterFade = globalProgress > 0.80 ? pow((1.0 - globalProgress) / 0.20, 1.5) : 1.0

            let mixL = Float(tanh((trumpetOutL + padLpL + kickSample + bassSample + hatSample) * 1.15) * masterFade)
            let mixR = Float(tanh((trumpetOutR + padLpR + kickSample + bassSample + hatSample) * 1.15) * masterFade)

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
