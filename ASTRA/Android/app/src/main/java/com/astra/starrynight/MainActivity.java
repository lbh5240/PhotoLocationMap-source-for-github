package com.astra.starrynight;

import android.app.*;
import android.os.*;
import android.content.*;
import android.database.Cursor;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.provider.MediaStore;
import android.provider.OpenableColumns;
import android.view.*;
import android.widget.*;
import androidx.core.content.FileProvider;
import java.io.*;
import java.nio.file.Files;
import java.util.*;
import java.util.concurrent.*;

public final class MainActivity extends Activity {
    private static final int PICK = 41;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final int ink = Color.rgb(8,11,20), accent = Color.rgb(165,172,255);
    private LinearLayout root, panel;
    private ImageView photo;
    private TextView status, heading;
    private ProgressBar progress;
    Button stackButton;
    volatile boolean busy;
    volatile Project project;
    private Button importButton, exportButton;
    private int section, range, previewGeneration;
    private Bitmap displayed;
    private Runnable pendingPreview;

    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(ink);getWindow().setNavigationBarColor(ink);
        root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL);root.setBackgroundColor(ink);
        root.setPadding(dp(16),dp(10),dp(16),dp(12));setContentView(root);
        root.setOnApplyWindowInsetsListener((view,insets)->{view.setPadding(dp(16),dp(10)+insets.getSystemWindowInsetTop(),dp(16),dp(12)+insets.getSystemWindowInsetBottom());return insets;});
        heading = text("ASTRA · 星野",22);root.addView(heading);
        LinearLayout navigation = row();
        navigation.addView(button("工程",this::chooseProject));navigation.addView(button("新建",this::newProject));
        navigation.addView(button("新手引导",this::showGuide));root.addView(navigation);
        photo = new ImageView(this);photo.setScaleType(ImageView.ScaleType.FIT_CENTER);photo.setBackgroundColor(Color.BLACK);
        root.addView(photo,new LinearLayout.LayoutParams(-1,0,1));
        status = text("从相册或文件导入一组星空照片",13);status.setPadding(0,dp(8),0,dp(8));root.addView(status);
        progress = new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);progress.setMax(1000);progress.setVisibility(View.GONE);root.addView(progress,new LinearLayout.LayoutParams(-1,dp(4)));
        LinearLayout tabs = row();String[] titles={"堆栈","调整","色轮"};
        for(int i=0;i<titles.length;i++){final int index=i;tabs.addView(button(titles[i],()->{if(!busy){section=index;showPanel();}}));}root.addView(tabs);
        ScrollView controls=new ScrollView(this);panel=new LinearLayout(this);panel.setOrientation(LinearLayout.VERTICAL);controls.addView(panel);root.addView(controls,new LinearLayout.LayoutParams(-1,dp(215)));
        LinearLayout actions=row();importButton=button("导入",this::chooseImport);stackButton=button("开始合成",this::startStack);exportButton=button("导出",this::export);
        actions.addView(importButton);actions.addView(stackButton);actions.addView(exportButton);root.addView(actions);
        try {
            File home=new File(getFilesDir(),"projects");home.mkdirs();
            String active=getPreferences(0).getString("active",null);
            project=active==null?Project.create(home):Project.open(new File(home,active));
            remember();showPanel();schedulePreview();
        }catch(Exception error){setStatus("工程加载失败，请点新建。"+error.getMessage());}
        if(!getPreferences(0).getBoolean("guided",false))showGuide();
    }
    private int dp(int value){return Math.round(value*getResources().getDisplayMetrics().density);}
    private TextView text(String value,int size){TextView v=new TextView(this);v.setText(value);v.setTextColor(Color.WHITE);v.setTextSize(size);return v;}
    private LinearLayout row(){LinearLayout view=new LinearLayout(this);view.setOrientation(LinearLayout.HORIZONTAL);view.setPadding(0,dp(4),0,dp(4));return view;}
    private Button button(String title,Runnable action){
        Button b=new Button(this);b.setText(title);b.setTextColor(accent);b.setTextSize(13);b.setAllCaps(false);
        GradientDrawable background=new GradientDrawable();background.setColor(0xff202638);background.setCornerRadius(dp(18));b.setBackground(background);
        LinearLayout.LayoutParams params=new LinearLayout.LayoutParams(0,dp(44),1);params.setMargins(dp(3),0,dp(3),0);b.setLayoutParams(params);b.setOnClickListener(v->action.run());return b;
    }
    private void setStatus(String value){status.setText(value);}
    private void begin(String value){busy=true;progress.setProgress(0);progress.setVisibility(View.VISIBLE);setStatus(value);importButton.setEnabled(false);exportButton.setEnabled(false);stackButton.setText("取消");}
    private void finish(){busy=false;progress.setVisibility(View.GONE);importButton.setEnabled(true);exportButton.setEnabled(true);stackButton.setText("开始合成");showPanel();}
    private void remember(){getPreferences(0).edit().putString("active",project.directory.getName()).apply();heading.setText("ASTRA · "+project.name);}
    private void save(){try{project.save();}catch(Exception e){setStatus("保存失败："+e.getMessage());}}
    private void newProject(){
        if(busy)return;
        try{project=Project.create(new File(getFilesDir(),"projects"));remember();photo.setImageDrawable(null);showPanel();setStatus("新工程已创建，请导入照片");}
        catch(Exception e){setStatus(e.getMessage());}
    }
    private void chooseProject(){
        if(busy)return;
        File[] folders=new File(getFilesDir(),"projects").listFiles(File::isDirectory);if(folders==null)return;
        ArrayList<Project> projects=new ArrayList<>();for(File folder:folders){try{projects.add(Project.open(folder));}catch(Exception ignored){}}
        String[] names=projects.stream().map(p->p.name+" · "+p.frames.size()+" 张").toArray(String[]::new);
        new AlertDialog.Builder(this).setTitle("选择工程").setItems(names,(d,i)->{project=projects.get(i);remember();showPanel();schedulePreview();setStatus(project.frames.size()+" 张照片");}).setNegativeButton("返回",null).show();
    }
    private void chooseImport(){
        if(busy||project==null)return;
        new AlertDialog.Builder(this).setTitle("导入照片").setItems(new String[]{"从手机相册选择","从文件选择（含 NEF）"},(dialog,index)->{
            Intent intent;
            if(index==0&&Build.VERSION.SDK_INT>=33){intent=new Intent(MediaStore.ACTION_PICK_IMAGES);intent.setType("image/*");intent.putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX,Math.min(100,MediaStore.getPickImagesMaxLimit()));}
            else {intent=new Intent(index==0?Intent.ACTION_GET_CONTENT:Intent.ACTION_OPEN_DOCUMENT);intent.setType(index==0?"image/*":"*/*");intent.addCategory(Intent.CATEGORY_OPENABLE);intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE,true);}
            startActivityForResult(intent,PICK);
        }).show();
    }
    @Override protected void onActivityResult(int request,int result,Intent data){
        super.onActivityResult(request,result,data);if(request!=PICK||result!=RESULT_OK||data==null)return;
        ArrayList<Uri> items=new ArrayList<>();if(data.getClipData()!=null){for(int i=0;i<data.getClipData().getItemCount();i++)items.add(data.getClipData().getItemAt(i).getUri());}
        else if(data.getData()!=null)items.add(data.getData());importSources(items);
    }
    void importSources(ArrayList<Uri> sources){
        if(busy||project==null||sources.isEmpty())return;Project target=project;begin("导入并解码照片");
        worker.execute(()->{
            ArrayList<Project.Frame> imported=new ArrayList<>();ArrayList<String> errors=new ArrayList<>();
            for(int i=0;i<sources.size();i++){
                Uri uri=sources.get(i);String name="Photo";File original=null,cache=null;
                try{
                    if("file".equals(uri.getScheme()))name=new File(uri.getPath()).getName();
                    else try(Cursor cursor=getContentResolver().query(uri,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)){if(cursor!=null&&cursor.moveToFirst())name=cursor.getString(0);}
                    String suffix=name.contains(".")?name.substring(name.lastIndexOf('.')).toLowerCase(Locale.ROOT):"";
                    String id=UUID.randomUUID().toString();original=target.file(id+suffix);cache=target.file(id+".rgba");
                    try(InputStream input=getContentResolver().openInputStream(uri)){if(input==null)throw new IOException("无法读取文件");Files.copy(input,original.toPath());}
                    int width,height;
                    if(Arrays.asList(".nef",".dng",".arw",".cr2",".cr3",".nrw").contains(suffix)){
                        int[] size=NativeEngine.cacheRaw(original.getPath(),cache.getPath());width=size[0];height=size[1];
                    }else{
                        Bitmap decoded=ImageDecoder.decodeBitmap(ImageDecoder.createSource(original),(decoder,info,source)->{decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB));});
                        Bitmap image=decoded.getConfig()==Bitmap.Config.ARGB_8888?decoded:decoded.copy(Bitmap.Config.ARGB_8888,false);
                        width=image.getWidth();height=image.getHeight();NativeEngine.cacheBitmap(image,cache.getPath());image.recycle();if(image!=decoded)decoded.recycle();
                    }
                    Project.Frame frame=new Project.Frame();frame.original=original.getName();frame.cache=cache.getName();frame.name=name;frame.width=width;frame.height=height;imported.add(frame);
                }catch(Exception|OutOfMemoryError error){errors.add(name+"："+error.getMessage());if(original!=null)original.delete();if(cache!=null)cache.delete();}
                final int done=i+1;runOnUiThread(()->{progress.setProgress(done*1000/sources.size());setStatus("导入 "+done+" / "+sources.size());});
            }
            try{target.frames.addAll(imported);target.save();runOnUiThread(()->{finish();setStatus("已导入 "+imported.size()+" 张"+(errors.isEmpty()?"":"，失败 "+errors.size()+" 张\n"+errors.get(0)));schedulePreview();});}
            catch(Exception error){target.frames.removeAll(imported);for(Project.Frame frame:imported){target.file(frame.original).delete();target.file(frame.cache).delete();}runOnUiThread(()->{finish();setStatus("保存导入失败："+error.getMessage());});}
        });
    }
    private void showPanel(){
        panel.removeAllViews();if(project==null)return;
        if(section==0){
            RadioGroup modes=new RadioGroup(this);modes.setOrientation(LinearLayout.HORIZONTAL);
            String[] labels={"星空对齐","星野地景","星轨"};for(int i=0;i<3;i++){RadioButton radio=new RadioButton(this);radio.setText(labels[i]);radio.setTextColor(Color.WHITE);radio.setTextSize(12);radio.setId(100+i);modes.addView(radio);}
            modes.check(100+project.mode);modes.setOnCheckedChangeListener((g,id)->{if(!busy){project.mode=id-100;save();}});panel.addView(modes);
            slider("天空高度（星野模式）",project.sky,.15,1,value->{project.sky=value;save();});
            Button frames=button("管理照片 · "+project.frames.size()+" 张",this::manageFrames);panel.addView(frames,new LinearLayout.LayoutParams(-1,dp(44)));
            panel.addView(text("选同一片天空、相同尺寸的照片。星野模式适用于平坦地平线，至少两张可对齐照片才能合成。",12));
        }else if(section==1){
            slider("曝光 EV",project.exposure,-5,5,v->{project.exposure=v;save();schedulePreview();});
            slider("对比度",project.contrast,.5,1.8,v->{project.contrast=v;save();schedulePreview();});
            slider("饱和度",project.saturation,0,2,v->{project.saturation=v;save();schedulePreview();});
            slider("冷暖",project.warmth,-1,1,v->{project.warmth=v;save();schedulePreview();});
        }else{
            LinearLayout ranges=row();String[] labels={"阴影","中间调","高光"};for(int i=0;i<3;i++){final int selected=i;ranges.addView(button(labels[i],()->{range=selected;showPanel();}));}panel.addView(ranges);
            WheelView wheel=new WheelView(this);wheel.x=project.wheels[range*3];wheel.y=project.wheels[range*3+1];wheel.listener=(x,y)->{if(!busy){project.wheels[range*3]=x;project.wheels[range*3+1]=y;save();schedulePreview();}};
            LinearLayout.LayoutParams layout=new LinearLayout.LayoutParams(dp(125),dp(125));layout.gravity=Gravity.CENTER_HORIZONTAL;panel.addView(wheel,layout);
            slider(labels[range]+"亮度",project.wheels[range*3+2],-1,1,v->{project.wheels[range*3+2]=v;save();schedulePreview();});
            panel.addView(button("重置当前色轮",()->{for(int i=0;i<3;i++)project.wheels[range*3+i]=0;save();showPanel();schedulePreview();}),new LinearLayout.LayoutParams(-1,dp(44)));
        }
    }
    interface Adjustment {void set(double value);}
    private void slider(String name,double value,double low,double high,Adjustment update){
        TextView label=text(name+String.format(Locale.ROOT,"  %.2f",value),12);panel.addView(label);SeekBar bar=new SeekBar(this);bar.setMax(1000);bar.setProgress((int)((value-low)/(high-low)*1000));
        bar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener(){public void onStartTrackingTouch(SeekBar b){}public void onStopTrackingTouch(SeekBar b){}public void onProgressChanged(SeekBar b,int position,boolean user){if(user&&!busy){double v=low+(high-low)*position/1000;label.setText(name+String.format(Locale.ROOT,"  %.2f",v));update.set(v);}}});panel.addView(bar);
    }
    private void manageFrames(){
        if(busy)return;String[] names=project.frames.stream().map(f->f.name+" · "+f.width+"×"+f.height).toArray(String[]::new);boolean[] selected=new boolean[names.length];for(int i=0;i<selected.length;i++)selected[i]=project.frames.get(i).included;
        new AlertDialog.Builder(this).setTitle("参与合成的照片").setMultiChoiceItems(names,selected,(d,i,on)->project.frames.get(i).included=on).setPositiveButton("完成",(d,i)->save()).show();
    }
    void startStack(){
        if(busy){NativeEngine.cancel();setStatus("正在安全停止…");return;}if(project==null)return;
        ArrayList<Project.Frame> selected=new ArrayList<>();for(Project.Frame f:project.frames)if(f.included)selected.add(f);
        if(selected.size()<2){setStatus("无法合成。请在照片列表选择至少两张照片。");return;}
        int width=selected.get(0).width,height=selected.get(0).height;
        for(Project.Frame frame:selected)if(frame.width!=width||frame.height!=height){setStatus("无法合成。照片尺寸不同，请排除裁切或方向不同的照片。");return;}
        Project target=project;String master="Master-"+UUID.randomUUID()+".rgba";int mode=target.mode;double sky=target.sky;
        String[] caches=selected.stream().map(f->target.file(f.cache).getPath()).toArray(String[]::new);begin("准备合成");
        worker.execute(()->{
            try{
                int count=NativeEngine.stack(caches,width,height,mode,sky,target.file(master).getPath(),(value,stage)->runOnUiThread(()->{progress.setProgress((int)(value*1000));setStatus(stage+" "+(int)(value*100)+"%");}));
                String old=target.master;target.master=master;target.width=width;target.height=height;target.accepted=count;
                try{target.save();}catch(Exception error){target.master=old;target.file(master).delete();throw error;}
                if(old!=null)target.file(old).delete();runOnUiThread(()->{finish();setStatus("合成完成 · "+count+" 帧 · "+width+"×"+height+"\n可以继续调色或导出");schedulePreview();});
            }catch(Exception|OutOfMemoryError error){runOnUiThread(()->{finish();setStatus("合成失败 · "+error.getMessage());});}
        });
    }
    private void schedulePreview(){
        if(project==null||project.frames.isEmpty())return;
        if(pendingPreview!=null)main.removeCallbacks(pendingPreview);int generation=++previewGeneration;
        Project target=project;String path=target.master;int width=target.width,height=target.height;
        if(path==null){Project.Frame f=target.frames.get(0);path=f.cache;width=f.width;height=f.height;}
        final String file=target.file(path).getPath();final int w=width,h=height;
        double exposure=target.exposure,contrast=target.contrast,saturation=target.saturation,warmth=target.warmth;double[] wheels=target.wheels.clone();
        pendingPreview=()->worker.execute(()->{
            if(generation!=previewGeneration)return;
            try{double scale=Math.min(1,1280.0/Math.max(w,h));Bitmap bitmap=Bitmap.createBitmap(Math.max(1,(int)(w*scale)),Math.max(1,(int)(h*scale)),Bitmap.Config.ARGB_8888);
                NativeEngine.render(file,w,h,bitmap,exposure,contrast,saturation,warmth,wheels);
                runOnUiThread(()->{if(generation!=previewGeneration){bitmap.recycle();return;}Bitmap old=displayed;displayed=bitmap;photo.setImageBitmap(bitmap);if(old!=null)old.recycle();});
            }catch(Exception|OutOfMemoryError error){runOnUiThread(()->setStatus("预览失败："+error.getMessage()));}
        });main.postDelayed(pendingPreview,130);
    }
    private void export(){
        if(busy||project==null||project.frames.isEmpty())return;
        new AlertDialog.Builder(this).setTitle("全分辨率导出").setItems(new String[]{"JPEG · 分享","PNG · 无损"},(d,index)->{
            Project target=project;begin("导出全分辨率图片");worker.execute(()->{
                try{
                    String path=target.master;int w=target.width,h=target.height;if(path==null){Project.Frame f=target.frames.get(0);path=f.cache;w=f.width;h=f.height;}
                    Bitmap output=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888);NativeEngine.render(target.file(path).getPath(),w,h,output,target.exposure,target.contrast,target.saturation,target.warmth,target.wheels);
                    File file=target.file("ASTRA-"+UUID.randomUUID()+(index==0?".jpg":".png"));
                    try(OutputStream stream=new FileOutputStream(file)){if(!output.compress(index==0?Bitmap.CompressFormat.JPEG:Bitmap.CompressFormat.PNG,96,stream))throw new IOException("编码失败");}finally{output.recycle();}
                    runOnUiThread(()->{finish();setStatus("已导出全分辨率成片");Uri uri=FileProvider.getUriForFile(this,"com.astra.starrynight.files",file);Intent share=new Intent(Intent.ACTION_SEND).setType(index==0?"image/jpeg":"image/png").putExtra(Intent.EXTRA_STREAM,uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);startActivity(Intent.createChooser(share,"分享成片"));});
                }catch(Exception|OutOfMemoryError error){runOnUiThread(()->{finish();setStatus("导出失败："+error.getMessage());});}
            });
        }).show();
    }
    private void showGuide(){
        String[] titles={"导入照片","选择堆栈模式","调整与色轮","导出成片"};
        String[] content={"从导入入口选择手机相册，或从文件选择 NEF。单张可以调色，多帧建议保持机位、焦距和曝光一致。", "星空对齐会匹配星点并剔除无法对齐的帧。星野地景需要设置水平天空分界。星轨使用最大值合成。失败原因会显示在画面下方。", "先调曝光、对比度和饱和度。色轮可分别调整阴影、中间调和高光，拖动方向选颜色，距中心越远强度越高。", "导出支持全分辨率 JPEG 和 PNG，工程会在本机保存。原始 NEF 通过 LibRaw 解码，不同机型和压缩类型可能有兼容差异。"};
        showGuidePage(0,titles,content);
    }
    private void showGuidePage(int page,String[] titles,String[] content){
        new AlertDialog.Builder(this).setTitle((page+1)+" / 4 · "+titles[page]).setMessage(content[page]).setNegativeButton("跳过",(d,i)->getPreferences(0).edit().putBoolean("guided",true).apply()).setPositiveButton(page==3?"开始使用":"下一步",(d,i)->{if(page<3)showGuidePage(page+1,titles,content);else getPreferences(0).edit().putBoolean("guided",true).apply();}).show();
    }
}
