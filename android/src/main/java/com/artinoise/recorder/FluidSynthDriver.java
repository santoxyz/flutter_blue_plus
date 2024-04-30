package com.artinoise.recorder;
import android.util.Log;


public class FluidSynthDriver extends DriverBase
{
    static
    {
        Log.i("FluidSynthDriver","loading native-lib");
        System.loadLibrary("native-lib"); //fluidSynth
    }

    public FluidSynthDriver()
    {
    }

    public void start()
    {
        Log.i("FluidSynthDriver","start() invoked");
        init();
    }

    public void stop()
    {

        Log.i("FluidSynthDriver","stop() invoked");

    }

    public native boolean init();

    public native boolean write(byte a[]);
    public native boolean setSF2(String path);

    public native void setDefaultStreamValues(int defaultSampleRate, int defaultFramesPerBurst);
    public native void setAudioPeriods(int audioPeriods, int audioPeriodSize);

    ///////////////////////
    //FLUID MEDIAPLAYER API
    ///////////////////////
    public native int MIDIPrepare(String filename, int ticksPerBeat);
    public native int MIDIPlay(boolean loopForever);
    public native int MIDIPause();
    public native int MIDIResume();
    public native int MIDIStop();
    public native int MIDIGetTotalTicks();
    public native double MIDIGetCurrentTick();
    public native int MIDIGetBpm();
    public native int MIDIGetTempo();
    public native int MIDIGetStatus();

    public native int MIDISetVolume(double v);
    public native int MIDISetTempo(double t);
    public native int MIDISetMetronomeVolume(double v);

}