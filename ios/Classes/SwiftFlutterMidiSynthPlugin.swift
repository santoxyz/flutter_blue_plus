import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import Foundation

@objcMembers public class SwiftFlutterMidiSynthPlugin: NSObject, FlutterPlugin {

    var parent: FlutterBluePlusPlugin?
    var synths: [Int:SoftSynth?] = [:]
    var sequencers: [Int:[Int:Sequencer]] = [:]
    var recorders = [String : Int]() //[mac : channel]
    var expressions = [String : Bool]() //[mac : expression]
    typealias instrumentInfos = (channel : Int, instrument: Int , bank: Int , mac:String?)
    var instruments = [Int:instrumentInfos]() //[channel, instrumentInfos
    var xpressionsMap = [Int:[UInt32]]() //channel, expressions
    let NOTE_ON = 0x90
    let NOTE_OFF = 0x80
    var lastNoteOnOff = 0x80
    var allowedInstrumentsIndexes: [Int] = []
    var allowedInstrumentsExpressions: [Bool] = []

    var lastNoteForChannel: [UInt32] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    var movingWindowForChannel: [[Int]] = [[],[],[],[],[],[],[],[],[],[],[],[],[],[],[],[]]
    let movingWindowDepth = 1
    var bendForChannel: [Int] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
    var targetBendForChannel: [Int] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
    typealias specialModeInfos = (channel : UInt32, mode: UInt32, notes:[Int], continuous: Bool , time: UInt32, controller: UInt32, muted: Bool)
    var specialModes = [Int:specialModeInfos]() //[channel, specialModeInfos]
    var backgroundBendTaskIsRunning: Bool = false

    let wand_velocity = 70
    var classroom: Bool = false

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "FlutterMidiSynthPlugin", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterMidiSynthPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initSynth":
            let args = call.arguments as? Dictionary<String, Any>
            let instrument = args?["instrument"] as! Int
            let synthIdx = args?["synthIdx"] as! Int
            classroom = args?["classroom"] as! Bool
            self.initSynth(synthIdx: synthIdx, instrument: instrument);
        case "setInstrument":
            let args = call.arguments as? Dictionary<String, Any>
            let synthIdx = args?["synthIdx"] as! Int
            let instrument = args?["instrument"] as! Int
            let channel = args?["channel"] as! Int
            let bank = args?["bank"] as! Int
            let mac = args?["mac"] as! String
            let expression = args?["expression"] as! Bool
            self.setInstrument(synthIdx: synthIdx, instrument: instrument, channel: channel, bank: bank, mac: mac, expression: expression)
        case "noteOn":
            let args = call.arguments as? Dictionary<String, Any>
            let synthIdx = args?["synthIdx"] as! Int
            let channel = args?["channel"] as? Int
            let note = args?["note"]  as? Int
            let velocity = args?["velocity"]  as? Int
            self.noteOn(synthIdx: synthIdx, channel: channel ?? 0, note: note ?? 60, velocity: velocity ?? 255)
        case "noteOff":
            let args = call.arguments as? Dictionary<String, Any>
            let synthIdx = args?["synthIdx"] as! Int
            let channel = args?["channel"] as? Int
            let note = args?["note"]  as? Int
            let velocity = args?["velocity"]  as? Int
            self.noteOff(synthIdx: synthIdx, channel: channel ?? 0, note: note ?? 60, velocity: velocity ?? 255)
        case "midiEvent":
            let args = call.arguments as? Dictionary<String, Any>
            let synthIdx = args?["synthIdx"] as! Int
            let command = args?["command"] as! UInt32
            let d1 = args?["d1"] as! UInt32
            var d2 = args?["d2"] as! UInt32
            
            self.midiEvent(synthIdx: synthIdx, command: command, d1: d1, d2: d2)
            
        case "setReverb":
            let args = call.arguments as? Dictionary<String, Any>
            let synthIdx = args?["synthIdx"] as! Int
            let amount = args?["amount"] as! NSNumber
            self.setReverb(synthIdx: synthIdx, dryWet: Float(amount.doubleValue))
            
