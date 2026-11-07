package com.astra.starrynight;

import android.graphics.Bitmap;

public final class NativeEngine {
    static { System.loadLibrary("astra"); }
    public interface Progress { void update(double fraction, String stage); }
    public static native void cacheBitmap(Bitmap image, String destination);
    public static native int[] cacheRaw(String source, String destination);
    public static native int stack(String[] caches, int width, int height, int mode,
                                   double skyFraction, String destination, Progress progress);
    public static native void render(String source, int width, int height, Bitmap destination,
                                     double exposure, double contrast, double saturation,
                                     double warmth, double[] wheels);
    public static native void cancel();
}
