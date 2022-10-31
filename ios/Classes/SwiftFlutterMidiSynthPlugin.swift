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

        default:
            print ("unknown method \(call.method)" )
        }
        
    }

    private func xpressionScale(min: Int, max: Int, value: UInt32) -> UInt32 {
        let scaled: Double = Double(min) + Double((max-min)*Int(value))/127.0
        print("xpressionScale min=\(min) max=\(max) v=\(value) scaled=\(scaled)" )
        return UInt32(scaled);
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
        let now = (Int64)(NSDate().timeIntervalSince1970*1000)
        //print("\(now) SwiftFlutterMidiSyntPlugin.swift noteOff \(channel)  \(note) \(velocity) ")
    }
    
    public func midiEvent(command: UInt32, d1: UInt32, d2: UInt32){
        //print("SwiftFlutterMidiSyntPlugin.swift midiEvent \(command)  \(d1) \(d2) (RAW) ")

        //Average on xpression
        var _d1 = d1
        var _d2 = d2
        if(command & 0xf0 == 0xb0 && d1 == 11){
            //print("SwiftFlutterMidiSyntPlugin.swift midiEvent \(command)  \(d1) \(d2) (RAW) ")
            //_d2 = xpressionAvg(ch: Int(command & 0xf), value: _d2)
            _d2 = xpressionScale(min:25, max:110, value: _d2)
            //_d1 = 7
        }
        synth!.midiEvent(cmd: command, d1: _d1, d2: _d2);
    }
    
    public func setReverb(dryWet: Float){
        synth!.setReverb(dryWet: dryWet)
    }
    
    public func setDelay(dryWet: Float){
        synth!.setDelay(dryWet: dryWet)
    }
    
}
