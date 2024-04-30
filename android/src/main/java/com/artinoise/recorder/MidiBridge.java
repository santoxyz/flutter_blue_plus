package com.artinoise.recorder;

import android.content.Context;
import android.util.Log;

import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.content.pm.PackageManager;
import android.os.PowerManager;
import android.os.PowerManager.WakeLock;
import android.content.SharedPreferences;
import android.widget.Toast;

public class MidiBridge {
    private static String TAG = MidiBridge.class.getName().toString();

    private Context context;
    private WakeLock wakeLock;
    private DriverBase engine;

    public MidiBridge(Context context) {
        this.context = context;
    }

    public void init(Object listener) {
        PowerManager powerManager = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "MyWakelockTag");
        wakeLock.acquire();
        setFluidSynthEngine();
    }

    public DriverBase getEngine() {
        return engine;
    }

    public void setFluidSynthEngine() {
        String path = context.getApplicationContext().getDir("flutter", Context.MODE_PRIVATE).getPath();
        String sfPath = path + "/soundfont_GM.sf2";
        Log.i("MidiBridge", "setFluidSynthEngine sfPath=" + sfPath);

        engine = new FluidSynthDriver();

        boolean hasLowLatencyFeature = context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_AUDIO_LOW_LATENCY);
        boolean hasProFeature = context.getPackageManager().hasSystemFeature(PackageManager.FEATURE_AUDIO_PRO);
        Log.i("MidiBridge", "hasLowLatencyFeature=" + hasLowLatencyFeature + " hasProFeature=" + hasProFeature);

        int defaultSampleRate = -1;
        int defaultFramesPerBurst = -1;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
            AudioManager myAudioMgr = (AudioManager) context.getApplicationContext().getSystemService(Context.AUDIO_SERVICE);
            String sampleRateStr = myAudioMgr.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE);
            defaultSampleRate = Integer.parseInt(sampleRateStr);
            String framesPerBurstStr = myAudioMgr.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER);
            defaultFramesPerBurst = Integer.parseInt(framesPerBurstStr);
            Log.i("MidiBridge", "setting default stream values: sampleRate=" + defaultSampleRate + " framesPerBurst=" + defaultFramesPerBurst);

            ((FluidSynthDriver) engine).setDefaultStreamValues(defaultSampleRate, defaultFramesPerBurst);
        }
        SharedPreferences prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE);
        long selectedPerformance = prefs.getLong("flutter.selectedPerformance", 2); //high
        long selectedPerformance2 = prefs.getLong("flutter.selectedPerformance2", 0);
        int audioPeriods = selectedPerformance == 0 ? 16 //low
                : selectedPerformance == 1 ? 8 //mid
                : 2; //high
        int audioPeriodSize = selectedPerformance2 == 0 ? 0 : (int) (Math.pow(2, (selectedPerformance2)) * 64);
        if (audioPeriodSize == 0 && defaultFramesPerBurst > 0) {
            audioPeriodSize = defaultFramesPerBurst;
        }
        Log.i("MidiBridge", "selectedPerformance=" + selectedPerformance + " -> audioPeriods=" + audioPeriods);
        ((FluidSynthDriver) engine).setAudioPeriods(audioPeriods, audioPeriodSize);

        //Toast.makeText(context, "DeviceSampleRate=" + defaultSampleRate + " DeviceFramesPerBurst=" + defaultFramesPerBurst + " synthAudioPeriods=" + audioPeriods + " synthAudioPeriodSize=" + audioPeriodSize, Toast.LENGTH_LONG).show();


        engine.init();
        ((FluidSynthDriver) engine).setSF2(sfPath);
    }

    public void write(byte msg[]) {
        //Log.w("MidiBridge", "writing message to Synth engine... "+ CommonResources.bytesToHex(msg));
        if (engine == null) {
            Log.e("MidiBridge", "write: Engine not SET :( aborting..");
            return;
        }

        engine.write(msg);
    }

    public int[] config() {
        if (engine == null) {
            Log.e("MidiBridge", "write: Engine not SET :( aborting..");
            return null;
        }
        return engine.config();
    }

    public void stop() {
        if (engine == null) {
            Log.e("MidiBridge", "write: Engine not SET :( aborting..");
            return;
        }
        engine.stop();
        wakeLock.release();

        return;
    }

    public void start() {
        if (engine == null) {
            Log.e("MidiBridge", "write: Engine not SET :( aborting..");
            return;
        }
        engine.start();
        return;
    }


    ///////////////////////
    //FLUID MEDIAPLAYER API
    ///////////////////////

    private boolean isFluidsynthEngine() {
        if (engine == null) {
            Log.e("MidiBridge", "Engine not SET :( aborting..");
            return false;
        }

        if (engine instanceof FluidSynthDriver) {
            return true;
        }
        return false;
    }

    public int MIDIPrepare(String filename, int ticksPerBeat) {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIPrepare(filename,ticksPerBeat);
        }
        return -1;
    }

    public int MIDIPlay(boolean loopForever) {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIPlay(loopForever);
        }
        return -1;
    }

    public int MIDIResume() {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIResume();
        }
        return -1;
    }

    public int MIDIPause() {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIPause();
        }
        return -1;
    }

    public int MIDIStop() {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIStop();
        }
        return -1;
    }

    public int MIDIGetTotalTicks() {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIGetTotalTicks();
        }
        return -1;
    }

    public double MIDIGetCurrentTick() {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIGetCurrentTick();
        }
        return -1;
    }

    public int MIDIGetBpm() {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIGetBpm();
        }
        return -1;
    }

    public int MIDIGetTempo() {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIGetTempo();
        }
        return -1;
    }

    public int MIDIGetStatus() {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDIGetStatus();
        }
        return -1;
    }

    public int MIDISetVolume(double v) {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDISetVolume(v);
        }
        return -1;
    }

    public int MIDISetTempo(double v) {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDISetTempo(v);
        }
        return -1;
    }

    public int MIDISetMetronomeVolume(double v) {
        if (isFluidsynthEngine()) {
            return ((FluidSynthDriver)engine).MIDISetMetronomeVolume(v);
        }
        return -1;
    }
}