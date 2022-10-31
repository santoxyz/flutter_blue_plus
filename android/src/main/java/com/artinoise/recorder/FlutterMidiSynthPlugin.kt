package com.artinoise.recorder

import android.R
import android.app.Activity
import android.content.Context
import android.content.res.Resources
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry.Registrar
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import java.util.*
import java.util.HashMap

/** FlutterMidiSynthPlugin */
public class FlutterMidiSynthPlugin(val context: Context): /*FlutterPlugin, MethodCallHandler,*/ /* MidiDriver.OnMidiStartListener,*/
  ActivityAware {

  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var activity: Activity
  private lateinit var channel : MethodChannel
  private lateinit var midiBridge: MidiBridge
  private var TAG: String = "FlutterMidiSynthPlugin"

  private val recorders = mutableListOf<String>() //mac
  private val isDrum = mutableListOf<Boolean>()
  private val expressions = HashMap<String, Boolean>() //mac,expression
  private var allowedInstrumentsIndexes = mutableListOf<Int>()
  private var allowedInstrumentsExpressions = mutableListOf<Boolean>()

  //NO MORE used as a plugin
  /*
  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    println("FlutterMidiSynthPlugin.kt onAttachedToEngine")
    attachToEngine(flutterPluginBinding)
  }

  public fun attachToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    println("FlutterMidiSynthPlugin.kt attachToEngine")
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "flutter_blue_plus/methods")
    //channel = MethodChannel(flutterPluginBinding.binaryMessenger, "FlutterMidiSynthPlugin")
    channel.setMethodCallHandler(this)
    context = flutterPluginBinding.applicationContext
  }

  // This static function is optional and equivalent to onAttachedToEngine. It supports the old
  // pre-Flutter-1.12 Android projects. You are encouraged to continue supporting
  // plugin registration via this function while apps migrate to use the new Android APIs
  // post-flutter-1.12 via https://flutter.dev/go/android-project-migration.
  //
  // It is encouraged to share logic between onAttachedToEngine and registerWith to keep
  // them functionally equivalent. Only one of onAttachedToEngine or registerWith will be called
  // depending on the user's project. onAttachedToEngine or registerWith must both be defined
  // in the same class.

  companion object {
    @JvmStatic
    fun registerWith(registrar: Registrar) {
      println("FlutterMidiSynthPlugin.kt registerWith")
      val channel = MethodChannel(registrar.messenger(), "FlutterMidiSynthPlugin")
      channel.setMethodCallHandler(FlutterMidiSynthPlugin())
    }
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    println("FlutterMidiSynthPlugin.kt onMethodCall")
    manageMethodCall(call, result)
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    detachFromEngine(binding)
  }

  public fun detachFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  */

  override fun onDetachedFromActivity() {
    TODO("Not yet implemented")
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    TODO("Not yet implemented")
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity;
  }

  override fun onDetachedFromActivityForConfigChanges() {
    TODO("Not yet implemented")
  }

  public fun manageMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method){
      "initSynth" -> {
        println("FlutterMidiSynthPlugin.kt initSynth called - context is " + context)
        // Create midi driver
        midiBridge = MidiBridge(context)
        println("FlutterMidiSynthPlugin.kt midiBridge " + midiBridge)

        // Set on midi start listener
        midiBridge.init(this)

        //onResume:
        midiBridge.start()  //onPause: midiBridge.stop()
        result.success(null);

      }
      "setInstrument" -> {
        val i = call.argument<Int>("instrument")
        val ch = call.argument<Int>("channel")
        val bank = call.argument<Int>("bank")
        val mac = call.argument<String>("mac")
        val expression = call.argument<Boolean>("expression")
        println("setInstrument ch " + ch + " i " + i + " bank " + bank + " mac " + mac + " expression " + expression)
        selectInstrument(ch!!, i!!, bank!!,mac!!,expression!!)
        result.success(null);
      }
      "noteOn" -> {
        val ch = call.argument<Int>("channel")
        val note = call.argument<Int>("note")
        val velocity = call.argument<Int>("velocity")
        println("noteOn ch " + ch + " note " + note + " velocity " + velocity)
        sendNoteOn(ch!!, note!!, velocity!!)
        result.success(null);
      }
      "noteOff" -> {
        val ch = call.argument<Int>("channel")
        val note = call.argument<Int>("note")
        val velocity = call.argument<Int>("velocity")
        sendNoteOff(ch!!, note!!, velocity!!)
        result.success(null);
      }
      "midiEvent" -> {
        val cmd = call.argument<Int>("command")
        val d1 = call.argument<Int>("d1")
        val d2 = call.argument<Int>("d2")

        println("FlutterMidiSynthplugin: midiEvent cmd="+cmd + " d1=" + d1 + " d2=" + d2)

        if (d2!! > 0) {
          sendMidi(cmd!!, d1!!, d2!!)
        } else {
          sendMidi(cmd!!, d1!!)
        }
        result.success(null);
      }
      "setReverb" -> {
        val amount = call.arguments as Double
        for (ch in 0 until 16) {
          sendMidi(0xB0 + ch, 91 /*(CC91: reverb)*/, (amount * 1.27).toInt())
        }
        println("FlutterMidiSynthplugin: setReverb " + amount);
        result.success(null);
      }
      "setDelay" -> {
        println("FlutterMidiSynthplugin: setDelay not yet implemented under Android.");
        result.success(null);
      }
      "initAudioSession" -> {
        println("FlutterMidiSynthplugin: initAudioSession not needed under Android.");
        result.success(null);
      }
      "setAllowedInstrumentsIndexes" -> {
        val args = call.arguments as HashMap<String, *>
        allowedInstrumentsIndexes = args["instruments"] as MutableList<Int>;
        allowedInstrumentsExpressions = args["expressions"] as MutableList<Boolean>;
        println("FlutterMidiSynthplugin: setAllowedInstrumentsIndexes " + allowedInstrumentsIndexes +
                " allowedInstrumentsExpressions " + allowedInstrumentsExpressions);
        result.success(null);
      }

      ///////////////////////
      //FLUID MEDIAPLAYER API
      ///////////////////////
      "MIDIPrepare" -> {
        println("FlutterMidiSynthplugin: MIDIPrepare");
        val name = call.argument<String>("name")
        val ticksPerBeat = call.argument<Int>("ticksPerBeat")
        val path: String = context.getApplicationContext().getDir("flutter", Context.MODE_PRIVATE).getPath()
        val r = midiBridge.MIDIPrepare(path + "/" + name, ticksPerBeat!!);
        result.success(r.toString());
      }
      "MIDIPlay" -> {
        println("FlutterMidiSynthplugin: MIDIPlay");
        val r = midiBridge.MIDIPlay();
        result.success(r.toString());
      }
      "MIDIStop" -> {
        println("FlutterMidiSynthplugin: MIDIStop");
        val r = midiBridge.MIDIStop();
        result.success(r.toString());
      }
      "MIDIPause" -> {
        println("FlutterMidiSynthplugin: MIDIPause");
        val r = midiBridge.MIDIPause();
        result.success(r.toString());
      }
      "MIDIResume" -> {
        println("FlutterMidiSynthplugin: MIDIResume");
        val r = midiBridge.MIDIResume();
        result.success(r.toString());
      }
      "MIDIGetCurrentTick" -> {
        //println("FlutterMidiSynthplugin: MIDIGetCurrentTick");
        val r = midiBridge.MIDIGetCurrentTick();
        result.success(r.toString());
      }
      "MIDISetVolume" -> {
        println("FlutterMidiSynthplugin: MIDISetVolume");
        val vol = call.argument<Double>("volume")
        val r = midiBridge.MIDISetVolume(vol!!);
        result.success(r.toString());
      }
      "MIDISetTempo" -> {
        println("FlutterMidiSynthplugin: MIDISetTempo");
        val rate = call.argument<Double>("rate")
        val r = midiBridge.MIDISetTempo(rate!!);
        result.success(r.toString());
      }
      "MIDISetMetronomeVolume" -> {
        println("FlutterMidiSynthplugin: MIDISetMetronomeVolume");
        val v = call.argument<Double>("volume")
        val r = midiBridge.MIDISetMetronomeVolume(v!!);
        result.success(r.toString());
      }

      else -> {
        println("unknown method " + call.method);
        result.notImplemented();
      }
    }
  }

  public fun selectInstrument(ch: Int, i: Int, bank: Int, mac:String?, expression: Boolean) {
    if(!allowedInstrumentsIndexes.contains(i) && bank == 0){
      println(" error! Instrument " + i + " not found in " + allowedInstrumentsIndexes)
      return
    }

    var _ch = ch
    //Select Sound Bank MSB
    if (!mac.isNullOrEmpty()) { //exclude DRUMS channel
      val idx = recorders.indexOfFirst {it == mac}
      if(idx>=0){
        if(isDrum.size <= idx)
          isDrum.add(ch == 9)
        else
          isDrum[idx] = (ch == 9)
        _ch = if (isDrum[idx]) 9 else idx
      } else {
        recorders.add(mac)
        isDrum.add(ch == 9)
        _ch = if (isDrum[0]) 9 else recorders.size - 1
      }
      expressions[mac] = expression
      print ("recorders: $recorders  - expressions: $expression")
    }
    val bankMSB = bank shr 7
    val bankLSB = bank and 0x7f
    println(" -> selectInstrument ch $_ch i $i bank $bank (bankMSB $bankMSB bankLSB $bankLSB mac $mac)\n")
    sendMidi(0xB0 + _ch, 0x0,  bankMSB)
    sendMidi(0xB0 + _ch, 0x20, bankLSB)
    sendMidiProgramChange(_ch, i)
  }

  public fun sendNoteOnWithMAC(n: Int, v: Int, mac: String) {
    var ch = 0
    try {
      if(!mac.isNullOrEmpty()) {
        val idx = recorders.indexOfFirst {it == mac}
        if(idx>=0){
          ch = if (isDrum[idx]) 9 else idx
        } else {
          recorders.add(mac)
          ch = recorders.size
        }
      }
    } catch (e: KotlinNullPointerException){

    }

    println ("AAAA sendNoteOnWithMAC ${ch} $n $v $mac recorders= $recorders")
    sendNoteOn(ch, n, v)
  }

  public fun sendNoteOffWithMAC(n: Int, v: Int, mac: String) {
    //println ("sendNoteOffWithMAC $ch $n $v $mac recorders= $recorders")

    var ch = 0
    try {
      if(!mac.isNullOrEmpty()) {
        val idx = recorders.indexOfFirst {it == mac}
        if(idx>=0){
          ch = if (isDrum[idx]) 9 else idx
        } else {
          recorders.add(mac)
          ch = recorders.size
        }
      }
    } catch (e: KotlinNullPointerException){}
    sendNoteOff(ch, n, v)
  }

  public fun sendNoteOn(ch: Int, n: Int, v: Int) {
    //println (" -> noteON ch $ch n $n v $v")
    val msg = ByteArray(3)
    msg[0] = (0x90 or ch).toByte()
    msg[1] = n.toByte()
    msg[2] = v.toByte()
    if ( midiBridge.engine != null) midiBridge.write(msg)
  }

  public fun sendNoteOff(ch: Int, n: Int, v: Int) {
    val msg = ByteArray(3)
    msg[0] = (0x80 or ch).toByte()
    msg[1] = n.toByte()
    msg[2] = v.toByte()
    if (midiBridge.engine != null) midiBridge.write(msg)
  }

  public fun sendMidiProgramChange(ch: Int, i: Int) {
    println ("AAAA sendMidiProgramChange ${ch} ${i} ")
    val msg = ByteArray(2)
    msg[0] = (0xc0 or ch).toByte()
    msg[1] = i.toByte()
    if ( midiBridge.engine != null) midiBridge.write(msg)
  }

  // Send a midi message, 1 bytes (Control/Program Change)
  protected fun sendMidi(i: Int) {
    println ("AAAA sendMidi ${i} ")
    val msg = ByteArray(2)
    msg[0] = 0xc0.toByte()
    msg[1] = i.toByte()
    if ( midiBridge.engine != null) midiBridge.write(msg)
  }

  // Send a midi message, 2 bytes
  protected fun sendMidi(m: Int, i: Int) {
    println ("AAAA sendMidi ${m} ${i} ")
    val msg = ByteArray(2)
    msg[0] = m.toByte()
    msg[1] = i.toByte()
    if ( midiBridge.engine != null) midiBridge.write(msg)
  }

  // Send a midi message, 3 bytes
  public fun sendMidi(m: Int, n: Int, v: Int) {
    //println ("AAAA sendMidi ${m} ${n} ${v} ")

    val msg = ByteArray(3)
    msg[0] = m.toByte()
    msg[1] = n.toByte()
    msg[2] = v.toByte()
    if ( midiBridge.engine != null) midiBridge.write(msg)
  }

  public fun sendMidiWithMAC(m: Int, n: Int, v: Int, mac: String?) {
    if (m != -80)
      println("sendMidiWithMAC $m $n $v $mac recorders= $recorders")

    var vel = v
    var ch = 0
    var expression = false
    try {
      if(!mac.isNullOrEmpty()) {
        val idx = recorders.indexOfFirst {it == mac}
        if(idx>=0){
          ch = idx
        } else {
          recorders.add(mac)
          ch = recorders.size
        }
        expression = expressions[mac]!!
      }
    } catch (e: KotlinNullPointerException){}

    if(n == 11 && !expression){
      println ("expression is filtered for this instrument.")
      vel=64
    }

    if ( m and 0xf0 == 0xC0){ //if this is a ProgramChange, set expression for mac according to allowedInstrumentsExpressions
      val pos = allowedInstrumentsIndexes.indexOf(n)
      println("programchange detected - n=" + n + " pos=" + pos + " expression=" + allowedInstrumentsExpressions[pos])
      expressions[mac!!] = allowedInstrumentsExpressions[pos]
    }

    sendMidi(m + ch, n, vel)
  }



}
