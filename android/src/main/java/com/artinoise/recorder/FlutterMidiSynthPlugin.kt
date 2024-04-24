package com.artinoise.recorder;

import android.app.Activity
import android.content.Context
import androidx.annotation.NonNull
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import java.util.*
import java.util.HashMap
import java.lang.*
import java.lang.Thread
import java.util.ArrayList
import kotlinx.coroutines.*
import java.util.concurrent.TimeUnit
import com.lib.flutter_blue_plus.FlutterBluePlusPlugin

/** FlutterMidiSynthPlugin */
public class FlutterMidiSynthPlugin(val context: Context, val parent: FlutterBluePlusPlugin): /*FlutterPlugin, MethodCallHandler,*/ /* MidiDriver.OnMidiStartListener,*/
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

  private var specialModes = HashMap<Int,HashMap<String, *>>()
  private var lastNoteForChannel = mutableListOf<Int>(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

  private var movingWindowDepth = 1
  private var movingWindowForChannel = mutableListOf(
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
    mutableListOf<Int>(),
  )

  private var bendForChannel = mutableListOf<Int>(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
  private var targetBendForChannel = mutableListOf<Int>(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
  private var backgroundBendTaskIsRunning = false

  private var wand_velocity = 70
  private var classroom = false

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

  private fun backgroundBendTask(){
    var wait = true
    while (backgroundBendTaskIsRunning){
      for (ch in 0 until bendForChannel.size-1) {
        if (bendForChannel[ch] != targetBendForChannel[ch]){
          if(specialModes[ch]?.get("time") == 0 || bendForChannel[ch] == 0){
            bendForChannel[ch] = targetBendForChannel[ch]
          }
          val pb_d1 = bendForChannel[ch] and 0x7f
          val pb_d2 = (bendForChannel[ch] shr 7) and 0x7f
          val msg = ByteArray(3)
          msg[0] = (0xE0 or ch).toByte()
          msg[1] = pb_d1.toByte()
          msg[2] = pb_d2.toByte()
          if ( midiBridge.engine != null) midiBridge.write(msg)

          if(bendForChannel[ch] < targetBendForChannel[ch]){
            bendForChannel[ch] = bendForChannel[ch] + 1
            wait = false
          } else if (bendForChannel[ch] > targetBendForChannel[ch]){
            bendForChannel[ch] = bendForChannel[ch] - 1
            wait = false
          }
          val t = specialModes[ch]?.get("time")
          java.util.concurrent.TimeUnit.NANOSECONDS.sleep((t as Int).toLong() * 100)
          //print("BackgroundBendTask: ch $ch bend ${bendForChannel[ch]} target ${targetBendForChannel[ch]}\n")
        }
      }
      if(wait){
        java.util.concurrent.TimeUnit.MILLISECONDS.sleep(1)
      }
    }
    println("backgroundBendTask stopped.")
  }

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

  public fun manageMethodCall(@NonNull call: MethodCall, @NonNull result: MethodChannel.Result) {
    when (call.method){
      "initSynth" -> {
        println("FlutterMidiSynthPlugin.kt initSynth called - context is " + context)
        val i = call.argument<Int>("instrument")
        classroom = call.argument<Boolean?>("classroom")!!

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

        if (d2!! >= 0) { //ATTENZIONE ALL NOTES OFF HA D2 == 0
          sendMidi(cmd!!, d1!!, d2)
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
      "setSpecialMode" -> {
        val args = call.arguments as HashMap<String, *>
        val channel = args["channel"] as Int
        val mode = args["mode"] as Int
        val notes = args["notes"] as MutableList<Int>
        val continuous = args["continuous"] as Boolean
        val time = args["time"] as Int
        val controller = args["controller"] as Int
        val muted = args["muted"] as Boolean
        setSpecialMode(args, channel, mode, notes, continuous, time/10, controller, muted)

        result.success(null)
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


    val specialModeInfos = specialModes[ch]
    if(specialModeInfos?.get("mode") == 1 && specialModeInfos?.get("continuous") == true){
      //println("SNTX -> selectInstrument mode == 1 && continuous == true ch=$ch lastNoteForChannel=$(lastNoteForChannel[ch])\n")
      wand_sendNoteOn(ch, lastNoteForChannel[ch], wand_velocity /*velocity*/)
    }
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

    //println ("AAAA sendNoteOnWithMAC ${ch} $n $v $mac recorders= $recorders")
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

    //println ("AAAA sendNoteOffWithMAC ${ch} $n $v $mac recorders= $recorders")
    sendNoteOff(ch, n, v)
  }

  public fun wand_sendNoteOn(ch: Int, n: Int, v: Int) {
    //println (" -> wand_sendNoteON ch $ch n $n v $v")
    val msg = ByteArray(3)
    msg[0] = (0x90 or ch).toByte()
    msg[1] = n.toByte()
    msg[2] = v.toByte()
    if ( midiBridge.engine != null) midiBridge.write(msg)
  }

  public fun wand_sendNoteOff(ch: Int, n: Int, v: Int) {
    //println (" -> wand_sendNoteOFF ch $ch n $n v $v stack:" + Exception().printStackTrace())
    val msg = ByteArray(3)
    msg[0] = (0x80 or ch).toByte()
    msg[1] = n.toByte()
    msg[2] = v.toByte()
    if (midiBridge.engine != null) midiBridge.write(msg)
  }

  public fun sendNoteOn(ch: Int, n: Int, v: Int) {
    //println (" -> noteON ch $ch n $n v $v")
    val msg = ByteArray(3)
    var _ch = ch
    var _v = v

    if(specialModes[_ch]?.get("mode") == 1){
      _ch += 1
      _v = wand_velocity - 10
    }

    msg[0] = (0x90 or _ch).toByte()
    msg[1] = n.toByte()
    msg[2] = _v.toByte()
    if ( midiBridge.engine != null) midiBridge.write(msg)
  }

  public fun sendNoteOff(ch: Int, n: Int, v: Int) {
    val msg = ByteArray(3)
    var _ch = ch
    if(specialModes[_ch]?.get("mode") == 1){
      _ch += 1
    }
    msg[0] = (0x80 or _ch).toByte()
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

  private fun scaleRotation(fromMin: Int, fromMax: Int, toMin: Int, toMax: Int, value: Int) : Int {
    val x = if (value > fromMin) {value - fromMin} else 0
    val scaled: Double = toMin.toDouble() + x.toDouble()*(toMax.toDouble()-toMin.toDouble())/(fromMax-fromMin).toDouble()
    //println("scaleRotation fromMin=$fromMin fromMax=$fromMax toMin=$toMin toMax=$toMax v=$value x=$x scaled=$scaled" )
    return if (scaled.toInt() > toMax) toMax else scaled.toInt()
  }

  private fun scaleInclination(fromMin: Int, fromMax: Int, toMin: Int, toMax: Int, value:Int) : Int {
    if(value < fromMin){
      return toMin
    }
    val scaled: Double = toMin.toDouble() + (toMax-toMin).toDouble()*(value-fromMin).toDouble()/(fromMax-fromMin).toDouble()
    //println("scaleInclination fromMin=$fromMin fromMax=$fromMax toMin=$toMin toMax=$toMax v=$value scaled=$scaled ${noteToString(scaled.toInt())}" )
    return scaled.toInt()
  }

  fun MutableList<Int>.findClosest(input: Int) = fold(null) { acc: Int?, num ->
    val closest = if (num <= input && (acc == null || num > acc)) num else acc
    if (closest == input) return@findClosest closest else return@fold closest
  }

  fun getNote(ch: Int, notes: ArrayList<Int>) : Int? {
    if (movingWindowForChannel[ch].size == 0)
      return 0

    if (notes.size == 0)
      return 0

    println("getNote: ch $ch movingWindowForChannel[ch] ${movingWindowForChannel[ch]} notes $notes")
    val n = movingWindowForChannel[ch].sum() / movingWindowForChannel[ch].size
    println("getNote: ch $ch n $n ")
    return  notes.toMutableList().findClosest(n)
  }

  fun selectNote(note: Int, ch: Int, notes: ArrayList<Int>) : Int {
    val prev = movingWindowForChannel[ch].toList()
    movingWindowForChannel[ch].add(note)
    movingWindowForChannel.set(ch, movingWindowForChannel[ch].takeLast(movingWindowDepth).toMutableList())
    val closest = getNote(ch, notes)
    //print("d2=\(d2) -> n=\(n) notes=\(notes) => closest=\(closest)")
    /*if (prev != movingWindowForChannel[ch]) {
      println("movingWindowForChannel[$ch] = ${movingWindowForChannel[ch]} prev = $prev => n= $n -  closest = $closest");
    }
    */
    if( closest != null)
      return closest

    return 0
  }

  private fun noteToString(note:Int) : String{
    val o = note/12
    var nnames = listOf<String>("C","C#","D","D#","E","F","F#","G","G#","A","A#","B")
    val name = nnames[note % 12]
    return ""+name+""+o
  }

  // Send a midi message, 3 bytes
  fun sendMidi(m: Int, n: Int, v: Int) {
    //println ("AAAA sendMidi ${m} ${n} ${v} ")
    val ch = m and 0xf;
    val infos = specialModes[ch] //(channel : Int, mode: Int, notes:[Int], octaves: Int , time: Int, controller: Int)
    var _m : Int = m
    var _n : Int = n
    var _v : Int = v
    val velocity = 100
    var send = true

    if(infos?.get("mode") == 1) { //WAND mode
      if (m and 0xf0 == 0xb0){
        when (n) {
          52 -> { //rotation
            _m = m
            _n = 11;
            _v = scaleRotation(0, (127*0.6).toInt(), 0, (127*0.3).toInt(), v)
            //println("FlutterMidiSynthPlugin.kt sendMidi: scaledRotation: " + _v)

          }

          1 -> { /*inclination*/
            val notes: ArrayList<Int> = infos["notes"] as ArrayList<Int>;
            var note = 0;

            //use pitch bend to reach next note
            //val scaled = scaleInclination(34,94, 0, 127, v)
            var min = notes.toList().minOrNull()
            var max = notes.toList().maxOrNull()
            if (min == null) { min = 0 }
            if (max == null) { max = 127 }
            var scaled = 0

            //se è continuous uso direttamente il valore v ricevuto
            // per fare un bend all'interno del noteSpan settato con il CC 6
            var bend = 0
            if (infos["continuous"] as Boolean) {
              //Pitch bend
              scaled = scaleInclination(0,115, 0, 127, v)
              note = (max + min) / 2
              bend = (scaled * 0x4000 / 127).toInt()
            } else {
              // Se è !continuous devo calcolare la distanza dalle note più vicine
              // e raggiungere il target con un bend manuale
              scaled = scaleInclination(0,115, min, max, v)
              note = selectNote(scaled.toInt(), ch, notes)
              val distance = (note - lastNoteForChannel[ch])
              val span = max - min //semitones span, including upper octave rootnote
              val pps = 16384.0/span
              bend = (distance*pps).toInt() + 8192
              //val calculated_note = lastNoteForChannel[ch] + ((bend - 8196)*(max-min))/16384
              println("FlutterMidiSynthPlugin => Quantized mode: note $note, lastNoteForChannel[ch] ${lastNoteForChannel[ch]}, distance $distance pps $pps => bend $bend d=${bend-8196}")
            }

            if (bend >= 16384){ bend = 16384 -1 }
            if (bend <= 0){ bend = 0 }

            //BackgroundThread impl
            if(true) {
              targetBendForChannel[ch] = bend
              send = false
            } else {
              _m = 0xE0 or ch
              _n = bend and 0x7f
              _v = (bend shr 7) and 0x7f
            }

            parent.sendMessage("WandNote", byteArrayOf(note.toByte())) //Send current note to UI

            //println("FlutterMidiSynthPlugin v $v  => bend $bend (" + (bend*100/0x4000) + "%) d1 " + _n  + " d2 " + _v)

            if(lastNoteForChannel[ch] != note){
              if (!(infos["continuous"] as Boolean) && lastNoteForChannel[ch] !=0) { //quantized
                //nothing to do
              } else {
                lastNoteForChannel[ch] = (max + min) / 2
                println("FlutterMidiSynthPlugin lastNoteForChannel[ch] != note sending new noteON for ${lastNoteForChannel[ch]}");
                wand_sendNoteOff(ch, 0, 0)
                wand_sendNoteOn(ch, lastNoteForChannel[ch], wand_velocity)
              }
            }

          }

          5 -> { //Portamento Time
            var map = specialModes[ch]?.toMutableMap()
            map?.set("time", v)
            specialModes[ch] = HashMap(map)
          }
        }
      }
    }

    if(send) {
      val msg = ByteArray(3)
      msg[0] = _m.toByte()
      msg[1] = _n.toByte()
      msg[2] = _v.toByte()
      if (midiBridge.engine != null) midiBridge.write(msg)
    }

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
      if (classroom){
        println("CLASSROOM - programchange FILTERED - n=" + n )
      } else {
        val pos = allowedInstrumentsIndexes.indexOf(n)
        println("programchange detected - n=" + n + " pos=" + pos + " expression=" + allowedInstrumentsExpressions[pos])
        expressions[mac!!] = allowedInstrumentsExpressions[pos]
      }
    }

    sendMidi(m + ch, n, vel)
  }

  fun setSpan(channel: Int, notes: MutableList<Int>, symmetric: Boolean): Int{
    var max = notes.toList().maxOrNull()
    var min = notes.toList().minOrNull()
    if (max == null){
      max = 127
    }
    if (min == null){
      min = 0
    }
    val span = max - min //semitones span
    val pps = 16384.0/span
    println("setSpan: ch $channel notes $notes symmetric $symmetric => span $span pps $pps")
    //Setup Pitch Bend Range
    //CC101 set value 0
    //CC100 set value 0
    //CC6 set value for pb range (eg 12 for 12 semitones up / down)
    sendMidi((0xB0 or channel),  101, 0) //Set Pitch Bend Range RPN
    sendMidi((0xB0 or channel),  100, 0) //Set Pitch Bend Range RPN
    sendMidi((0xB0 or channel),  6, span/2)  //Set Entry Value
    sendMidi((0xB0 or channel),  101, 127) //RPN Null
    sendMidi((0xB0 or channel),  100, 127) //RPN Null
    return span
  }

  fun setSpecialMode(args: HashMap<String, *>, channel: Int, mode: Int, notes: MutableList<Int>, continuous: kotlin.Boolean, time: Int, controller: Int, muted: Boolean) {

    val prev_mode = specialModes[channel]?.get("mode")
    val prev_continuous = specialModes[channel]?.get("continuous")
    if(prev_mode != mode || !continuous){
      println("prev_mode=$prev_mode mode=$mode continuous=$continuous")
      lastNoteForChannel[channel] = 0
    }

    sendMidi((0xB0 or channel),  123, 0) //ALL NOTES OFF

    specialModes[channel] = args

    //println("setSpecialMode ch="+channel+" mode="+mode+" notes?"+notes+" continuous="+continuous+" time="+time+" controller="+controller+" muted="+muted);

    if (/*continuous &&*/ mode == 1){  //mode 1 is WAND Mode
      if(backgroundBendTaskIsRunning == false){
        GlobalScope.async {
          backgroundBendTaskIsRunning = true
          backgroundBendTask()
        }
      }

      val span = setSpan(channel, notes, true);
      //println("setSpecialMode: span=$span")

      // Enable/Disable portamento - mode 1 is WAND Mode
      //sendMidi((0xB0 or channel),  65, if (mode == 1) 127 else 0)
      //sendMidi((0xB0 or channel),  5, time) //Portamento time (CC5)
      //sendMidi((0xB0 or channel),  84, controller) //Portamento Controller (CC84) TEST = 64

      //println("prev_mode=" + prev_mode + " mode=" + mode + " continuous=" + continuous)
      if(continuous || prev_continuous != continuous){ //must send a new NoteON in continous mode
        println("setSpecialMode: sending noteOn - channel=" + channel + " lastNote=" + lastNoteForChannel[channel])
        wand_sendNoteOn(channel, lastNoteForChannel[channel], wand_velocity)
      } else if (!continuous){
        println("setSpecialMode: sending noteOff - channel=" + channel)
        wand_sendNoteOff(channel, 0, 0);
      }

      sendMidi((0xB0 or channel), 7, if(muted) 0 else 127)

    } else {
      // Enable/Disable portamento - mode 1 is WAND Mode
      //sendMidi((0xB0 or channel), 65, if (mode == 1) 127 else 0) //Portamento ON/OFF
      //sendMidi((0xB0 or channel), 5, time) //Portamento time (CC5)
      //sendMidi((0xB0 or channel), 84, controller) //Portamento Controller (CC84) TEST = 64
      backgroundBendTaskIsRunning = false
    }
  }

  fun hasSpecialModeWAND(channel: Int) : Boolean {
    val infos = specialModes[channel]
    return infos?.get("mode") == 1
  }

}
