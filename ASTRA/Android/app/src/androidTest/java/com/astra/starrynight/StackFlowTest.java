package com.astra.starrynight;

import android.graphics.Bitmap;
import android.net.Uri;
import android.os.SystemClock;
import androidx.test.core.app.ActivityScenario;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

@RunWith(AndroidJUnit4.class)
public class StackFlowTest {
    @Test public void importedImagesCreateRealCombinedPixels() throws Exception {
        android.content.Context context=InstrumentationRegistry.getInstrumentation().getTargetContext();
        context.getSharedPreferences("MainActivity",0).edit().putBoolean("guided",true).commit();
        ArrayList<Uri> sources=fixtures(context,false);
        try(ActivityScenario<MainActivity> scenario=ActivityScenario.launch(MainActivity.class)){
            AtomicReference<MainActivity> activity=new AtomicReference<>();
            scenario.onActivity(a->{activity.set(a);a.importSources(sources);});
            waitUntilIdle(activity.get());
            assertEquals(3,activity.get().project.frames.size());
            scenario.onActivity(a->a.stackButton.performClick());
            waitUntilIdle(activity.get());
            Project p=activity.get().project;
            assertNotNull("Stack did not create a master",p.master);
            assertEquals(3,p.accepted);assertEquals(384,p.width);assertEquals(256,p.height);
            byte[] master=java.nio.file.Files.readAllBytes(p.file(p.master).toPath());
            assertEquals(384*256*16,master.length);
            for(Project.Frame frame:p.frames)assertFalse(Arrays.equals(master,java.nio.file.Files.readAllBytes(p.file(frame.cache).toPath())));
            Bitmap neutral=Bitmap.createBitmap(384,256,Bitmap.Config.ARGB_8888);
            Bitmap colored=Bitmap.createBitmap(384,256,Bitmap.Config.ARGB_8888);
            NativeEngine.render(p.file(p.master).getPath(),384,256,neutral,0,1,1,0,new double[9]);
            NativeEngine.render(p.file(p.master).getPath(),384,256,colored,0,1,1,0,new double[]{.6,.2,0,0,0,0,0,0,0});
            assertNotEquals(neutral.getPixel(10,10),colored.getPixel(10,10));
            File exported=p.file("verified-export.png");
            try(FileOutputStream out=new FileOutputStream(exported)){assertTrue(colored.compress(Bitmap.CompressFormat.PNG,100,out));}
            assertTrue(exported.length()>100);neutral.recycle();colored.recycle();
        }
    }
    @Test public void libRawDecodesTheCfaTestFile() throws Exception {
        android.content.Context context=InstrumentationRegistry.getInstrumentation().getTargetContext();
        File input=new File(context.getCacheDir(),"synthetic.dng"),output=new File(context.getCacheDir(),"raw-test.rgba");
        try(InputStream in=InstrumentationRegistry.getInstrumentation().getContext().getAssets().open("synthetic.dng");OutputStream out=new FileOutputStream(input)){in.transferTo(out);}
        int[] dimensions=NativeEngine.cacheRaw(input.getPath(),output.getPath());
        assertTrue(dimensions[0]>0&&dimensions[1]>0);
        assertEquals((long)dimensions[0]*dimensions[1]*16,output.length());
    }
    private static void waitUntilIdle(MainActivity activity) throws Exception {
        long deadline=SystemClock.elapsedRealtime()+45000;
        while(activity.busy&&SystemClock.elapsedRealtime()<deadline)Thread.sleep(60);
        assertFalse("Operation timed out",activity.busy);
    }
    private static ArrayList<Uri> fixtures(android.content.Context context,boolean mixed) throws Exception {
        Random random=new Random(41);int[][] stars=new int[42][2];
        for(int[] s:stars){s[0]=36+random.nextInt(300);s[1]=36+random.nextInt(176);}
        ArrayList<Uri> result=new ArrayList<>();
        for(int frame=0;frame<3;frame++){
            int width=384,height=mixed&&frame==2?240:256;int[] pixels=new int[width*height];
            for(int i=0;i<pixels.length;i++){int v=30+random.nextInt(12);pixels[i]=0xff000000|(v<<16)|(v<<8)|v;}
            for(int[] s:stars)for(int y=-4;y<=4;y++)for(int x=-4;x<=4;x++){
                int i=(s[1]+y-frame)*width+s[0]+x+frame*2;
                int value=Math.min(255,(pixels[i]&255)+(int)(195*Math.exp(-(x*x+y*y)/4.0)));
                pixels[i]=0xff000000|(value<<16)|(value<<8)|value;
            }
            Bitmap bitmap=Bitmap.createBitmap(pixels,width,height,Bitmap.Config.ARGB_8888);
            File file=new File(context.getCacheDir(),"Fixture-"+frame+".png");
            try(FileOutputStream out=new FileOutputStream(file)){bitmap.compress(Bitmap.CompressFormat.PNG,100,out);}bitmap.recycle();result.add(Uri.fromFile(file));
        }
        return result;
    }
}
