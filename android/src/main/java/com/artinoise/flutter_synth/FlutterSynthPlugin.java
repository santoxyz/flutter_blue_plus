// Copyright 2017-2023, Charles Weinberger & Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

package com.artinoise.flutter_synth;

import android.Manifest;
import android.annotation.TargetApi;
import android.app.Activity;
import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelUuid;
import android.util.Log;
import android.util.SparseArray;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.ConcurrentHashMap;
import java.io.StringWriter;
import java.io.PrintWriter;
import java.io.UnsupportedEncodingException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

import java.lang.reflect.Method;

import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.artinoise.ocarina.FlutterMidiSynthPlugin;
import com.artinoise.ocarina.CircularFifoArray;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.EventChannel.EventSink;
import io.flutter.plugin.common.EventChannel.StreamHandler;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener;
import io.flutter.plugin.common.PluginRegistry.ActivityResultListener;

public class FlutterSynthPlugin implements
    FlutterPlugin,
    MethodCallHandler,
    RequestPermissionsResultListener,
    ActivityResultListener,
    ActivityAware
{
    private static final String TAG = "[FBP-Android]";

    private LogLevel logLevel = LogLevel.DEBUG;

    private Context context;
    private MethodChannel methodChannel;
    private static final String NAMESPACE = "flutter_synth";

    private FlutterPluginBinding pluginBinding;
    private ActivityPluginBinding activityBinding;

    private int lastEventId = 1452;

    private int transpose = 0;
    private FlutterMidiSynthPlugin midiSynthPlugin = null;
    java.util.HashMap<Integer, CircularFifoArray> xpressionsMap=new HashMap<Integer,CircularFifoArray>(); //ch,List<values>

    public FlutterSynthPlugin() {}

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding flutterPluginBinding)
    {
        log(LogLevel.DEBUG, "onAttachedToEngine");

        pluginBinding = flutterPluginBinding;

        this.context = (Application) pluginBinding.getApplicationContext();

        methodChannel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), NAMESPACE + "/methods");
        methodChannel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding)
    {
        log(LogLevel.DEBUG, "onDetachedFromEngine");

        invokeMethodUIThread("OnDetachedFromEngine", new HashMap<>());

        pluginBinding = null;

        context = null;

        methodChannel.setMethodCallHandler(null);
        methodChannel = null;

    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding)
    {
        log(LogLevel.DEBUG, "onAttachedToActivity");
        activityBinding = binding;
        activityBinding.addRequestPermissionsResultListener(this);
        activityBinding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges()
    {
        log(LogLevel.DEBUG, "onDetachedFromActivityForConfigChanges");
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding)
    {
        log(LogLevel.DEBUG, "onReattachedToActivityForConfigChanges");
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity()
    {
        log(LogLevel.DEBUG, "onDetachedFromActivity");
        activityBinding.removeRequestPermissionsResultListener(this);
        activityBinding = null;
    }

    ////////////////////////////////////////////////////////////
    // ███    ███  ███████  ████████  ██   ██   ██████   ██████
    // ████  ████  ██          ██     ██   ██  ██    ██  ██   ██
    // ██ ████ ██  █████       ██     ███████  ██    ██  ██   ██
    // ██  ██  ██  ██          ██     ██   ██  ██    ██  ██   ██
    // ██      ██  ███████     ██     ██   ██   ██████   ██████
    //
    //  ██████   █████   ██       ██
    // ██       ██   ██  ██       ██
    // ██       ███████  ██       ██
    // ██       ██   ██  ██       ██
    //  ██████  ██   ██  ███████  ███████

    @Override
    @SuppressWarnings({"deprecation", "unchecked"}) // needed for compatibility, type safety uses bluetooth_msgs.dart
    public void onMethodCall(@NonNull MethodCall call,
                                 @NonNull Result result)
    {
        try {
            //og(LogLevel.DEBUG, "onMethodCall: " + call.method);

            switch (call.method) {

                case "setLogLevel":
                {
                    int idx = (int)call.arguments;

                    // set global var
                    logLevel = LogLevel.values()[idx];

                    result.success(true);
                    break;
                }

                //Transpose:
                case "transpose":
                    transpose = call.arguments();
                    break;

                ///FlutterMidiSynthPlugin
                case "initSynth":
                case "setInstrument":
                case "noteOn":
                case "noteOff":
                case "midiEvent":
                case "setReverb":
                case "setDelay":
                case "initAudioSession":
                case "setAllowedInstrumentsIndexes":
                case "MIDIPrepare":
                case "MIDIPlay":
                case "MIDIPause":
                case "MIDIResume":
                case "MIDIStop":
                case "MIDIGetTotalTicks":
                case "MIDIGetCurrentTick":
                case "MIDIGetBpm":
                case "MIDIGetTempo":
                case "MIDIGetStatus":

                case "MIDISetVolume":
                case "MIDISetTempo":
                case "MIDISetMetronomeVolume":
                case "setSpecialMode":
                    if (midiSynthPlugin == null){
                        midiSynthPlugin = new FlutterMidiSynthPlugin(context, this);
                    }
                    midiSynthPlugin.manageMethodCall(call,result);
                    break;
                ///FINE FlutterMidiSynthPlugin

                default:
                {
                    result.notImplemented();
                    break;
                }
            }
        } catch (Exception e) {
            StringWriter sw = new StringWriter();
            PrintWriter pw = new PrintWriter(sw);
            e.printStackTrace(pw);
            String stackTrace = sw.toString();
            result.error("androidException", e.toString(), stackTrace);
            return;
        }
    }

    public void sendMessage(final String name, final byte[] byteArray)
    {
        HashMap<String, Object> map = new HashMap<>();
        map.put(name, byteArray);
        invokeMethodUIThread(name, map);
    }

   //////////////////////////////////////////////////////////////////////
   //  █████    ██████  ████████  ██  ██    ██  ██  ████████  ██    ██ 
   // ██   ██  ██          ██     ██  ██    ██  ██     ██      ██  ██  
   // ███████  ██          ██     ██  ██    ██  ██     ██       ████   
   // ██   ██  ██          ██     ██   ██  ██   ██     ██        ██    
   // ██   ██   ██████     ██     ██    ████    ██     ██        ██    
   // 
   // ██████   ███████  ███████  ██    ██  ██       ████████ 
   // ██   ██  ██       ██       ██    ██  ██          ██    
   // ██████   █████    ███████  ██    ██  ██          ██    
   // ██   ██  ██            ██  ██    ██  ██          ██    
   // ██   ██  ███████  ███████   ██████   ███████     ██    

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data)
    {
        return false; // did not handle anything
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // ██████   ███████  ██████   ███    ███  ██  ███████  ███████  ██   ██████   ███    ██
    // ██   ██  ██       ██   ██  ████  ████  ██  ██       ██       ██  ██    ██  ████   ██
    // ██████   █████    ██████   ██ ████ ██  ██  ███████  ███████  ██  ██    ██  ██ ██  ██
    // ██       ██       ██   ██  ██  ██  ██  ██       ██       ██  ██  ██    ██  ██  ██ ██
    // ██       ███████  ██   ██  ██      ██  ██  ███████  ███████  ██   ██████   ██   ████

    @Override
    public boolean onRequestPermissionsResult(int requestCode,
                                         String[] permissions,
                                            int[] grantResults)
    {
        return false; // did not handle anything
    }

    //////////////////////////////////////////
    // ██    ██ ████████  ██  ██       ███████
    // ██    ██    ██     ██  ██       ██
    // ██    ██    ██     ██  ██       ███████
    // ██    ██    ██     ██  ██            ██
    //  ██████     ██     ██  ███████  ███████

    private void log(LogLevel level, String message)
    {
        if(level.ordinal() > logLevel.ordinal()) {
            return;
        }
        switch(level) {
            case DEBUG:
                Log.d(TAG, "[FSP] " + message);
                break;
            case WARNING:
                Log.w(TAG, "[FSP] " + message);
                break;
            case ERROR:
                Log.e(TAG, "[FSP] " + message);
                break;
            default:
                Log.d(TAG, "[FSP] " + message);
                break;
        }
    }

    private void invokeMethodUIThread(final String method, HashMap<String, Object> data)
    {
        new Handler(Looper.getMainLooper()).post(() -> {
            //Could already be teared down at this moment
            if (methodChannel != null) {
                methodChannel.invokeMethod(method, data);
            } else {
                log(LogLevel.WARNING, "invokeMethodUIThread: tried to call method on closed channel: " + method);
            }
        });
    }

    private static byte[] hexToBytes(String s) {
        if (s == null) {
            return new byte[0];
        }
        int len = s.length();
        byte[] data = new byte[len / 2];

        for (int i = 0; i < len; i += 2) {
            data[i / 2] = (byte) ((Character.digit(s.charAt(i), 16) << 4)
                                + Character.digit(s.charAt(i+1), 16));
        }

        return data;
    }

    private static String bytesToHex(byte[] bytes) {
        if (bytes == null) {
            return "";
        }
        StringBuilder sb = new StringBuilder();
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }

    enum LogLevel
    {
        NONE,    // 0
        ERROR,   // 1
        WARNING, // 2
        INFO,    // 3
        DEBUG,   // 4
        VERBOSE  // 5
    }

    private boolean isSysex(byte[] data){
        if(data.length -2 < 6){
            return false;
        }

        final byte[] header = {(byte)0xf0,(byte)0x0,(byte)0x2f,(byte)0x7f,(byte)0x0,(byte)0x1};
        byte[] hdr = {data[2],data[3],data[4],data[5],data[6],data[7]};

        if (data[data.length-1] == (byte)0x7f && Arrays.equals(hdr,header)){
            return true;
        }
        return false;
    }

    private ArrayList<byte[]> parseMidiMessages(byte[] data){

        ArrayList<byte[]> ret = new ArrayList<byte[]>();

        if (data.length > 11) {
            if(isSysex(data))
                return ret;
        }

        //Se non è un sysex, procedo nel processare il pacchetto.
        final int STATE_HDR = 0;
        final int STATE_TS = 1;
        final int STATE_ST = 2;
        final int STATE_D1 = 3;
        final int STATE_D2 = 4;

        int state = STATE_HDR;

        byte status = 0;
        byte channel = 0;
        byte d1 = -1;
        byte d2 = -1;

        for (int i = 0; i < data.length; i++) {
            byte b = data[i];
            //Log.i(TAG, "[parseMidiMessages] state: " + state + " status=" + bytesToHex(new byte[]{status}) + " channel=" + channel +
            //        " d1=" + bytesToHex(new byte[]{d1}) + " d2=" + bytesToHex(new byte[]{d2}));
            switch (state) {
                case STATE_HDR:
                    state = STATE_TS;
                    continue;
                case STATE_TS:
                    state = STATE_ST;
                    continue;
                case STATE_ST:
                    status = (byte)(b & 0xf0);
                    channel = (byte)(b & 0x0f);
                    state = STATE_D1;
                    continue;
                case STATE_D1:
                    d1 = b;
                    if (status < (byte)(0xc0) || status > (byte)(0xe0)) {
                        //Log.i(TAG, "status=" + bytesToHex(new byte[]{status}) + " going to STATE_D2");
                        state = STATE_D2;
                    } else {
                        //PRGM_CHANGE e AFTER_TOUCH hanno un solo byte di informazione
                        //Log.i(TAG, "adding MIDI msg containing only d1 byte");
                        ret.add(new byte[]{status,channel,d1,d2});
                        status = channel = 0;
                        d1 = d2 = -1;
                        state = STATE_TS;
                    }
                    continue;
                case STATE_D2:
                    d2 = b;
                    //Log.i(TAG, "adding MIDI msg containing d1 and d2 byte");
                    ret.add(new byte[]{status,channel,d1,d2});
                    status = channel = 0;
                    d1 = d2 = -1;
                    state = STATE_TS;
                    continue;

                default:
                    Log.w(TAG, "you should never reach this state!");
                    break;
            }
        }

        return ret;
    }

    private void directMidiMessageManager(byte[] data) {
        String mac = "de:ad:be:ef:00:00";
        //byte[] data = characteristic.getValue();
        ArrayList<byte[]> messages = parseMidiMessages(data);
        //Log.i(TAG, "[directMidiMessageManager] uuid: " + characteristic.getUuid().toString()
        //        + " data=" + bytesToHex(data) + " messages=" + messages);
        if (messages != null && messages.size()>0){
            for (byte[] m : messages) {
                //Log.i(TAG, " processing message " + bytesToHex(m));

                byte status = m[0];
                byte ch = m[1];
                byte d1 = m[2];
                byte d2 = m[3];


                boolean filter_accel = true;
                if(!midiSynthPlugin.hasSpecialModeWAND(ch)){ /*in WAND mode let the rotation CC pass*/
                    filter_accel &= (d1 != 52);
                }
                filter_accel &= (d1 != 53); /*filtering accelerometer y an z*/


                if (status == (byte)0x90 /*noteON*/ ||
                        status == (byte)0x80 /*noteOFF*/ ||
                        (status >= (byte)0xb0 /*CC*/ && status < (byte)0xc0 /*PrgChg*/ && filter_accel /*filtering accelerometer y and z*/) ||
                        (status >= (byte)0xc0 /*PrgChg*/ && status < (byte)0xd0 /*ChPressure*/) ||
                        (status >= (byte)0xd0 /*ChPressure*/ && status < (byte)0xe0 /*bender*/)
                ){
                    switch (status){
                        case (byte) 0x90: //noteon
                            midiSynthPlugin.sendNoteOnWithMAC(d1+transpose,d2,mac);
                            break;
                        case (byte) 0x80: //noteoff
                            if (!midiSynthPlugin.hasSpecialModeWAND(ch)) {
                                CircularFifoArray xpressions = xpressionsMap.get((int) ch);
                                if (xpressions != null) {
                                    xpressions.clear();
                                }
                            }
                            midiSynthPlugin.sendNoteOffWithMAC(d1+transpose,d2,mac);
                            break;

                        case (byte) 0xC0: //Program Change
                            Log.i(TAG, "[directMidiMessageManager] : "
                                    + " PROGRAM CHANGE - ch="+ch+" status="+ status + " d1=" + d1 + " d2=" + d2 + "(ignored) mac=" + mac);
                            midiSynthPlugin.sendMidiWithMAC(ch|status,d1,0,mac);
                            break;

                        case (byte) 0xB0:
                            if(d1==11) {
                                if(midiSynthPlugin.hasSpecialModeWAND(ch)) {
                                    Log.i(TAG, "WAND MODE: ignoring expression on ch=" + ch);
                                    break; //ignore Expression
                                }
                                //d2 = xpressionAvg(ch,d2);
                                d2 = xpressionScale(25,110,d2);
                            }
                            /*
                            case (byte) 0xB0:
                                if(d1==01) {
                                    break; //ignore Modulation Wheel
                                }
                                //ATTENZIONE NON C'E' IL BREAK!
                            case (byte) 0xD0: //aftertouch
                                status = (byte)0xB0;
                                final int c = 60;
                                double v = c + ((127.0f-c)*d1)/127.0f;
                                d2=(byte)(int)v;
                                d1=11;
                                //break; ATTENZIONE NON C'E' IL BREAK!

                             */

                        default:
                            midiSynthPlugin.sendMidiWithMAC(ch|status,d1,d2,mac);
                    }
                } else {
                    if(d1==52 && status==-80){
                        //Log.i(TAG, "rotation d1="+d1);
                    } else {
                        Log.i(TAG, "[directMidiMessageManager] : "
                                + " FILTERED msg ch=" + ch + " status=" + status + " d1=" + d1 + " d2=" + d2 + " mac=" + mac);
                    }
                }

            }
        }
    }

    private byte xpressionScale(int min, int max, byte v) {
        double scaled = min + (max-min)*v/127.0f;
        //Log.d("xpressionScale", " v=" + v + " scaled=" + scaled );
        return (byte)(int)scaled;
    }

    private byte xpressionAvg(byte ch, byte v){
        CircularFifoArray xpressions = xpressionsMap.get((int) ch);
        Log.i("xpressionAvg", " ch=" + ch + " xpressions=" + xpressions );
        if(xpressions == null){
            xpressions = new CircularFifoArray(30);
        }
        xpressions.add((int) v);
        xpressionsMap.put((int) ch,xpressions);

        return (byte) (xpressions.avg() & 0xff);
    }


}
