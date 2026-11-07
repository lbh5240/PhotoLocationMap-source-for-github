package com.astra.starrynight;

import android.graphics.Bitmap;

public final class NativeEngine {
    static { System.loadLibrary("astra"); }
    public interface Progress { void update(double fraction, String stage); }
    public static native void cacheBitmap(Bitmap image, String destination);
    public static native int[] cacheRaw(String source, String destination);
    public static int stack(String[] caches, int width, int height, int mode,
                            double skyFraction, String destination, Progress progress) {
        return stackEnhanced(caches,width,height,mode,skyFraction,false,destination,progress);
    }
    public static native int stackEnhanced(String[] caches, int width, int height, int mode,
                                           double skyFraction, boolean hdrFusion, String destination, Progress progress);
    public static void render(String source, int width, int height, Bitmap destination,
                              double exposure, double contrast, double saturation,
                              double warmth, double[] wheels) {
        renderEnhanced(source,width,height,destination,exposure,contrast,saturation,warmth,wheels,new double[5],false);
    }
    public static native void renderEnhanced(String source, int width, int height, Bitmap destination,
                                              double exposure, double contrast, double saturation,
                                              double warmth, double[] wheels, double[] astro, boolean autoSTF);
    public static native void cancel();
}
