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

    /// 90s Eurodance Vengabus full drop at 136 BPM (#1143):
    /// - Layer 1 (Lead Hook): High-pitched staccato synth-trumpet playing the iconic
    ///   "ba-dat-dat-dat-dat-DAHHH-dahh" carnival horn melody in Eb Major
    /// - Layer 2 (Backing Stabs): Warm supersaw triad chords pumping underneath
    /// - Layer 3 (Rhythm Section): 909 four-on-the-floor kick, off-beat octave bass, open hi-hat
    static func makeVengabusBuffer(sampleRate: Double = YoloSynth.sampleRate) -> AVAudioPCMBuffer? {
        let bpm: Double = 136.0
        let beatDur: Double = 60.0 / bpm          // ~0.4412 s per quarter-note beat
        let sixteenth: Double = beatDur / 4.0     // ~0.1103 s per 16th note
        let pickupSteps: Double = 2.0             // 2-sixteenth pickup ("ba-") before Bar 1 Beat 1
        let totalSixteenths = 64                  // 4 bars (16 beats) + pickup ≈ 7.28 s
        let totalDuration = (Double(totalSixteenths) + pickupSteps) * sixteenth
        let totalFrames = AVAudioFrameCount(totalDuration * sampleRate)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              let leftChannel = buffer.floatChannelData?[0],
              let rightChannel = buffer.floatChannelData?[1] else { return nil }

        buffer.frameLength = totalFrames

        // Lead Horn Pitches in Eb Major (High Register so it cuts right over the backing track)
        let Bb4 = 466.16
        let Eb5 = 622.25
        let F5  = 698.46
        let G5  = 783.99
        let Ab5 = 830.61
        let Bb5 = 932.33
        let C6  = 1046.50

        struct LeadNote {
            let step: Double      // Step relative to Bar 1 Beat 1 (negative = pickup)
            let gateSteps: Double // Short for "dat", long for "DAHHH"
            let freq: Double
            let accent: Double    // Extra filter brightness & punch on "DAHHH-dahh"
        }

        // The "ba - dat-dat-dat-dat-dat - DAHHH - dahh" Vengabus trumpet melody:
        let leadMelody: [LeadNote] = [
            // Pickup: "ba-"
            LeadNote(step: -1.0, gateSteps: 0.65, freq: Bb4, accent: 0.9),

            // Phrase 1 (Bar 1): "dat-dat-dat-dat-dat   DAHHH - dahh" (Eb5 x5 -> C6 - Bb5)
            LeadNote(step: 0.0,  gateSteps: 0.58, freq: Eb5, accent: 1.0),
            LeadNote(step: 1.0,  gateSteps: 0.58, freq: Eb5, accent: 0.85),
            LeadNote(step: 2.0,  gateSteps: 0.58, freq: Eb5, accent: 0.9),
            LeadNote(step: 3.0,  gateSteps: 0.58, freq: Eb5, accent: 0.85),
            LeadNote(step: 4.0,  gateSteps: 1.35, freq: Eb5, accent: 1.0),
            LeadNote(step: 6.0,  gateSteps: 2.40, freq: C6,  accent: 1.25),  // "DAHHH"
            LeadNote(step: 9.0,  gateSteps: 2.20, freq: Bb5, accent: 1.15),  // "dahh"

            // Phrase 2 (Bar 2): "dat-dat-dat-dat-dat   DAAHHH - dahhh" (Eb5 x5 -> Ab5 - G5)
            LeadNote(step: 15.0, gateSteps: 0.60, freq: Bb4, accent: 0.85),  // tiny "ba" pickup
            LeadNote(step: 16.0, gateSteps: 0.58, freq: Eb5, accent: 1.0),
            LeadNote(step: 17.0, gateSteps: 0.58, freq: Eb5, accent: 0.85),
            LeadNote(step: 18.0, gateSteps: 0.58, freq: Eb5, accent: 0.9),
            LeadNote(step: 19.0, gateSteps: 0.58, freq: Eb5, accent: 0.85),
            LeadNote(step: 20.0, gateSteps: 1.35, freq: Eb5, accent: 1.0),
            LeadNote(step: 22.0, gateSteps: 2.40, freq: Ab5, accent: 1.25),  // "DAAHHH"
            LeadNote(step: 25.0, gateSteps: 2.20, freq: G5,  accent: 1.15),  // "dahhh"

            // Phrase 3 (Bar 3): "ba - dat-dat-dat-dat-dat   DAHHH - dahh" (Eb5 x5 -> C6 - Bb5)
            LeadNote(step: 31.0, gateSteps: 0.60, freq: Bb4, accent: 0.85),
            LeadNote(step: 32.0, gateSteps: 0.58, freq: Eb5, accent: 1.0),
            LeadNote(step: 33.0, gateSteps: 0.58, freq: Eb5, accent: 0.85),
            LeadNote(step: 34.0, gateSteps: 0.58, freq: Eb5, accent: 0.9),
            LeadNote(step: 35.0, gateSteps: 0.58, freq: Eb5, accent: 0.85),
            LeadNote(step: 36.0, gateSteps: 1.35, freq: Eb5, accent: 1.0),
            LeadNote(step: 38.0, gateSteps: 2.40, freq: C6,  accent: 1.25),  // "DAHHH"
            LeadNote(step: 41.0, gateSteps: 2.20, freq: Bb5, accent: 1.15),  // "dahh"

            // Phrase 4 (Bar 4 turnaround): "dat-dat-dat-dat-dat   DAHHH - dahh - dahh - dahh"
            LeadNote(step: 47.0, gateSteps: 0.60, freq: Bb4, accent: 0.85),
            LeadNote(step: 48.0, gateSteps: 0.58, freq: Eb5, accent: 1.0),
            LeadNote(step: 49.0, gateSteps: 0.58, freq: Eb5, accent: 0.85),
            LeadNote(step: 50.0, gateSteps: 0.58, freq: Eb5, accent: 0.9),
            LeadNote(step: 51.0, gateSteps: 0.58, freq: Eb5, accent: 0.85),
            LeadNote(step: 52.0, gateSteps: 1.35, freq: Eb5, accent: 1.0),
            LeadNote(step: 54.0, gateSteps: 1.75, freq: Ab5, accent: 1.25),  // "DAHHH"
            LeadNote(step: 56.0, gateSteps: 1.75, freq: G5,  accent: 1.15),  // "dahh"
            LeadNote(step: 58.0, gateSteps: 1.75, freq: F5,  accent: 1.10),  // "dahh"
            LeadNote(step: 60.0, gateSteps: 3.20, freq: Eb5, accent: 1.20)   // resolves on Eb5
        ]

        // Backing chord stabs (Eb Major -> Ab Major -> Eb Major -> Bb Major)
        let ebMaj: [Double] = [311.13, 392.00, 466.16] // Eb4, G4, Bb4
        let abMaj: [Double] = [261.63, 311.13, 415.30] // C4, Eb4, Ab4
        let bbMaj: [Double] = [293.66, 349.23, 466.16] // D4, F4, Bb4
        let barChords: [[Double]] = [ebMaj, abMaj, ebMaj, bbMaj]

        // Bass roots per bar (Eb1 -> Ab1 -> Eb1 -> Bb1)
        let bassBarRoots: [Double] = [38.89, 51.91, 38.89, 58.27]

        // Lead trumpet unison stack (tight detune + octave below for brass body)
        let leadDetunes: [Double] = [-0.0035, -0.0012, 0.0, 0.0012, 0.0035]
        let leadPans: [Double]    = [-0.45,   -0.20,   0.0, 0.20,   0.45]

        // Wide backing pad/stab supersaw detunes
        let padDetunes: [Double]  = [-0.014, 0.0, 0.014]
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

        // Filter states
        var leadLpL: Double = 0.0, leadBpL: Double = 0.0
        var leadLpR: Double = 0.0, leadBpR: Double = 0.0
        var padLpL: Double = 0.0,  padLpR: Double = 0.0
        var bassLp: Double = 0.0
        var hatLp: Double = 0.0
        var peak: Float = 0.0

        for frame in 0..<Int(totalFrames) {
            let time = Double(frame) / sampleRate
            // stepPos is negative during the 2-step pickup, 0.0 at Bar 1 Beat 1
            let stepPos = (time / sixteenth) - pickupSteps

            // 1. HIGH MELODIC TRUMPET HOOK ("ba-dat-dat-dat-dat-DAHHH-dahh")
            var leadL: Double = 0.0
            var leadR: Double = 0.0
            var leadFilterEnv: Double = 0.15

            if let note = leadMelody.first(where: {
                stepPos >= $0.step && stepPos < $0.step + $0.gateSteps
            }) {
                let elapsed = (stepPos - note.step) * sixteenth
                let dur = note.gateSteps * sixteenth
                let prog = elapsed / dur

                // Ultra-snappy 2ms trumpet tongue attack + crisp staccato cut
                let attack = min(1.0, elapsed / 0.002)
                let decay = 0.78 + 0.22 * exp(-elapsed / 0.04)
                let release = min(1.0, (1.0 - prog) / 0.16)
                let ampEnv = attack * decay * release * note.accent

                // Quick brass lip-scoop on attack + subtle vibrato on held "DAHHH" notes
                let scoop = 1.0 - 0.018 * exp(-elapsed / 0.006)
                let vibrato = elapsed > 0.12 ? (1.0 + 0.003 * sin(2.0 * .pi * 6.0 * elapsed)) : 1.0
                let baseFreq = note.freq * scoop * vibrato
                leadFilterEnv = (0.35 + 0.65 * exp(-elapsed / 0.065)) * note.accent

                for vIdx in 0..<5 {
                    let fMain = baseFreq * (1.0 + leadDetunes[vIdx])
                    let dtMain = fMain / sampleRate
                    leadPhases[vIdx] += dtMain
                    if leadPhases[vIdx] >= 1.0 { leadPhases[vIdx] -= 1.0 }

                    // Sub-octave layer (0.5x) gives the high C6/Bb5 trumpet real horn chest
                    let dtSub = dtMain * 0.5
                    leadPhases[vIdx + 5] += dtSub
                    if leadPhases[vIdx + 5] >= 1.0 { leadPhases[vIdx + 5] -= 1.0 }

                    let sawMain = bandlimitedSaw(phase: leadPhases[vIdx], dt: dtMain)
                    let pulsePhase = (leadPhases[vIdx] + 0.38).truncatingRemainder(dividingBy: 1.0)
                    let pulseMain = sawMain - bandlimitedSaw(phase: pulsePhase, dt: dtMain)
                    let subSaw = bandlimitedSaw(phase: leadPhases[vIdx + 5], dt: dtSub)

                    let voice = (0.55 * sawMain + 0.45 * pulseMain) + 0.40 * subSaw
                    let pan = leadPans[vIdx]
                    leadL += voice * 0.5 * (1.0 - pan)
                    leadR += voice * 0.5 * (1.0 + pan)
                }
                leadL *= ampEnv * 0.19
                leadR *= ampEnv * 0.19
            } else {
                leadBpL *= 0.98
                leadBpR *= 0.98
            }

            // Bright resonant brass filter for the lead (sweeps up to 6.5 kHz so it cuts through)
            let leadCutoff = min(6500.0, 1400.0 + 3800.0 * leadFilterEnv)
            let fLead = min(0.82, 2.0 * sin(.pi * leadCutoff / sampleRate))
            let qLead = 0.50
            let hpL = leadL - leadLpL - qLead * leadBpL
            leadBpL += fLead * hpL
            leadLpL += fLead * leadBpL
            let hpR = leadR - leadLpR - qLead * leadBpR
            leadBpR += fLead * hpR
            leadLpR += fLead * leadBpR

            let trumpetOutL = leadLpL * 0.70 + leadBpL * 0.65
            let trumpetOutR = leadLpR * 0.70 + leadBpR * 0.65

            // 2. RHYTHM SECTION & BACKING CHORDS (engaged once stepPos >= 0)
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

                // Backing off-beat Eurodance chord stabs
                let chord = barChords[barIndex]
                let stabGate = posInBeat >= 0.50 && posInBeat < 0.92
                let stabEnv = stabGate ? exp(-(posInBeat - 0.50) * beatDur / 0.09) : 0.0
                if stabEnv > 0.001 {
                    for (nIdx, cFreq) in chord.enumerated() {
                        for vIdx in 0..<3 {
                            let idx = nIdx * 3 + vIdx
                            let dt = (cFreq * (1.0 + padDetunes[vIdx])) / sampleRate
                            padPhases[idx] += dt
                            if padPhases[idx] >= 1.0 { padPhases[idx] -= 1.0 }
                            let s = bandlimitedSaw(phase: padPhases[idx], dt: dt) * stabEnv * 0.065
                            backingL += s * 0.5 * (1.0 - padPans[vIdx])
                            backingR += s * 0.5 * (1.0 + padPans[vIdx])
                        }
                    }
                }
                padLpL += 0.25 * (backingL - padLpL)
                padLpR += 0.25 * (backingR - padLpR)

                // 909 Four-on-the-Floor Kick
                if kickTime < 0.18 {
                    let kickFreq = 48.0 + 125.0 * exp(-kickTime / 0.019)
                    kickPhase += kickFreq / sampleRate
                    if kickPhase >= 1.0 { kickPhase -= 1.0 }
                    let kickEnv = min(1.0, kickTime / 0.0015) * exp(-kickTime / 0.062)
                    kickSample = sin(2.0 * .pi * kickPhase) * kickEnv * 0.56
                } else {
                    kickPhase = 0.0
                }

                // Off-beat Octave Bass
                if posInBeat >= 0.50 && posInBeat < 0.95 {
                    let bassTime = (posInBeat - 0.50) * beatDur
                    let bassFreq = bassBarRoots[barIndex] * 2.0
                    let dt = bassFreq / sampleRate
                    bassPhase += dt
                    if bassPhase >= 1.0 { bassPhase -= 1.0 }
                    let rawBass = bandlimitedSaw(phase: bassPhase, dt: dt)
                    let bassEnv = min(1.0, bassTime / 0.004) * exp(-bassTime / 0.085)
                    bassLp += 0.24 * (rawBass - bassLp)
                    bassSample = bassLp * bassEnv * 0.40
                } else {
                    bassPhase = 0.0
                }

                // 909 Off-Beat Open Hi-Hat
                if posInBeat >= 0.50 && posInBeat < 0.88 {
                    let hatTime = (posInBeat - 0.50) * beatDur
                    let noise = whiteNoise()
                    hatLp += 0.35 * (noise - hatLp)
                    let hpNoise = noise - hatLp
                    let hatEnv = min(1.0, hatTime / 0.002) * exp(-hatTime / 0.055)
                    hatSample = hpNoise * hatEnv * 0.14
                }
            }

            let globalProgress = Double(frame) / Double(totalFrames)
            let masterFade = globalProgress > 0.93 ? pow((1.0 - globalProgress) / 0.07, 1.3) : 1.0

            // Mix the high trumpet lead on top of the backing stabs + 909 rhythm section
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
