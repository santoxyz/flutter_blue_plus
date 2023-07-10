import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import Foundation

@objcMembers public class SwiftFlutterMidiSynthPlugin: NSObject, FlutterPlugin {
    
    var synth: SoftSynth?
    var sequencers: [Int:Sequencer] = [:]
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
    let movingWindowDepth = 5

    typealias specialModeInfos = (channel : UInt32, mode: UInt32, notes:[Int], continuous: Bool , time: UInt32, controller: UInt32)
    var specialModes = [Int:specialModeInfos]() //[channel, specialModeInfos]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "FlutterMidiSynthPlugin", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterMidiSynthPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initSynth":
            let i = call.arguments as! Int
            self.initSynth(instrument: i);
        case "setInstrument":
            let args = call.arguments as? Dictionary<String, Any>
            let instrument = args?["instrument"] as! Int
            let channel = args?["channel"] as! Int
            let bank = args?["bank"] as! Int
            let mac = args?["mac"] as! String
            let expression = args?["expression"] as! Bool
            self.setInstrument(instrument: instrument, channel: channel, bank: bank, mac: mac, expression: expression)
        case "noteOn":
            let args = call.arguments as? Dictionary<String, Any>
            let channel = args?["channel"] as? Int
            let note = args?["note"]  as? Int
            let velocity = args?["velocity"]  as? Int
            self.noteOn(channel: channel ?? 0, note: note ?? 60, velocity: velocity ?? 255)
        case "noteOff":
            let args = call.arguments as? Dictionary<String, Any>
            let channel = args?["channel"] as? Int
            let note = args?["note"]  as? Int
            let velocity = args?["velocity"]  as? Int
            self.noteOff(channel: channel ?? 0, note: note ?? 60, velocity: velocity ?? 255)
        case "midiEvent":
            let args = call.arguments as? Dictionary<String, Any>
            let command = args?["command"] as! UInt32
            let d1 = args?["d1"] as! UInt32
            var d2 = args?["d2"] as! UInt32
            
            self.midiEvent(command: command, d1: d1, d2: d2)
            
        case "setReverb":
            let amount = call.arguments as! NSNumber
            self.setReverb(dryWet: Float(amount.doubleValue))
            
        case "setDelay":
            let amount = call.arguments as! NSNumber
            self.setDelay(dryWet: Float(amount.doubleValue))
            
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

            self.setSpecialMode(channel:channel, mode:mode, notes:notes, continuous:continuous, time:time, controller:controller)
            
