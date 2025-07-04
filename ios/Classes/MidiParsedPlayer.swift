//
//  MidiParsedPlayer.swift
//  Pods
//
//  Created by Luca Santini on 03/07/25.
//

import Foundation

// Represents one MIDI event as array of bytes
typealias MidiEvent = [UInt8]

// Tracks: tick → list of events
typealias Track = [Int: [MidiEvent]]

@objc class MidiParsedPlayer: NSObject {
    
    // MARK: - Properties
    
    private var synth: SoftSynth?
    
    private var totalTicks: Int = 0
    private var tickDuration: Int = 1000 // microseconds
    private var tickPerBeat: Int = 120
    private var beatsPerMeasure: Int = 4
    
    private var curTicks: Int = 0
    private var tempo: Double = 1.0
    
    private var playing = false
    private var prepared = false
    private var metronomeEnabled = false
    private var countInEnabled = false
    private var countInBeats = 0
    
    private var eventMask: UInt16 = 0xFFFF
    
    private var tracks: Track = [:]
    private var metronome: Track = [:]
    
    private var tickTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.yourcompany.midi.tickTimer")
    
    var onEvent: ((Int) -> Void)?
    var onDone: (() -> Void)?
    
    private let metronomeChannel = 9
    
    private let lock = NSLock()
    
    // MARK: - Public API
    
    func setSynth(_ s: SoftSynth) {
        synth = s
    }
    
    func prepare(totalTicks: Int, tickDurationMicros: Int, ticksPerBeat: Int, beatsPerMeasure: Int) {
        lock.lock()
        defer { lock.unlock() }
        
        print("prepare ticks \(totalTicks) duration \(tickDurationMicros)")
        self.totalTicks = totalTicks
        self.tickDuration = tickDurationMicros
        self.tickPerBeat = ticksPerBeat
        self.beatsPerMeasure = beatsPerMeasure
        self.curTicks = 0
        self.tempo = 1.0
        self.metronomeEnabled = false
        self.countInEnabled = false
        self.tracks.removeAll()
        prepareMetronome()
        self.prepared = true
    }
    
    func prepareEvents(events: [[UInt8]], totalTicks: Int) {
        lock.lock()
        defer { lock.unlock() }
        tracks[totalTicks] = events
    }
    
    func play() {
        guard prepared, !playing else { return }
        
        playing = true
        
        if tickTimer != nil {
            tickTimer?.cancel()
            tickTimer = nil
        }
        
        startCountInIfNeeded {
            self.startTickLoop()
        }
    }
    
    func stop() {
        playing = false
        tickTimer?.cancel()
        tickTimer = nil
        curTicks = 0
        allNotesOff()
    }
    
    func pause() {
        playing = false
        tickTimer?.cancel()
        tickTimer = nil
        allNotesOff()
    }
    
    func seek(to tick: Int) {
        lock.lock()
        defer { lock.unlock() }
        curTicks = tick
        allNotesOff()
        print("Seek → \(curTicks)")
    }
    
    func setVolume(_ volume: Int) {
        guard let synth = synth else { return }
        
        for ch in 0..<16 {
            let vol = ch == metronomeChannel ? volume + 10 : volume
            synth.midiEvent(cmd: 0xB0 | UInt32(ch), d1: 7, d2: UInt32(vol))
        }
    }
    
    func setTempo(_ tempoPercent: Int) {
        tempo = Double(tempoPercent) / 100.0
        print("Tempo → \(tempoPercent)")
    }
    
    func setReverb(_ reverb: Double) {
        guard let synth = synth else { return }
        
        for ch in 0..<16 {
            let value = Int(reverb * 1.27)
            synth.midiEvent(cmd: 0xB0 | UInt32(ch), d1: 91, d2: UInt32(value))
        }
    }
    
    func setMetronome(enabled: Bool) {
        metronomeEnabled = enabled
    }
    
    func setCountIn(enabled: Bool) {
        countInEnabled = enabled
    }
    
    func setTrackEnable(track: Int, enabled: Bool) {
        if track >= 0 && track < 16 {
            if enabled {
                eventMask |= (1 << track)
            } else {
                eventMask &= ~(1 << track)
            }
        }
    }
    
    // MARK: - Private
    
