package com.artinoise.recorder;

import androidx.collection.CircularArray;
import android.util.Log;

public class CircularFifoArray   {
    private CircularArray array;
    private int capacity;
    public CircularFifoArray(int capacity) {
        array = new CircularArray(capacity);
        this.capacity = capacity;
    }

    public void clear() { array.clear();}
    public Integer size() { return array.size();}
    public boolean isFull(){
        Log.i("isFull","array.size="+ array.size() + " capacity=" + capacity + " =>" + (array.size() == capacity));

        return array.size() == capacity;
    }

    public void add(Integer element) {
        if (isFull()) {
            array.removeFromStart(1);
        }
        array.addLast(element);
        Log.i("add","added element. Now array.size="+ array.size());

    }

    public Integer avg(){
        String s = "";
        Integer avg = 0;
        for(int i = 0 ; i<array.size(); i++){
            avg += (Integer) array.get(i);
            s += " " + (Integer) array.get(i);
        }
        Integer r = avg/array.size();
        s += " => r " + r;
        Log.i("Avg",s);
        return r;
    }

}