        default:
            print ("unknown method \(call.method)" )
        }
    }
    

    private func scaleXpression(min: Int, max: Int, value: UInt32) -> UInt32 {
        let scaled: Double = Double(min) + Double((max-min)*Int(value))/127.0
        print("scaleXpression min=\(min) max=\(max) v=\(value) scaled=\(scaled)" )
        return UInt32(scaled);
    }
    
    private func scaleRotation(fromMin: Int, fromMax: Int, toMin: Int, toMax: Int, value:UInt32) -> UInt32 {
        let x = Int(value) > fromMin ? Int(value) - fromMin : 0
        let scaled: Double = Double(toMin) + Double(fromMax-fromMin)*Double(x)/Double(toMax)
        //print("scaleRotation fromMin=\(fromMin) fromMax=\(fromMax) toMin=\(toMin) toMax=\(toMax) v=\(value) scaled=\(scaled)" )
        return UInt32(scaled)
    }

    private func scaleInclination(fromMin: Int, fromMax: Int, toMin: Int, toMax: Int, value:UInt32) -> Double {
        if(value < fromMin){
            return Double(toMin)
        }
        
        let scaled: Double = Double(toMin) + Double(toMax-toMin)*Double(Int(value)-fromMin)/Double(fromMax-fromMin)
        //print("scaleInclination fromMin=\(fromMin) fromMax=\(fromMax) toMin=\(toMin) toMax=\(toMax) v=\(value) scaled=\(scaled) \(noteToString(note:UInt32(scaled)))" )
        
        return scaled
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
            AUGraphStop(synth!.audioGraph!)
            
        // An interruption began. Update the UI as needed.
        
        case .ended:
            // An interruption ended. Resume playback, if appropriate.
            
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                print("reactivating audio session")
                AUGraphStart(synth!.audioGraph!)
            } else {
                // Interruption ended. Playback should not resume.
            }
            
        default: ()
        }
    }
    
    //TODO: add soundfont argument
    public func initSynth(instrument: Int){
        setupNotifications()
        synth = SoftSynth()
        setInstrument(instrument: instrument)
        
        
        if #available(iOS 10.0, *) {
            setSpeakersAsDefaultAudioOutput()
        } else {
            // Fallback on earlier versions
            print ("setSpeakersAsDefaultAudioOutput is available only from iOS 10");
        }
        
        /*load voices (in background)*/
        DispatchQueue.global(qos: .background).async {
            self.synth!.loadSoundFont()
            self.synth!.loadPatch(patchNo: instrument)
            DispatchQueue.main.async {
                print ("background loading of voices completed." )
            }
        }
        
    }
    
    private func getSequencer(channel: Int) -> Sequencer{
        if (sequencers[channel] == nil){
            sequencers[channel] = Sequencer(channel: channel)
        }
        return sequencers[channel]!
    }
    
    public func setInstrument(idx: Int, channel: Int , mac: String){
        if(allowedInstrumentsIndexes.contains(idx)){
            let pos = allowedInstrumentsIndexes.firstIndex(of: idx)!
            let expression = allowedInstrumentsExpressions[pos]
            setInstrument(instrument: idx, channel: channel, bank: 0, mac: mac, expression: expression)
        } else {
            print(" error! Instrument \(idx) not found in \(allowedInstrumentsIndexes)")
        }
    }
    
    private func setInstrument(instrument: Int, channel: Int = 0, bank: Int = 0, mac: String? = nil, expression: Bool? = false){
        print ("setInstrument \(instrument) \(channel) \(bank) \(mac) \(expression)")
        if(!allowedInstrumentsIndexes.contains(instrument) && bank == 0){
            print(" error! Instrument \(instrument) not found in \(allowedInstrumentsIndexes)")
            return
        }

        if(mac != nil){
            recorders[mac!] = channel
            expressions[mac!] = expression
        }
        
        let infos : instrumentInfos = ( channel: channel, instrument: instrument, bank: bank, mac: mac)
        instruments[channel] = infos
        synth!.loadPatch(patchNo: instrument, channel: channel, bank: bank)
        getSequencer(channel: channel).patch = UInt32(instrument)
        
        if(mac != nil){
            midiEventWithMac(command: 0xB0 + UInt32(channel), d1: 11, d2: 10, mac: mac!) //invio un expression fittizio
        } else {
            midiEvent(command: 0xB0 + UInt32(channel), d1: 11, d2: 10);
        }
        
        let specialModeInfos = specialModes[Int(channel)]
        if (specialModeInfos?.1 == 1 /*WAND*/ && specialModeInfos?.3 == true /*continuous*/){
            noteOn(channel: channel, note: Int(lastNoteForChannel[channel]), velocity: 80)
        }

    }
    
    public func noteOnWithMac(channel: Int, note: Int, velocity: Int, mac: String ){
        print ("noteOnWithMac \(channel) \(note) \(velocity) \(mac)")
        var vel = velocity
        let ch = recorders[mac] ?? channel
        let expression = expressions[mac] ?? false
        //if (!expression){
        //    vel = Int(xpressionsMap[channel]?.last ?? UInt32(velocity))
        //}
        noteOn(channel: ch, note: note, velocity: vel)
    }
    
    public func noteOffWithMac(channel: Int, note: Int, velocity: Int, mac: String){
        print ("noteOffWithMac \(channel) \(note) \(velocity) \(mac)")
        let ch = recorders[mac] ?? channel
        noteOff(channel: ch, note: note, velocity: velocity)
    }
    
    public func midiEventWithMac(command: UInt32, d1: UInt32, d2: UInt32, mac: String){
        var _d2 = d2
        let ch = recorders[mac] ?? 0
        let expression = expressions[mac] ?? false
        if(d1==11 && !expression){
            print ("expression disabled for this instrument.")
            _d2 = 80
        }
        midiEvent(command: command+UInt32(ch), d1: d1, d2: _d2)
    }
    
    public func noteOn(channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        let sequencer = getSequencer(channel: channel)
        let _velocity = /*lastNoteOnOff == NOTE_OFF ? 0 :*/ velocity
        lastNoteOnOff = NOTE_ON
        synth!.playNoteOn(channel: channel, note: UInt8(note), midiVelocity: _velocity, sequencer: sequencer)
        sequencer.noteOn(note: UInt8(note))
        let now = (Int64)(NSDate().timeIntervalSince1970*1000)
        //print("\(now) SwiftFlutterMidiSyntPlugin.swift noteOn \(channel)  \(note) \(velocity) ")
    }
    
    public func noteOff(channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        xpressionsMap[channel] = []
        lastNoteOnOff = NOTE_OFF

        let sequencer = getSequencer(channel: channel)
        synth!.playNoteOff(channel: channel, note: UInt8(note), midiVelocity: velocity, sequencer: sequencer)
        sequencer.noteOff(note: UInt8(note))
        //let now = (Int64)(NSDate().timeIntervalSince1970*1000)
        //print("\(now) SwiftFlutterMidiSyntPlugin.swift noteOff \(channel)  \(note) \(velocity) ")
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

    public func midiEvent(command: UInt32, d1: UInt32, d2: UInt32){
        //print("SwiftFlutterMidiSyntPlugin.swift midiEvent \(command)  \(d1) \(d2) (RAW) ")

        //Average on xpression
        var _d1 = d1
        var _d2 = d2

        let ch = Int(command & 0xf)
        let infos = specialModes[ch] //(channel : Int, mode: Int, notes:[Int], continuous: Bool , time: Int, controller: Int)
        let velocity = 80
        //print("SwiftFlutterMidiSyntPlugin.swift midiEvent \(infos)")
        if (infos?.1 == 1){ //WAND MODE
            if(command & 0xf0 == 0xb0){
                switch d1 {
                case 52: /*rotation*/
                    _d2 = scaleRotation(fromMin: 30, fromMax: 80, toMin: 0, toMax: 127, value: _d2)
                    _d1 = 11 //Map rotation to volume via expression
                    synth!.midiEvent(cmd: command, d1: _d1, d2: _d2)
                    
                case 1: /*inclination*/
                    if ((infos?.3)!) { //continuous
                        //use pitch band to reach next note
                        let min_note = (infos?.2)!.min()
                        let max_note = (infos?.2)!.max()
                        let scaled = scaleInclination(fromMin: 34, fromMax: 94, toMin: 0, toMax: 127, value: d2)
                        let uscaled = UInt32(scaled)
                        let note = UInt32((max_note! + min_note!) / 2)

                        //Pitch bend
                        let bend = UInt32(uscaled*0x4000/127)
                        let pb_d1 = bend & 0x7f
                        let pb_d2 = (bend >> 8) & 0x7f
                        synth!.midiEvent(cmd: 0xE0 | UInt32(ch), d1: pb_d1, d2: pb_d2)
                        print("SwiftFlutterMidiSynthPlugin.swift note \(note) (\(noteToString(note:note))) => bend \(bend*100/0x4000)% d1 \(d1) d2 \(d2)")

                        if(lastNoteForChannel[ch] != note){
                            noteOn(channel:ch, note:Int(note), velocity:velocity)
                            noteOff(channel: ch, note: Int(lastNoteForChannel[ch]), velocity: 0)

                            lastNoteForChannel[ch] = note
                        }
                        
                    } else {
                        let notes = infos?.2 ?? []
                        let scaled = scaleInclination(fromMin: 34, fromMax: 94, toMin: notes.min() ?? 0, toMax: notes.max() ?? 127, value: d2)
                        let note = selectNote(d2:UInt32(scaled), ch:UInt32(ch), notes:notes)
                        if(lastNoteForChannel[ch] != note){
                            print("SwiftFlutterMidiSynthPlugin.swift note \(note) (\(noteToString(note:note))) midiEvent \(infos)")
                            //synth!.midiEvent(cmd: command, d1: 123, d2: 0) /*turn off current note*/

                            noteOn(channel:ch, note:Int(note), velocity:velocity)
                            noteOff(channel: ch, note: Int(lastNoteForChannel[ch]), velocity: 0)

                            lastNoteForChannel[ch] = note
                        }
                    }
                default:
                    break
                }
            }

        } else {
            if(command & 0xf0 == 0xb0 && d1 == 11){
                //print("SwiftFlutterMidiSyntPlugin.swift midiEvent \(command)  \(d1) \(d2) (RAW) ")
                //_d2 = xpressionAvg(ch: Int(command & 0xf), value: _d2)
                _d2 = scaleXpression(min:25, max:110, value: _d2)
                //_d1 = 7
            }
            synth!.midiEvent(cmd: command, d1: _d1, d2: _d2);
        }
    }
    
    public func setReverb(dryWet: Float){
        synth!.setReverb(dryWet: dryWet)
    }
    
    public func setDelay(dryWet: Float){
        synth!.setDelay(dryWet: dryWet)
    }

    public func setSpecialMode(channel: UInt32, mode: UInt32, notes: [Int], continuous: Bool, time: UInt32, controller: UInt32){
        let infos : specialModeInfos = (channel: channel, mode: mode, notes: notes, continuous: continuous, time: time, controller: controller)
        let prev_mode = specialModes[Int(channel)]?.1
        if(prev_mode != mode){
            lastNoteForChannel[Int(channel)] = 0;
        }

        specialModes[Int(channel)] = infos

        print("setSpecialMode mode \(mode) on channel \(channel) - notes \(notes) continuous \(continuous) time \(time) controller \(controller)")
        
        if(continuous && mode == 1){
            let span = notes.max()! - notes.min()! //semitones span
            
            //Setup Pitch Bend Range
            //CC101 set value 0
            //CC100 set value 0
            //CC6 set value for pb range (eg 12 for 12 semitones up / down)
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 101, d2: 0) //Set Pitch Bend Range RPN
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 100, d2: 0) //Set Pitch Bend Range RPN
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 6, d2: UInt32((span+1)/2))  //Set Entry Value
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 101, d2: 127) //RPN Null
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 100, d2: 127) //RPN Null

            // Enable/Disable portamento - mode 1 is WAND Mode
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 65, d2: mode == 1 ? 127 : 0)
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 5, d2: time) //Portamento time (CC5)
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 84, d2: controller /*note*/ /*infos?.5*/ /*?? 0*/) //Portamento Controller (CC84) TEST = 64

        } else {
            // Enable/Disable portamento - mode 1 is WAND Mode
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 65, d2: mode == 1 ? 127 : 0)
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 5, d2: time) //Portamento time (CC5)
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 84, d2: controller /*note*/ /*infos?.5*/ /*?? 0*/) //Portamento Controller (CC84) TEST = 64
        }
    }
    
    public func hasSpecialModeWAND(channel: UInt32) -> Bool {
        let infos = specialModes[Int(channel)]
        return infos?.1 == 1
    }
}
