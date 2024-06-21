part of flutter_blue_plus;

class FlutterMidiSynthPlugin {
  static const DEFAULT_SYNTH = 0;
  //static const MethodChannel _channel = const MethodChannel('FlutterMidiSynthPlugin');
  static const MethodChannel _channel = const MethodChannel('flutter_blue_plus/methods');

  static Future<void> transpose(int t) async {
    return _channel.invokeMethod('transpose',t);
  }

  static Future<void> initSynth(int synthIdx, int i, [bool classroom = false]) async {
    return _channel.invokeMethod('initSynth',{'synthIdx':synthIdx, 'instrument':i, 'classroom': classroom});
  }

  static Future<void> setInstrument(int synthIdx, int instrument, int channel, int bank, String mac, bool expression, [int transpose = 0]) async {
    return _channel.invokeMethod('setInstrument',{'synthIdx':synthIdx, 'channel':channel, 'instrument':instrument, 'bank':bank , 'mac':mac, 'expression':expression, 'transpose':transpose});
  }

  static Future<void> noteOn(int synthIdx, int channel, int note, int velocity) async {
    return _channel.invokeMethod('noteOn', {'synthIdx':synthIdx, 'channel':channel, 'note':note, 'velocity':velocity} );
  }

  static Future<void> noteOff(int synthIdx, int channel, int note, int velocity) async {
    return _channel.invokeMethod('noteOff', {'synthIdx':synthIdx, 'channel':channel, 'note':note, 'velocity':velocity} );
  }

  static Future<void> midiEvent(int synthIdx, int cmd, int d1, int d2) async {
    return _channel.invokeMethod('midiEvent', {'synthIdx':synthIdx, 'command':cmd, 'd1':d1, 'd2':d2} );
  }

  static Future<void> setReverb(int synthIdx, double amount) async {
    return _channel.invokeMethod('setReverb', {'synthIdx':synthIdx, 'amount':amount} );
  }

  static Future<void> setDelay(int synthIdx, double amount) async {
    return _channel.invokeMethod('setDelay', {'synthIdx':synthIdx, 'amount':amount} );
  }

  static Future<void> initAudioSession(int param) async {
    return _channel.invokeMethod('initAudioSession', param);
  }

  static Future<void> setAllowedInstrumentsIndexes(List instruments, List expressions) async {
    return _channel.invokeMethod('setAllowedInstrumentsIndexes', {"instruments": instruments, "expressions": expressions});
  }

  ///////////////////////
  //FLUID MEDIAPLAYER API
  ///////////////////////
  static Future<dynamic> load(String name,[int ticksPerBeat = 960]) async {
    return _channel.invokeMethod('MIDIPrepare', {'name':name , 'ticksPerBeat':ticksPerBeat});
  }

  static Future<void> start() async {
    return _channel.invokeMethod('MIDIPlay');
  }

  static Future<void> stop() async {
    return _channel.invokeMethod('MIDIStop');
  }

  static Future<void> pause(bool b) async {
    return b ? _channel.invokeMethod('MIDIPause') :  _channel.invokeMethod('MIDIResume');
  }

  static Future<String> position() async {
    final String res = await _channel.invokeMethod('MIDIGetCurrentTick');
    return res;
  }

  static Future<String> setVolume(double v) async {
    final String res = await _channel.invokeMethod('MIDISetVolume',{"volume":v});
    return res;
  }

  static Future<String> setTempo(double rate) async {
    final String res = await _channel.invokeMethod('MIDISetTempo',{"rate":rate});
    return res;
  }
  static Future<String> setMetronomeVolume(double vol) async {
    final String res = await _channel.invokeMethod('MIDISetMetronomeVolume',{"volume":vol});
    return res;
  }

  static void setSpecialMode(int channel, int mode, List notes, bool continuous, int time, int controller, bool muted) async {
    await _channel.invokeMethod("setSpecialMode",
      {"channel": channel, "mode":mode, "notes":notes, "continuous":continuous, "time":time, "controller": controller, "muted": muted});
    return;
  }

}
