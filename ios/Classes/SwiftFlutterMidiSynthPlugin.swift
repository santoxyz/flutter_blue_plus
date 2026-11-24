import Flutter
import UIKit
import AVFoundation
import AudioToolbox
import Foundation

//AIR DRUM mode (mode 3) - see air_drum.dart
//The re.corder sends: CC1 = inclination, CC52 = wrist rotation and
//CC53 = z-axis (mapped on entering the mode to read the acceleration peaks).
//- the z-axis acceleration peaks trigger the drum hits
//- the inclination selects the zone: low = drums, high = cymbals
//- the wrist rotation selects which drum/cymbal (left, center, right)
class AirDrumState {
    var base:Double = 64.0       //slow moving baseline of the z-axis CC (float: the integer division would stall it)
    var lastZ:Int = 64           //last raw CC53 value
    var prevDev:Int = 0          //deviation of the previous z sample (for the slope)
    var zValid:Bool = false      //false until the first z sample (no slope available yet)
    var lastSlope:Int = 0        //last slope (for the UI debug)
    var detectorState:Int = 0    //0 = IDLE, 1 = ARMED, 2 = REFRACTORY
    var armPeak:Int = 0          //peak slope reached while armed (end-of-fast-phase detection)
    var armEnergy:Int = 0        //sum of the slope magnitudes while armed (strike strength)
    var armSlope:Int = 0         //sign of the slope that armed the detector
    var stateMs:Double = 0       //when the current state was entered
    var inclination:Int = 64     //last raw CC1 value
    var rotation:Int = 64        //last raw CC52 value
    var inclHist:[Int] = [64, 64, 64] //last 3 raw CC1 values
    var rotHist:[Int] = [64, 64, 64]  //last 3 raw CC52 values
    var inclSmooth:Int = 64      //median of the last CC1 values (aimed zone)
    var rotSmooth:Int = 64       //median of the last CC52 values (aimed zone)
    var inclZone:Int = 0         //0 = drums, 1 = cymbals
    var hitElement:Int = 0       //element index captured when the hit is armed
    var lastElement:Int = -1     //last element index sent to the UI
    var lastDebugMs:Double = 0   //throttle for the UI debug messages
}

@objcMembers public class SwiftFlutterMidiSynthPlugin: NSObject, FlutterPlugin {

    var parent: FlutterBluePlusPlugin?
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
    let movingWindowDepth = 1
    var bendForChannel: [Int] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
    var targetBendForChannel: [Int] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
    typealias specialModeInfos = (channel : UInt32, mode: UInt32, notes:[Int], continuous: Bool , time: UInt32, controller: UInt32, muted: Bool)
    var specialModes = [Int:specialModeInfos]() //[channel, specialModeInfos]
    var backgroundBendTaskIsRunning: Bool = false

    let wand_velocity = 70

    //AIR DRUM tuning - measured on the device: CC53 (z-axis) is an ORIENTATION
    //(gravity) channel like CC1: 64 when horizontal, saturating at 127 at both
    //ends of the swing, so the hits are detected via the slope (rate of change)
    let AIR_DRUM_INCL_CYMBALS_THR = 80 //CC1 > thr => cymbals zone, drums otherwise
    let AIR_DRUM_ROT_LEFT_MAX = 36     //CC52 < thr => left zone (measured: 20 left, 52 center, 110 right)
    let AIR_DRUM_ROT_RIGHT_MIN = 81    //CC52 >= thr => right zone
    let AIR_DRUM_PEAK_DROP = 8         //slope fade (CC/sample) that ends the fast phase of a strike
    let AIR_DRUM_REFRACTORY_MS = 180.0  //min interval between two hits (swallows the impact bounce)
    let AIR_DRUM_ARM_TIMEOUT_MS = 150.0 //a fast phase longer than this triggers the hit anyway
    let AIR_DRUM_BASELINE_DIV = 64.0   //baseline adaptation speed (ema divisor)
    let AIR_DRUM_SLOPE_THR_MIN = 4     //slope threshold at max sensitivity (CC/sample)
    let AIR_DRUM_SLOPE_THR_MAX = 28    //slope threshold at min sensitivity (CC/sample)
    let AIR_DRUM_DEFAULT_SLOPE_THR = 14 //slope threshold when not set via CC5
    let AIR_DRUM_SLOPE_VEL_MAX = 80    //strike energy (sum of the slopes) mapped to the maximum velocity
    let AIR_DRUM_MIN_VELOCITY = 40
    let AIR_DRUM_NOTE_DURATION_S = 0.15
    let AIR_DRUM_UI_DEBUG_PERIOD_MS = 100.0 //throttle of the AirDrumDebug messages to the UI
    let AIR_DRUM_DEBUG = false //logs the raw CC values and the state machine (set false when done debugging)
    var airDrumStates = [Int:AirDrumState]()

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