        case "setDelay":
            let args = call.arguments as? Dictionary<String, Any>
            let synthIdx = args?["synthIdx"] as! Int
            let amount = args?["amount"] as! NSNumber
            self.setDelay(synthIdx: synthIdx, dryWet: Float(amount.doubleValue))
            
        case "initAudioSession":
            let param = call.arguments as! Int32
            //nothing to do, using AVAudioSession.interruptionNotification
            
        case "setAllowedInstrumentsIndexes":
            let args = call.arguments as? Dictionary<String, Any>
            allowedInstrumentsIndexes = args?["instruments"] as! [Int]
            allowedInstrumentsExpressions = args?["expressions"] as! [Bool]
            
        case "setSpecialMode":
            let args = call.arguments as? Dictionary<String, Any>
            let channel = args?["channel"] as! UInt32
            let mode = args?["mode"] as! UInt32
            let notes = args?["notes"] as! [Int]
            let continuous = args?["continuous"] as! Bool
            let time = args?["time"] as! UInt32
            let controller = args?["controller"] as! UInt32
            let muted = args?["muted"] as! Bool
            self.setSpecialMode(channel:channel, mode:mode, notes:notes, continuous:continuous, time:time, controller:controller, muted:muted)
            
        default:
            print ("unknown method \(call.method)" )
        }
    }
    

    private func scaleXpression(min: Int, max: Int, value: UInt32) -> UInt32 {
        let scaled: Double = Double(min) + Double((max-min)*Int(value))/127.0
        //print("scaleXpression min=\(min) max=\(max) v=\(value) scaled=\(scaled)" )
        return UInt32(scaled);
    }
    
    private func scaleRotation(fromMin: Int, fromMax: Int, toMin: Int, toMax: Int, value:UInt32) -> UInt32 {
        let x = Int(value) > fromMin ? Int(value) - fromMin : 0
        let scaled: Double = Double(toMin) + Double(toMax-toMin)*Double(x)/Double(fromMax-fromMin)
        //print("scaleRotation fromMin=\(fromMin) fromMax=\(fromMax) toMin=\(toMin) toMax=\(toMax) v=\(value) scaled=\(scaled)" )
        return UInt32(scaled) > toMax ? UInt32(toMax) : UInt32(scaled)
    }

    private func scaleInclination(fromMin: Int, fromMax: Int, toMin: Int, toMax: Int, value:UInt32) -> Int {
        if(value < fromMin){
            return toMin
        }
        
        let scaled: Double = Double(toMin) + Double(toMax-toMin)*Double(Int(value)-fromMin)/Double(fromMax-fromMin)
        //print("scaleInclination fromMin=\(fromMin) fromMax=\(fromMax) toMin=\(toMin) toMax=\(toMax) v=\(value) scaled=\(scaled) \(noteToString(note:UInt32(scaled)))" )
        
        return Int(scaled)
    }
    
    private func xpressionAvg(ch: Int, value: UInt32) -> UInt32{
        var s: String = "";
        var avg: UInt32 = 0
        var xpressions = xpressionsMap[ch]
        if(xpressions == nil){
            xpressions = []
        }
        xpressions?.append(value)
        xpressions = xpressions?.suffix(5)
        xpressionsMap[ch] = xpressions
        for v in xpressions! {
            avg += v
            s += " \(v)"
        }
        let r = avg / UInt32(xpressionsMap[ch]!.count)
        s += " => r \(r)"
        print (s)
        return r
    }
    
    @available(iOS 10.0, *)
    private func setSpeakersAsDefaultAudioOutput() {
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSession.Category.playback /*playAndRecord*/, mode: .default, options: AVAudioSession.CategoryOptions.defaultToSpeaker)
        } catch {
            print ("Error in setSpeakersAsDefaultAudioOutput");
        }
    }
    
    func setupNotifications() {
        // Get the default notification center instance.
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleInterruption),
                       name: AVAudioSession.interruptionNotification,
                       object: nil)
    }
    
    @objc func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        // Switch over the interruption type.
        switch type {
        
        case .began:
            print("deactivating audio session")
            
            do {try  AVAudioSession.sharedInstance().setActive(false) } catch { print ("can't deactivate audiosession")}
            for synth in synths {
                AUGraphStop(synth.value!.audioGraph!)
            }
        // An interruption began. Update the UI as needed.
        
        case .ended:
            // An interruption ended. Resume playback, if appropriate.
            
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                print("reactivating audio session")
                for synth in synths {
                    AUGraphStart(synth.value!.audioGraph!)
                }
            } else {
                // Interruption ended. Playback should not resume.
            }
            
        default: ()
        }
    }
    
    //TODO: add soundfont argument
    public func initSynth(synthIdx: Int, instrument: Int){
        setupNotifications()
        synths[synthIdx] = SoftSynth()
        setInstrument(synthIdx: synthIdx, instrument: instrument)
        
        
        if #available(iOS 10.0, *) {
            setSpeakersAsDefaultAudioOutput()
        } else {
            // Fallback on earlier versions
            print ("setSpeakersAsDefaultAudioOutput is available only from iOS 10");
        }
        
        /*load voices (in background)*/
        //DispatchQueue.global(qos: .background).async {
            self.synths[synthIdx]?!.loadSoundFont()
            self.synths[synthIdx]?!.loadPatch(patchNo: instrument)
            DispatchQueue.main.async {
                print ("background loading of voices completed." )
            }
        //}
    }
    
    private func getSequencer(synthIdx: Int, channel: Int) -> Sequencer{
        if (sequencers[synthIdx]?[channel] == nil){
            print("creating sequencer for channel \(channel) synthIdx \(synthIdx)")
            var v: [Int:Sequencer] = sequencers[synthIdx] ?? [:]
            v[channel] = Sequencer(channel: channel)
            sequencers[synthIdx] = v
        }
        return (sequencers[synthIdx]?[channel]!)!
    }
    
    public func setInstrument(synthIdx: Int, idx: Int, channel: Int , mac: String){
        if(allowedInstrumentsIndexes.contains(idx)){
            let pos = allowedInstrumentsIndexes.firstIndex(of: idx)!
            let expression = allowedInstrumentsExpressions[pos]
            setInstrument(synthIdx: synthIdx, instrument: idx, channel: channel, bank: 0, mac: mac, expression: expression)
        } else {
            print(" error! Instrument \(idx) not found in allowedInstruments= \(allowedInstrumentsIndexes)")
        }
    }
    
    private func setInstrument(synthIdx: Int, instrument: Int, channel: Int = 0, bank: Int = 0, mac: String? = nil, expression: Bool? = false){
        
        print ("setInstrument synthIdx=\(synthIdx) instrument=\(instrument) channel=\(channel) bank=\(bank) mac=\(mac) expression=\(expression)")
        if(!allowedInstrumentsIndexes.contains(instrument) && bank == 0){
            print(" error! Instrument \(instrument) not found in \(allowedInstrumentsIndexes)")
            return
        }

        if(mac != nil){
            recorders[mac!] = channel
            expressions[mac!] = expression
        }

        let specialModeInfos = specialModes[Int(channel)]

        let infos : instrumentInfos = ( channel: channel, instrument: instrument, bank: bank, mac: mac)
        instruments[channel] = infos
        
        synths[synthIdx]?!.loadPatch(patchNo: instrument, channel: channel, bank: bank)

        getSequencer(synthIdx: synthIdx, channel: channel).patch = UInt32(instrument)
        
        if(mac != nil){
            midiEventWithMac(synthIdx: synthIdx, command: 0xB0 + UInt32(channel), d1: 11, d2: 10, mac: mac!) //invio un expression fittizio
        } else {
            midiEvent(synthIdx: synthIdx, command: 0xB0 + UInt32(channel), d1: 11, d2: 10);
        }
        
        if (specialModeInfos?.mode == 1 /*WAND*/ && specialModeInfos?.continuous == true /*continuous*/){
            wand_noteOn(synthIdx: synthIdx, channel: channel, note: Int(lastNoteForChannel[channel]), velocity: wand_velocity)
        }
    }
    
    public func noteOnWithMac(synthIdx: Int, channel: Int, note: Int, velocity: Int, mac: String ){
        var vel = velocity
        let ch = recorders[mac] ?? channel
        let expression = expressions[mac] ?? false
        //if (!expression){
        //    vel = Int(xpressionsMap[channel]?.last ?? UInt32(velocity))
        //}
        //print ("noteOnWithMac synthIdx=\(synthIdx) ch=\(ch) note=\(note) velocity=\(velocity) expression=\(expression) mac=\(mac)")
        noteOn(synthIdx: synthIdx, channel: ch, note: note, velocity: vel)
    }
    
    public func noteOffWithMac(synthIdx: Int, channel: Int, note: Int, velocity: Int, mac: String){
        //print ("noteOffWithMac \(channel) \(note) \(velocity) \(mac)")
        let ch = recorders[mac] ?? channel
        noteOff(synthIdx: synthIdx, channel: ch, note: note, velocity: velocity)
    }
    
    public func midiEventWithMac(synthIdx: Int, command: UInt32, d1: UInt32, d2: UInt32, mac: String){

        var _cmd = command & 0xf0
        var _d2 = d2
        let ch = recorders[mac] ?? 0
        let expression = expressions[mac] ?? false
        if(d1==11 && !expression){
            print ("expression disabled for this instrument.")
            _d2 = 80
        }
        
        midiEvent(synthIdx: synthIdx, command: _cmd+UInt32(ch), d1: d1, d2: _d2)
    }

    private func wand_noteOff(synthIdx: Int, channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        var _channel = channel
        let sequencer = getSequencer(synthIdx: synthIdx, channel: _channel)
        let _velocity = /*lastNoteOnOff == NOTE_OFF ? 0 :*/ velocity
        synths[synthIdx]?!.playNoteOff(channel: _channel, note: UInt8(note), midiVelocity: _velocity, sequencer: sequencer)
        sequencer.noteOff(note: UInt8(note))
    }
    
    private func wand_noteOn(synthIdx: Int, channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        var _channel = channel
        let sequencer = getSequencer(synthIdx: synthIdx, channel: _channel)
        let _velocity = /*lastNoteOnOff == NOTE_OFF ? 0 :*/ velocity
        synths[synthIdx]?!.playNoteOn(channel: _channel, note: UInt8(note), midiVelocity: _velocity, sequencer: sequencer)
        sequencer.noteOn(note: UInt8(note))
        //let now = (Int64)(NSDate().timeIntervalSince1970*1000)
        //print("\(now) SwiftFlutterMidiSyntPlugin.swift noteOn \(_channel)  \(note) \(velocity) ")
    }

    public func noteOn(synthIdx: Int, channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        let sequencer = getSequencer(synthIdx: synthIdx, channel: channel)
        var _channel = channel
        var _velocity = /*lastNoteOnOff == NOTE_OFF ? 0 :*/ velocity

        if(specialModes[_channel]?.mode == 1){
          _channel += 1
          _velocity = wand_velocity - 10
        }

        lastNoteOnOff = NOTE_ON
        synths[synthIdx]?!.playNoteOn(channel: channel, note: UInt8(note), midiVelocity: _velocity, sequencer: sequencer)
        sequencer.noteOn(note: UInt8(note))

        let now = (Int64)(NSDate().timeIntervalSince1970*1000)
        //print("\(now) SwiftFlutterMidiSynthPlugin.swift noteOn \(_channel)  \(note) \(_velocity) ")
    }
    
    public func noteOff(synthIdx: Int, channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        var _channel = channel

        if(specialModes[_channel]?.mode == 1){
          _channel += 1
        }

        xpressionsMap[_channel] = []
        lastNoteOnOff = NOTE_OFF

        let sequencer = getSequencer(synthIdx: synthIdx, channel: channel)
        synths[synthIdx]?!.playNoteOff(channel: channel, note: UInt8(note), midiVelocity: velocity, sequencer: sequencer)
        sequencer.noteOff(note: UInt8(note))
        //let now = (Int64)(NSDate().timeIntervalSince1970*1000)
        //print("\(now) SwiftFlutterMidiSyntPlugin.swift noteOff \(_channel)  \(note) \(velocity) ")
    }

    public func selectNote(d2: UInt32, ch: UInt32, notes: [Int]) -> UInt32 {

        movingWindowForChannel[Int(ch)].append(Int(d2))
        movingWindowForChannel[Int(ch)] = Array(movingWindowForChannel[Int(ch)].suffix(movingWindowDepth))
        let n = movingWindowForChannel[Int(ch)].reduce(0, +) / movingWindowForChannel[Int(ch)].count
        let closest = notes.enumerated().min( by: { abs($0.1 - Int(n)) < abs($1.1 - Int(n)) } )!
        //print("d2=\(d2) -> n=\(n) notes=\(notes) => closest=\(closest)")
        return UInt32(closest.element)
    }

    private func noteToString(note:UInt32) -> String{
        let o = note/12 
        var nnames: [String] = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        let name = nnames[Int(note % 12)]
        return "\(name)\(o)"
    }

    private func backgroundBendTask(synthIdx: Int) {
        print ("starting backgroundBendTask()")
        var wait = true
        while(backgroundBendTaskIsRunning){
            for ch in 0...bendForChannel.count-1 {
              if (bendForChannel[ch] != targetBendForChannel[ch]){
                if(Int(specialModes[ch]!.time) == 0 || bendForChannel[ch] == 0){
                    bendForChannel[ch] = targetBendForChannel[ch]
                }
                let pb_d1 = UInt32(bendForChannel[ch]) & 0x7f
                let pb_d2 = (UInt32(bendForChannel[ch]) >> 7) & 0x7f
                synths[synthIdx]?!.midiEvent(cmd: 0xE0 | UInt32(ch), d1: UInt32(pb_d1), d2: UInt32(pb_d2))
                if(bendForChannel[ch] < targetBendForChannel[ch]){
                    bendForChannel[ch] = bendForChannel[ch] + 1
                    wait = false
                } else if (bendForChannel[ch] > targetBendForChannel[ch]) {
                    bendForChannel[ch] = bendForChannel[ch] - 1
                    wait = false
                }
                Thread.sleep(forTimeInterval: 0.000000100 * Double(Int(specialModes[ch]!.time)))
                //print("ch \(ch) bend \(bendForChannel[ch]) target \(targetBendForChannel[ch])")
              }
            }
            if(wait){
                Thread.sleep(forTimeInterval: 0.001000000)
            }
        }
        
        print("backgroundBendTask stopped.");
    }

    public func midiEvent(synthIdx: Int, command: UInt32, d1: UInt32, d2: UInt32){
        //print("SwiftFlutterMidiSyntPlugin.swift midiEvent synthIdx=\(synthIdx) command=\(command)  d1=\(d1) d2=\(d2) (RAW) ")

        
        var _d1 = d1
        var _d2 = d2
        var _command = command
        var ch = Int(command & 0xf)
        let infos = specialModes[ch] //(channel : Int, mode: Int, notes:[Int], continuous: Bool , time: Int, controller: Int, muted: Bool)
        
        if (infos?.mode == 1){ //WAND MODE
            //print("SwiftFlutterMidiSyntPlugin.swift midiEvent cmd \(command)  ch \(ch) d1 \(d1) d2 \(d2) infos \(infos) (RAW) ")
            //_command = (command & 0xf0) | UInt32(ch)
            if(_command & 0xf0 == 0xb0){
                switch d1 {
                case 52: /*rotation*/
                    let uscaled = scaleRotation(fromMin: 0, fromMax: Int(127*0.6), toMin: 0, toMax: Int(127*0.3), value: _d2)
                    _d1 = 11 //Map rotation to volume via expression
                    //_d1 = 7 //Map rotation to volume via volume
                    //print("SwiftFlutterMidiSynthPlugin.swift Rotation: uscaled \(uscaled) d2 \(_d2) _d1 \(_d1)")
                    synths[synthIdx]?!.midiEvent(cmd: _command, d1: _d1, d2: uscaled)

                case 1: /*inclination*/
                    let notes = infos?.notes ?? []
                    var note = 0

                    //use pitch bend to reach next note
                    var min_note = notes.min() ?? 0
                    var max_note = notes.max() ?? 127
                    var scaled = 0
                    // se è continuous uso direttamente il valore v ricevuto
                    // per fare un bend all'interno del noteSpan settato con il CC 6
                    var bend = 0
                    if ((infos?.continuous)!) { //continuous
                        //Pitch bend
                        scaled = scaleInclination(fromMin: 0, fromMax: 115, toMin: 0, toMax: 127, value: d2)
                        let uscaled = UInt32(scaled)
                        note = Int((max_note + min_note) / 2)
                        bend = Int(uscaled*0x4000/127)
                        //print("SwiftFlutterMidiSynthPlugin.swift Continuous mode: d2 \(d2) uscaled \(uscaled) => note \(note) (\(noteToString(note:UInt32(note))) lastNoteForChannel[\(ch)] \(lastNoteForChannel[ch]) => bend \(bend)")

                    } else {
                        // Se è !continuous devo calcolare la distanza dalle note più vicine
                        // e raggiungere il target con un bend manuale
                        scaled = scaleInclination(fromMin: 0, fromMax: 115, toMin: min_note, toMax: max_note, value: d2)
                        note = Int(selectNote(d2:UInt32(scaled), ch:UInt32(ch), notes:notes))
                        let distance = note - Int(lastNoteForChannel[ch])
                        let span = max_note - min_note //semitones span, including upper octave rootnote
                        let pps = 16384.0/Double(span)
                        bend = Int(Double(distance)*pps) + 8192
                        //print("SwiftFlutterMidiSynthPlugin.swift Quantized mode: note \(note) (\(noteToString(note:UInt32(note))) centralNote[\(ch)] \(lastNoteForChannel[ch]) distance \(distance) pps \(pps) => bend \(bend) (d=\(bend-8196))")
                    }

                    if (bend >= 16384) {bend = 16384-1}
                    if (bend <= 0) {bend = 0}

                    if #available(iOS 13.0.0, *) {
                        targetBendForChannel[ch] = bend
                    } else {
                        let pb_d1 = UInt32(bend) & 0x7f
                        let pb_d2 = (UInt32(bend) >> 7) & 0x7f
                        synths[synthIdx]?!.midiEvent(cmd: 0xE0 | UInt32(ch), d1: UInt32(pb_d1), d2: UInt32(pb_d2))
                    }
                    //print("SwiftFlutterMidiSynthPlugin.swift pb_d1 \(pb_d1) pb_d2 \(pb_d2)")

                    if(lastNoteForChannel[ch] != note){

                        parent?.sendMessage("WandNote", withBody: Data(bytes:&note, count:1) ) //Send current note to UI
                        if (!(infos?.3)! && lastNoteForChannel[ch] != 0) {
                            //nothing to do
                        } else {
                            print("SwiftFlutterMidiSynthPlugin.swift note \(note) != \(lastNoteForChannel[ch]) -> ")
                            lastNoteForChannel[ch] = UInt32( (max_note + min_note) / 2)
                            print("SwiftFlutterMidiSynthPlugin.swift    -> sending new noteON for \(lastNoteForChannel[ch])")
                            wand_noteOff(synthIdx: synthIdx, channel:ch, note:0, velocity:0)
                            wand_noteOn(synthIdx: synthIdx, channel:ch, note:Int(lastNoteForChannel[ch]), velocity:wand_velocity)
                        }
                    }
                case 5: //Portamento Time
                    //synth!.midiEvent(cmd: _command, d1: _d1, d2: _d2)
                    specialModes[ch]?.time = _d2


                default:
                    break
                }
            }

        } else {

            //print("SwiftFlutterMidiSyntPlugin.swift NORMAL MODE")
            if(command & 0xf0 == 0xb0 && d1 == 11) {
                //print("SwiftFlutterMidiSyntPlugin.swift midiEvent \(command)  \(d1) \(d2) (RAW) ")
                //_d2 = xpressionAvg(ch: Int(command & 0xf), value: _d2)
                _d2 = scaleXpression(min:25, max:110, value: _d2)
                //_d1 = 7
            }
 
            synths[synthIdx]?!.midiEvent(cmd: command, d1: _d1, d2: _d2);
        }
    }
    
    public func setParent(arg: FlutterBluePlusPlugin){
        parent = arg
    }
    
    public func setReverb(synthIdx: Int, dryWet: Float){
        synths[synthIdx]?!.setReverb(dryWet: dryWet)
    }
    
    public func setDelay(synthIdx: Int, dryWet: Float){
        synths[synthIdx]?!.setDelay(dryWet: dryWet)
    }

    public func setSpecialMode(channel: UInt32, mode: UInt32, notes: [Int], continuous: Bool, time: UInt32, controller: UInt32, muted: Bool){
        let synthIdx: Int = 0;
        let infos : specialModeInfos = (channel: channel, mode: mode, notes: notes, continuous: continuous, time: time, controller: controller, muted: muted)
        let prev_mode = specialModes[Int(channel)]?.1 //mode
        let prev_continuous = specialModes[Int(channel)]?.3 //continuous

        if(prev_mode != mode || !continuous){
            lastNoteForChannel[Int(channel)] = 0;
        }

        synths[synthIdx]?!.midiEvent(cmd: 0xB0 | channel, d1: 123, d2: 0) //ALL NOTES OFF

        specialModes[Int(channel)] = infos

        if(/*continuous &&*/ mode == 1){
            if(backgroundBendTaskIsRunning == false){
                do {
                    try DispatchQueue.global(qos: .background).async {
                        self.backgroundBendTaskIsRunning = true
                        self.backgroundBendTask(synthIdx: synthIdx);
                    }
                } catch {
                    print ("Error in DispatchQueue trying to start backgroundBendTask()");
                }
            }
            
            let span = notes.max()! - notes.min()! //semitones span, notes includes upper octave rootnote
            let pps = 16384/span
            print("setSpecialMode mode \(mode) on channel \(channel) - notes \(notes) span \(span) (\(pps) points/semitone) continuous \(continuous) time \(time) controller \(controller) muted \(muted)")

            synths[synthIdx]?!.midiEvent(cmd: 0xB0 | channel, d1: 7, d2: 0) //tolgo volume

            //Setup Pitch Bend Range
            //CC101 set value 0
            //CC100 set value 0
            //CC6 set value for pb range (eg 12 for 12 semitones up / down)
            synths[synthIdx]?!.midiEvent(cmd: 0xB0 | channel, d1: 101, d2: 0) //Set Pitch Bend Range RPN
            synths[synthIdx]?!.midiEvent(cmd: 0xB0 | channel, d1: 100, d2: 0) //Set Pitch Bend Range RPN
            synths[synthIdx]?!.midiEvent(cmd: 0xB0 | channel, d1: 6, d2: UInt32(span/2))  //Set Entry Value
            synths[synthIdx]?!.midiEvent(cmd: 0xB0 | channel, d1: 101, d2: 127) //RPN Null
            synths[synthIdx]?!.midiEvent(cmd: 0xB0 | channel, d1: 100, d2: 127) //RPN Null

            // Enable/Disable portamento - mode 1 is WAND Mode
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 65, d2: mode == 1 ? 127 : 0)
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 5, d2: time) //Portamento time (CC5)
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 84, d2: controller /*note*/ /*infos?.5*/ /*?? 0*/) //Portamento Controller (CC84) TEST = 64

            if (continuous || prev_continuous != continuous){
                //Causes audio glitch !
                wand_noteOn(synthIdx: synthIdx, channel:Int(channel), note: Int(lastNoteForChannel[Int(channel)]), velocity: wand_velocity)
            } else if (!continuous) {
                wand_noteOff(synthIdx: synthIdx, channel:Int(channel), note:0, velocity:0)
            }
            synths[synthIdx]?!.midiEvent(cmd: 0xB0 | channel, d1: 7, d2: muted ? 0 : 127)

        } else {
            // Enable/Disable portamento - mode 1 is WAND Mode
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 65, d2: mode == 1 ? 127 : 0)
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 5, d2: time) //Portamento time (CC5)
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 84, d2: controller /*note*/ /*infos?.5*/ /*?? 0*/) //Portamento Controller (CC84) TEST = 64
            backgroundBendTaskIsRunning = false
        }
    }
    
    public func hasSpecialModeWAND(channel: UInt32) -> Bool {
        let infos = specialModes[Int(channel)]
        return infos?.1 == 1
    }
    
    public func hasClassRoom() -> Bool {
        return classroom
    }

}
