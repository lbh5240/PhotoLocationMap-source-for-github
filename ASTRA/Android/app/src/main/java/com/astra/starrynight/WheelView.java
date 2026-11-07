package com.astra.starrynight;

import android.content.Context;
import android.graphics.*;
import android.view.MotionEvent;
import android.view.View;

final class WheelView extends View {
    interface Listener { void changed(double x, double y); }
    double x, y;
    Listener listener;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    WheelView(Context context) { super(context); setContentDescription("拖动色轮选择颜色，距中心越远强度越高"); }
    @Override protected void onDraw(Canvas canvas) {
        float cx = getWidth()/2f, cy = getHeight()/2f, radius = Math.min(cx, cy)-8;
        paint.setShader(new SweepGradient(cx,cy,new int[]{Color.RED,Color.YELLOW,Color.GREEN,Color.CYAN,Color.BLUE,Color.MAGENTA,Color.RED},null));
        canvas.drawCircle(cx,cy,radius,paint);
        paint.setShader(new RadialGradient(cx,cy,radius,new int[]{0xff737373,0x00737373},null,Shader.TileMode.CLAMP));
        canvas.drawCircle(cx,cy,radius,paint);
        paint.setShader(null);paint.setColor(Color.WHITE);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(3);
        canvas.drawCircle(cx+(float)x*radius*.9f,cy+(float)y*radius*.9f,8,paint);paint.setStyle(Paint.Style.FILL);
    }
    @Override public boolean onTouchEvent(MotionEvent event) {
        if (!isEnabled()) return false;
        float radius = Math.min(getWidth(),getHeight())/2f-8;
        double px=(event.getX()-getWidth()/2f)/(radius*.9), py=(event.getY()-getHeight()/2f)/(radius*.9);
        double length=Math.max(1,Math.hypot(px,py));
        if(event.getAction()==MotionEvent.ACTION_DOWN||event.getAction()==MotionEvent.ACTION_MOVE){
            getParent().requestDisallowInterceptTouchEvent(true);x=px/length;y=py/length;
            if(listener!=null)listener.changed(x,y);invalidate();return true;
        }
        if(event.getAction()==MotionEvent.ACTION_UP){getParent().requestDisallowInterceptTouchEvent(false);performClick();return true;}
        return true;
    }
    @Override public boolean performClick(){super.performClick();return true;}
}