        let specialModeInfos = specialModes[Int(channel)]

        let infos : instrumentInfos = ( channel: channel, instrument: instrument, bank: bank, mac: mac)
        instruments[channel] = infos
        synth!.loadPatch(patchNo: instrument, channel: channel, bank: bank)
        getSequencer(channel: channel).patch = UInt32(instrument)
        
        if(mac != nil){
            midiEventWithMac(command: 0xB0 + UInt32(channel), d1: 11, d2: 10, mac: mac!) //invio un expression fittizio
        } else {
            midiEvent(command: 0xB0 + UInt32(channel), d1: 11, d2: 10);
        }
        
        if (specialModeInfos?.mode == 1 /*WAND*/ && specialModeInfos?.continuous == true /*continuous*/){
            wand_noteOn(channel: channel, note: Int(lastNoteForChannel[channel]), velocity: wand_velocity)
        }
    }
    
    public func noteOnWithMac(channel: Int, note: Int, velocity: Int, mac: String ){
        //print ("noteOnWithMac \(channel) \(note) \(velocity) \(mac)")
        var vel = velocity
        let ch = recorders[mac] ?? channel
        let expression = expressions[mac] ?? false
        //if (!expression){
        //    vel = Int(xpressionsMap[channel]?.last ?? UInt32(velocity))
        //}
        noteOn(channel: ch, note: note, velocity: vel)
    }
    
    public func noteOffWithMac(channel: Int, note: Int, velocity: Int, mac: String){
        //print ("noteOffWithMac \(channel) \(note) \(velocity) \(mac)")
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

    private func wand_noteOff(channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        var _channel = channel
        let sequencer = getSequencer(channel: _channel)
        let _velocity = /*lastNoteOnOff == NOTE_OFF ? 0 :*/ velocity
        synth!.playNoteOff(channel: _channel, note: UInt8(note), midiVelocity: _velocity, sequencer: sequencer)
        sequencer.noteOff(note: UInt8(note))
    }
    
    private func wand_noteOn(channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        var _channel = channel
        let sequencer = getSequencer(channel: _channel)
        let _velocity = /*lastNoteOnOff == NOTE_OFF ? 0 :*/ velocity
        synth!.playNoteOn(channel: _channel, note: UInt8(note), midiVelocity: _velocity, sequencer: sequencer)
        sequencer.noteOn(note: UInt8(note))
        //let now = (Int64)(NSDate().timeIntervalSince1970*1000)
        //print("\(now) SwiftFlutterMidiSyntPlugin.swift noteOn \(_channel)  \(note) \(velocity) ")
    }

    public func noteOn(channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        if(specialModes[channel]?.mode == 3){
            //AIR DRUM mode: the breath/fingering notes are filtered -
            //the acceleration peak itself is the only note-on
            return
        }
        var _channel = channel
        var _velocity = /*lastNoteOnOff == NOTE_OFF ? 0 :*/ velocity

        if(specialModes[_channel]?.mode == 1){
          _channel += 1
          _velocity = wand_velocity - 10
        }

        let sequencer = getSequencer(channel: _channel)
        lastNoteOnOff = NOTE_ON
        synth!.playNoteOn(channel: _channel, note: UInt8(note), midiVelocity: _velocity, sequencer: sequencer)
        sequencer.noteOn(note: UInt8(note))

        let now = (Int64)(NSDate().timeIntervalSince1970*1000)
        //print("\(now) SwiftFlutterMidiSynthPlugin.swift noteOn \(_channel)  \(note) \(_velocity) ")
    }
    
    public func noteOff(channel: Int, note: Int, velocity: Int){
        if (channel < 0 || note < 0 || velocity < 0){ return }
        if(specialModes[channel]?.mode == 3){
            //AIR DRUM mode: the breath/fingering notes are filtered -
            //the acceleration peak itself is the only note-on
            return
        }
        var _channel = channel

        if(specialModes[_channel]?.mode == 1){
          _channel += 1
        }

        xpressionsMap[_channel] = []
        lastNoteOnOff = NOTE_OFF

        let sequencer = getSequencer(channel: _channel)
        synth!.playNoteOff(channel: _channel, note: UInt8(note), midiVelocity: velocity, sequencer: sequencer)
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

    private func backgroundBendTask() {
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
                synth!.midiEvent(cmd: 0xE0 | UInt32(ch), d1: UInt32(pb_d1), d2: UInt32(pb_d2))
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

    public func midiEvent(command: UInt32, d1: UInt32, d2: UInt32){

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
                    synth!.midiEvent(cmd: _command, d1: _d1, d2: uscaled)

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
                        synth!.midiEvent(cmd: 0xE0 | UInt32(ch), d1: UInt32(pb_d1), d2: UInt32(pb_d2))
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
                            wand_noteOff(channel:ch, note:0, velocity:0)
                            wand_noteOn(channel:ch, note:Int(lastNoteForChannel[ch]), velocity:wand_velocity)
                        }
                    }
                case 5: //Portamento Time
                    //synth!.midiEvent(cmd: _command, d1: _d1, d2: _d2)
                    specialModes[ch]?.time = _d2


                default:
                    break
                }
            }

        } else if (infos?.mode == 3) { //AIR DRUM MODE
            if(_command & 0xf0 == 0xb0){
                switch d1 {
                case 1: /*inclination: selects the drums/cymbals zone*/
                    airDrumSetInclination(ch: ch, value: Int(_d2))
                case 52: /*wrist rotation: selects which drum/cymbal*/
                    airDrumSetRotation(ch: ch, value: Int(_d2))
                case 53: /*z-axis: acceleration peak => drum hit*/
                    airDrumOnZ(ch: ch, value: Int(_d2))
                case 5: /*hit sensitivity threshold (like the wand portamento time)*/
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
            synth!.midiEvent(cmd: command, d1: _d1, d2: _d2);
        }
    }
    
    public func setParent(arg: FlutterBluePlusPlugin){
        parent = arg
    }
    
    public func setReverb(dryWet: Float){
        synth!.setReverb(dryWet: dryWet)
    }
    
    public func setDelay(dryWet: Float){
        synth!.setDelay(dryWet: dryWet)
    }

    public func setSpecialMode(channel: UInt32, mode: UInt32, notes: [Int], continuous: Bool, time: UInt32, controller: UInt32, muted: Bool){
        let infos : specialModeInfos = (channel: channel, mode: mode, notes: notes, continuous: continuous, time: time, controller: controller, muted: muted)
        let prev_mode = specialModes[Int(channel)]?.1 //mode
        let prev_continuous = specialModes[Int(channel)]?.3 //continuous

        if(prev_mode != mode || !continuous){
            lastNoteForChannel[Int(channel)] = 0;
        }

        synth!.midiEvent(cmd: 0xB0 | channel, d1: 123, d2: 0) //ALL NOTES OFF

        specialModes[Int(channel)] = infos

        if(/*continuous &&*/ mode == 1){
            if(backgroundBendTaskIsRunning == false){
                do {
                    try DispatchQueue.global(qos: .background).async {
                        self.backgroundBendTaskIsRunning = true
                        self.backgroundBendTask();
                    }
                } catch {
                    print ("Error in DispatchQueue trying to start backgroundBendTask()");
                }
            }
            
            let span = notes.max()! - notes.min()! //semitones span, notes includes upper octave rootnote
            let pps = 16384/span
            print("setSpecialMode mode \(mode) on channel \(channel) - notes \(notes) span \(span) (\(pps) points/semitone) continuous \(continuous) time \(time) controller \(controller) muted \(muted)")

            synth!.midiEvent(cmd: 0xB0 | channel, d1: 7, d2: 0) //tolgo volume

            //Setup Pitch Bend Range
            //CC101 set value 0
            //CC100 set value 0
            //CC6 set value for pb range (eg 12 for 12 semitones up / down)
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 101, d2: 0) //Set Pitch Bend Range RPN
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 100, d2: 0) //Set Pitch Bend Range RPN
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 6, d2: UInt32(span/2))  //Set Entry Value
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 101, d2: 127) //RPN Null
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 100, d2: 127) //RPN Null

            // Enable/Disable portamento - mode 1 is WAND Mode
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 65, d2: mode == 1 ? 127 : 0)
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 5, d2: time) //Portamento time (CC5)
            //synth!.midiEvent(cmd: 0xB0 | channel, d1: 84, d2: controller /*note*/ /*infos?.5*/ /*?? 0*/) //Portamento Controller (CC84) TEST = 64

            if (continuous || prev_continuous != continuous){
                //Causes audio glitch !
                wand_noteOn(channel:Int(channel), note: Int(lastNoteForChannel[Int(channel)]), velocity: wand_velocity)
            } else if (!continuous) {
                wand_noteOff(channel:Int(channel), note:0, velocity:0)
            }
            synth!.midiEvent(cmd: 0xB0 | channel, d1: 7, d2: muted ? 0 : 127)

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

    public func hasSpecialModeAIRDRUM(channel: UInt32) -> Bool {
        let infos = specialModes[Int(channel)]
        return infos?.1 == 3
    }
    
    ///////////////////////
    //AIR DRUM mode (mode 3)
    ///////////////////////
    private func airDrumState(ch: Int) -> AirDrumState {
        var state = airDrumStates[ch]
        if (state == nil) {
            state = AirDrumState()
            airDrumStates[ch] = state
        }
        return state!
    }

    //median of 3 values: follows an intentional wrist move within ~2 samples
    //while rejecting the single-sample swings of a strike
    private func airDrumMedian(_ a: [Int]) -> Int {
        let s = a.sorted()
        return s[1]
    }
    
    private func airDrumNotes(ch: Int) -> [Int] {
        return specialModes[ch]?.notes ?? []
    }
    
    //converts the sensitivity (CC5, 10..100, higher = more sensitive) to the
    //slope threshold in CC units per sample
    private func airDrumThreshold(ch: Int) -> Int {
        let sens = Int(specialModes[ch]?.time ?? 0)
        if (sens < 1) { return AIR_DRUM_DEFAULT_SLOPE_THR }
        return AIR_DRUM_SLOPE_THR_MAX - (sens - 10) * (AIR_DRUM_SLOPE_THR_MAX - AIR_DRUM_SLOPE_THR_MIN) / 90
    }
    
    private func airDrumElementIndex(state: AirDrumState) -> Int {
        //cymbals if the smoothed inclination > 80, drums otherwise. The smoothed
        //values are used so that the fast swings of a strike do not change the
        //aimed element: the zone is the one the user is aiming at.
        state.inclZone = state.inclSmooth > AIR_DRUM_INCL_CYMBALS_THR ? 1 : 0
        let rotZone = state.rotSmooth < AIR_DRUM_ROT_LEFT_MAX ? 0 : (state.rotSmooth < AIR_DRUM_ROT_RIGHT_MIN ? 1 : 2)
        return state.inclZone * 3 + rotZone
    }
    
    //sends the currently aimed drum element to the UI (air_drum.dart)
    private func airDrumUpdateElement(ch: Int, state: AirDrumState) {
        let idx = airDrumElementIndex(state: state)
        if (idx == state.lastElement) { return }
        state.lastElement = idx
        let notes = airDrumNotes(ch: ch)
        if (idx < 0 || idx >= notes.count) { return }
        var note = notes[idx]
        parent?.sendMessage("AirDrum", withBody: Data(bytes:&note, count:1))
    }
    
    private func airDrumSetInclination(ch: Int, value: Int) {
        let state = airDrumState(ch: ch)
        let changed = state.inclination != value
        state.inclination = value
        state.inclHist[0] = state.inclHist[1]
        state.inclHist[1] = state.inclHist[2]
        state.inclHist[2] = value
        state.inclSmooth = airDrumMedian(state.inclHist)
        if (AIR_DRUM_DEBUG && changed) {
            let zone = airDrumElementIndex(state: state) >= 3 ? "cymbals" : "drums"
            print("AD ch\(ch) INCL v=\(value) s=\(state.inclSmooth) zone=\(zone)")
        }
        airDrumUpdateElement(ch: ch, state: state)
        airDrumSendDebug(ch: ch, state: state, now: Double(NSDate().timeIntervalSince1970 * 1000))
    }
    
    private func airDrumSetRotation(ch: Int, value: Int) {
        let state = airDrumState(ch: ch)
        let changed = state.rotation != value
        state.rotation = value
        state.rotHist[0] = state.rotHist[1]
        state.rotHist[1] = state.rotHist[2]
        state.rotHist[2] = value
        state.rotSmooth = airDrumMedian(state.rotHist)
        if (AIR_DRUM_DEBUG && changed) {
            let zone = ["left", "center", "right"][airDrumElementIndex(state: state) % 3]
            print("AD ch\(ch) ROT v=\(value) s=\(state.rotSmooth) zone=\(zone)")
        }
        airDrumUpdateElement(ch: ch, state: state)
        airDrumSendDebug(ch: ch, state: state, now: Double(NSDate().timeIntervalSince1970 * 1000))
    }
    
    ///detects the strikes on the z-axis CC and triggers the drum hit.
    ///The z-axis CC is an orientation (gravity) channel saturating at both ends
    ///of the swing, so the hit is detected via the SLOPE (rate of change):
    ///ARMED on a fast change -> HIT when the slope reverses or fades ->
    ///REFRACTORY to avoid the stick bounce retriggering (each hit must
    ///produce exactly one sound).
    private func airDrumOnZ(ch: Int, value: Int) {
        let state = airDrumState(ch: ch)
        let now = Double(NSDate().timeIntervalSince1970 * 1000)
        let dev = Int((Double(value) - state.base).rounded())
        state.lastZ = value
        
        //slow baseline adaptation (follows any held position, even a saturated one)
        state.base += (Double(value) - state.base) / AIR_DRUM_BASELINE_DIV
        
        //slope = rate of change of the deviation: the strike signature.
        //The CC53 value saturates at both ends of the swing (orientation channel),
        //so the amplitude carries no dynamics, only the speed does.
        var slope = 0
        if (state.zValid) { slope = dev - state.prevDev }
        state.prevDev = dev
        state.zValid = true
        state.lastSlope = slope
        
        if (AIR_DRUM_DEBUG) { print("AD ch\(ch) Z v=\(value) b=\(Int(state.base)) d=\(dev) sl=\(slope) st=\(state.detectorState) pk=\(state.armPeak) en=\(state.armEnergy)") }
        
        let threshold = airDrumThreshold(ch: ch)
        
        switch state.detectorState {
        case 0: //IDLE: arm on a fast change (a strike, not a slow tilt)
            if (abs(slope) >= threshold) {
                state.detectorState = 1; state.armPeak = abs(slope); state.armEnergy = state.armPeak
                state.armSlope = slope > 0 ? 1 : -1
                state.stateMs = now
                state.hitElement = airDrumElementIndex(state: state) //capture the aimed element at the beginning of the strike
                if (AIR_DRUM_DEBUG) { print("AD ch\(ch) ARM pk=\(state.armPeak) el=\(state.hitElement)") }
            }
        case 1: //ARMED: accumulate the strike energy until the fast phase ends
            let s = abs(slope)
            state.armEnergy += s
            if (s > state.armPeak) { state.armPeak = s }
            //the fast phase ends when the slope reverses (impact turnaround) or fades
            if (s < state.armPeak - AIR_DRUM_PEAK_DROP || slope * state.armSlope < 0) {
                airDrumTrigger(ch: ch, intensity: state.armEnergy)
                state.detectorState = 2; state.stateMs = now
            } else if (now - state.stateMs > AIR_DRUM_ARM_TIMEOUT_MS) { //long fast phase: trigger anyway
                airDrumTrigger(ch: ch, intensity: state.armEnergy)
                state.detectorState = 2; state.stateMs = now
            }
        default: //2 = REFRACTORY: swallow the impact bounce/ringing
            if (now - state.stateMs > AIR_DRUM_REFRACTORY_MS) { state.detectorState = 0 }
        }
        
        airDrumSendDebug(ch: ch, state: state, now: now)
    }
    
    //sends the live values to the UI debug panel (air_drum.dart), throttled
    private func airDrumSendDebug(ch: Int, state: AirDrumState, now: Double) {
        if (now - state.lastDebugMs < AIR_DRUM_UI_DEBUG_PERIOD_MS) { return }
        state.lastDebugMs = now
        let data = Data([UInt8(max(0, min(127, state.inclSmooth))),
                         UInt8(max(0, min(127, state.rotSmooth))),
                         UInt8(max(0, min(127, state.lastZ))),
                         UInt8(Int(max(0, min(127, state.base)))),
                         UInt8(state.detectorState),
                         UInt8(max(0, min(127, state.lastSlope + 64))))]) //slope offset by 64 (signed)
        parent?.sendMessage("AirDrumDebug", withBody: data)
    }
    
    private func airDrumTrigger(ch: Int, intensity: Int) {
        let notes = airDrumNotes(ch: ch)
        let state = airDrumState(ch: ch)
        let idx = state.hitElement //element aimed when the strike started (captured on ARM)
        if (idx < 0 || idx >= notes.count) { return }
        let outCh = Int(specialModes[ch]?.controller ?? 9)
        let note = notes[idx]
        //the peak slope is the strike speed: map it to the velocity
        let s = min(intensity, AIR_DRUM_SLOPE_VEL_MAX)
        var vel = AIR_DRUM_MIN_VELOCITY + s * (127 - AIR_DRUM_MIN_VELOCITY) / AIR_DRUM_SLOPE_VEL_MAX
        if (vel > 127) { vel = 127 }
        if (vel < AIR_DRUM_MIN_VELOCITY) { vel = AIR_DRUM_MIN_VELOCITY }
        print("airDrum HIT ch=\(outCh) note=\(note) vel=\(vel) intensity=\(intensity)")
        wand_noteOn(channel: outCh, note: note, velocity: vel)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + AIR_DRUM_NOTE_DURATION_S) {
            self.wand_noteOff(channel: outCh, note: note, velocity: 0)
        }
        var n = note
        parent?.sendMessage("AirDrum", withBody: Data(bytes:&n, count:1)) //Send played drum element to UI
    }
}