    private func startCountInIfNeeded(completion: @escaping () -> Void) {
        guard countInEnabled else {
            completion()
            return
        }
        
        countInBeats = beatsPerMeasure +
            ((curTicks % (beatsPerMeasure * tickPerBeat)) / tickPerBeat)
        
        var beat = 0
        
        func tickCountIn() {
            guard playing else { return }
            
            sendMetronomeNote(accented: (beat % beatsPerMeasure) == 0)
            
            beat += 1
            if beat >= countInBeats {
                completion()
            } else {
                let intervalUs = Int(Double(tickDuration * tickPerBeat) / tempo)
                let delayNs = UInt64(intervalUs) * 1000
                timerQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNs))) {
                    tickCountIn()
                }
            }
        }
        
        tickCountIn()
    }
    
    private func startTickLoop() {
        let intervalUs = Int(Double(tickDuration) / tempo)
        let intervalNs = UInt64(intervalUs) * 1000
        
        tickTimer = DispatchSource.makeTimerSource(queue: timerQueue)
        tickTimer?.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)), leeway: .nanoseconds(Int(intervalNs / 10)))
        
        tickTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            if !self.playing {
                self.tickTimer?.cancel()
                self.tickTimer = nil
                return
            }
            
            var events: [MidiEvent] = []
            self.lock.lock()
            events = self.getEventsAtCurrentTick()
            self.lock.unlock()
            
            if !events.isEmpty {
                self.executeEvents(events)
            }
            
            self.curTicks += 1
            
            if self.curTicks >= self.totalTicks {
                self.playing = false
                self.tickTimer?.cancel()
                self.tickTimer = nil
                self.onDone?()
            }
        }
        
        tickTimer?.resume()
    }
    
    private func getEventsAtCurrentTick() -> [MidiEvent] {
        var result: [MidiEvent] = []
        if let trackEvents = tracks[curTicks] {
            result.append(contentsOf: trackEvents)
        }
        if metronomeEnabled, let metronomeEvents = metronome[curTicks] {
            result.append(contentsOf: metronomeEvents)
        }
        return result
    }
    
    private func executeEvents(_ events: [MidiEvent]) {
        for ev in events {
            let ch = Int(ev[0] & 0x0F)
            if (eventMask & (1 << ch)) != 0 {
                synthEventSend(synthCh: ch, data: ev)
            }
        }
    }
    
    private func synthEventSend(synthCh: Int, data: MidiEvent) {
        guard let synth = synth else { return }
        
        let cmd = data[0] & 0xF0
        switch cmd {
        case 0x90:
            print("MidiParsedPlayer noteON ch \(synthCh) d1 \(data[1]) d2 \(data[2])")
            synth.midiEvent(cmd: 0x90 | UInt32(synthCh), d1: UInt32(data[1]), d2: UInt32(data[2]))
        case 0x80:
            synth.midiEvent(cmd: 0x80 | UInt32(synthCh), d1: UInt32(data[1]), d2: 0)
        case 0xB0:
            synth.midiEvent(cmd: 0xB0 | UInt32(synthCh), d1: UInt32(data[1]), d2: UInt32(data[2]))
        case 0xC0:
            synth.midiEvent(cmd: 0xC0 | UInt32(synthCh), d1: UInt32(data[1]), d2: 0)
        case 0xE0:
            synth.midiEvent(cmd: 0xE0 | UInt32(synthCh), d1: UInt32(data[1]), d2: 0)
        default:
            print("Not implemented \(data[0])")
        }
    }
    
    private func sendMetronomeNote(accented: Bool) {
        let velocity: UInt8 = accented ? 100 : 70
        let noteOn: MidiEvent = [0x90 | UInt8(metronomeChannel), 31, velocity]
        let noteOff: MidiEvent = [0x80 | UInt8(metronomeChannel), 31, 0]
        
        synthEventSend(synthCh: metronomeChannel, data: noteOn)
        
        let intervalUs = tickDuration / 2
        let delayNs = UInt64(intervalUs) * 1000
        
        timerQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(delayNs))) {
            self.synthEventSend(synthCh: self.metronomeChannel, data: noteOff)
        }
    }
    
    private func allNotesOff() {
        guard let synth = synth else { return }
        
        for ch in 0..<16 {
            synth.midiEvent(cmd: 0xB0 | UInt32(ch), d1: 123, d2: 0) // CC All Notes Off
        }
    }
    
    func currentTime() -> Int {
        return curTicks * tickDuration
    }

    func currentTicks() -> Int {
        return curTicks
    }

    func getStatus() -> Int {
        return playing ? 1 : 0
    }
    
    private func prepareMetronome() {
        metronome.removeAll()
        
        var tick = 0
        while tick < totalTicks {
            let accented = (tick % (beatsPerMeasure * tickPerBeat)) == 0
            let velocity: UInt8 = accented ? 100 : 70
            
            let noteOn: MidiEvent = [0x90 | UInt8(metronomeChannel), 31, velocity]
            let noteOff: MidiEvent = [0x80 | UInt8(metronomeChannel), 31, 0]
            
            if metronome[tick] == nil {
                metronome[tick] = []
            }
            metronome[tick]?.append(noteOn)
            
            if metronome[tick + 1] == nil {
                metronome[tick + 1] = []
            }
            metronome[tick + 1]?.append(noteOff)
            
            tick += tickPerBeat
        }
    }

    
}
