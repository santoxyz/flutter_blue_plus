package com.artinoise.recorder;

public class DriverBase {
    public DriverBase()
    {
    }
    protected void start(){}
    protected void stop(){}
    protected int[] config(){return null;}

    protected native boolean init();
    protected native boolean write(byte a[]);
}