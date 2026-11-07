#include <jni.h>
#include <android/bitmap.h>
#include <libraw/libraw.h>
#include "AstroCore.hpp"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <stdexcept>
#include <vector>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

namespace {
std::atomic<bool> cancelled(false);
struct Text {
    JNIEnv* env; jstring text; const char* value;
    Text(JNIEnv* e,jstring s):env(e),text(s),value(e->GetStringUTFChars(s,nullptr)){}
    ~Text(){env->ReleaseStringUTFChars(text,value);}
};
void fail(JNIEnv* env,const std::exception& error){env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),error.what());}
float linear(float v){return v<=.04045f?v/12.92f:std::pow((v+.055f)/1.055f,2.4f);}
float srgb(float v){v=std::max(0.f,v);return v<=.0031308f?v*12.92f:1.055f*std::pow(v,1.f/2.4f)-.055f;}
struct Mapped {
    int fd=-1;size_t size;float* data;
    Mapped(const char* path,int w,int h):size(size_t(w)*h*16),data(nullptr){
        fd=open(path,O_RDONLY);struct stat st{};
        if(fd<0||fstat(fd,&st)||size_t(st.st_size)!=size){if(fd>=0)close(fd);fd=-1;throw std::runtime_error("图像缓存缺失或损坏，请重新导入");}
        data=(float*)mmap(nullptr,size,PROT_READ,MAP_PRIVATE,fd,0);
        if(data==MAP_FAILED){close(fd);fd=-1;throw std::runtime_error("无法映射图像缓存");}
    }
    ~Mapped(){if(fd>=0){munmap(data,size);close(fd);}}
};
struct Pixels {
    JNIEnv* env;jobject image;void* data=nullptr;AndroidBitmapInfo info{};
    Pixels(JNIEnv* e,jobject b):env(e),image(b){
        if(AndroidBitmap_getInfo(env,image,&info)!=0||info.format!=ANDROID_BITMAP_FORMAT_RGBA_8888||AndroidBitmap_lockPixels(env,image,&data)!=0)
            throw std::runtime_error("无法访问图像像素");
    }
    ~Pixels(){if(data)AndroidBitmap_unlockPixels(env,image);}
};
void commit(std::ofstream& output,const std::string& temp,const char* dest){
    output.flush();if(!output)throw std::runtime_error("写入失败，请检查存储空间");output.close();
    if(rename(temp.c_str(),dest))throw std::runtime_error("无法保存图像缓存");
}
double smooth(double low,double high,double x){double t=std::clamp((x-low)/(high-low),0.0,1.0);return t*t*(3-2*t);}
}
extern "C" JNIEXPORT void JNICALL Java_com_astra_starrynight_NativeEngine_cacheBitmap(JNIEnv* env,jclass,jobject bitmap,jstring path){
    Text dest(env,path);std::string temp=std::string(dest.value)+".partial";
    try{
        Pixels pixels(env,bitmap);int w=pixels.info.width,h=pixels.info.height;
        std::ofstream output(temp,std::ios::binary);std::vector<float> row(size_t(w)*4);
        for(int y=h-1;y>=0;y--){auto src=(unsigned char*)pixels.data+size_t(y)*pixels.info.stride;
            for(int x=0;x<w;x++){for(int c=0;c<3;c++)row[x*4+c]=linear(src[x*4+c]/255.f);row[x*4+3]=src[x*4+3]/255.f;}
            output.write((const char*)row.data(),row.size()*4);
        }commit(output,temp,dest.value);
    }catch(const std::exception& e){unlink(temp.c_str());fail(env,e);}
}
extern "C" JNIEXPORT jintArray JNICALL Java_com_astra_starrynight_NativeEngine_cacheRaw(JNIEnv* env,jclass,jstring source,jstring path){
    Text input(env,source),dest(env,path);std::string temp=std::string(dest.value)+".partial";
    try{
        LibRaw raw;int code=raw.open_file(input.value);if(code)throw std::runtime_error(std::string("RAW 打开失败：")+libraw_strerror(code));
        raw.imgdata.params.output_bps=16;raw.imgdata.params.output_color=1;
        raw.imgdata.params.gamm[0]=1;raw.imgdata.params.gamm[1]=1;
        raw.imgdata.params.no_auto_bright=1;raw.imgdata.params.use_camera_wb=1;
        code=raw.unpack();if(code)throw std::runtime_error(std::string("RAW 解码失败：")+libraw_strerror(code));
        code=raw.dcraw_process();if(code)throw std::runtime_error(std::string("RAW 处理失败：")+libraw_strerror(code));
        libraw_processed_image_t* image=raw.dcraw_make_mem_image(&code);
        if(!image||code)throw std::runtime_error("RAW 输出失败");
        if(image->bits!=16||image->colors!=3||image->type!=LIBRAW_IMAGE_BITMAP){LibRaw::dcraw_clear_mem(image);throw std::runtime_error("不支持此 RAW 输出格式");}
        int w=image->width,h=image->height;auto src=(unsigned short*)image->data;
        std::ofstream output(temp,std::ios::binary);std::vector<float> row(size_t(w)*4);
        for(int y=h-1;y>=0;y--){for(int x=0;x<w;x++){for(int c=0;c<3;c++)row[x*4+c]=src[(size_t(y)*w+x)*3+c]/65535.f;row[x*4+3]=1;}output.write((const char*)row.data(),row.size()*4);}
        LibRaw::dcraw_clear_mem(image);commit(output,temp,dest.value);
        jint dims[2]={w,h};jintArray result=env->NewIntArray(2);env->SetIntArrayRegion(result,0,2,dims);return result;
    }catch(const std::exception& e){unlink(temp.c_str());fail(env,e);return nullptr;}
}
extern "C" JNIEXPORT jint JNICALL Java_com_astra_starrynight_NativeEngine_stack(JNIEnv* env,jclass,jobjectArray paths,jint w,jint h,jint mode,jdouble sky,jstring path,jobject callback){
    Text dest(env,path);cancelled.store(false);
    try{
        int count=env->GetArrayLength(paths);if(count<2)throw std::runtime_error("请至少选择两张照片");
        std::vector<std::string> names;std::vector<astra::Analysis> analyses;
        double scale=std::min(1.0,1600.0/std::max(w,h));int pw=int(w*scale),ph=int(h*scale);
        jclass cls=env->GetObjectClass(callback);jmethodID update=env->GetMethodID(cls,"update","(DLjava/lang/String;)V");
        auto progress=[&](double value,const char* label){jstring text=env->NewStringUTF(label);env->CallVoidMethod(callback,update,value,text);env->DeleteLocalRef(text);};
        for(int i=0;i<count;i++){
            if(cancelled.load())throw std::runtime_error("合成已取消");
            jstring item=(jstring)env->GetObjectArrayElement(paths,i);Text name(env,item);names.emplace_back(name.value);
            Mapped input(name.value,w,h);std::vector<float> proxy(size_t(pw)*ph*4);
            for(int y=0;y<ph;y++)for(int x=0;x<pw;x++){int sx=std::min(w-1,int((x+.5)/scale)),sy=std::min(h-1,int((y+.5)/scale));std::copy_n(input.data+(size_t(sy)*w+sx)*4,4,proxy.data()+(size_t(y)*pw+x)*4);}
            analyses.push_back(astra::analyze(proxy.data(),pw,ph,mode==1?sky:1));progress(.3*(i+1)/count,"星点分析");
        }
        int reference=-1;for(int i=0;i<count;i++)if((mode==2||analyses[i].stars.size()>=8)&&(reference<0||analyses[i].quality>analyses[reference].quality))reference=i;
        if(reference<0)throw std::runtime_error("没有足够星点，请使用同一片天空的清晰照片，或检查天空分界");
        std::vector<astra::Input> inputs;
        for(int i=0;i<count;i++){
            if(cancelled.load())throw std::runtime_error("合成已取消");
            astra::Transform transform;
            try{if(i!=reference&&mode!=2)transform=astra::registerFrame(analyses[reference],analyses[i],scale,{names[reference],{},1},{names[i],{},1},w,h);}
            catch(const std::exception&){continue;}
            inputs.push_back({names[i],transform,std::max(.01,analyses[i].quality)});progress(.3+.15*(i+1)/count,"星点配准");
        }
        if(inputs.size()<2)throw std::runtime_error("成功对齐不足两张，请排除云层、拖尾或构图不同的照片");
        astra::Settings cfg;cfg.mode=(astra::Mode)mode;cfg.skyFraction=sky;
        astra::stack(inputs,w,h,cfg,dest.value,cancelled,[&](double v){progress(.45+.55*v,"合成真实像素");});
        return int(inputs.size());
    }catch(const std::exception& e){fail(env,e);return 0;}
}
extern "C" JNIEXPORT void JNICALL Java_com_astra_starrynight_NativeEngine_cancel(JNIEnv*,jclass){cancelled.store(true);}
extern "C" JNIEXPORT void JNICALL Java_com_astra_starrynight_NativeEngine_render(JNIEnv* env,jclass,jstring path,jint w,jint h,jobject bitmap,jdouble exposure,jdouble contrast,jdouble saturation,jdouble warmth,jdoubleArray grades){
    Text source(env,path);
    try{
        Mapped input(source.value,w,h);Pixels output(env,bitmap);double wheels[9]={};if(env->GetArrayLength(grades)==9)env->GetDoubleArrayRegion(grades,0,9,wheels);
        double shifts[3][3];for(int j=0;j<3;j++){double r=wheels[j*3],g=-.5*r+.8660254*wheels[j*3+1],b=-.5*r-.8660254*wheels[j*3+1];double l=.2126*r+.7152*g+.0722*b;shifts[j][0]=(r-l)*.18+wheels[j*3+2]*.18;shifts[j][1]=(g-l)*.18+wheels[j*3+2]*.18;shifts[j][2]=(b-l)*.18+wheels[j*3+2]*.18;}
        for(uint32_t y=0;y<output.info.height;y++){auto row=(unsigned char*)output.data+size_t(y)*output.info.stride;int sy=h-1-std::min(h-1,int((y+.5)*h/output.info.height));
            for(uint32_t x=0;x<output.info.width;x++){int sx=std::min(w-1,int((x+.5)*w/output.info.width));auto p=input.data+(size_t(sy)*w+sx)*4;double rgb[3];for(int c=0;c<3;c++)rgb[c]=(srgb(p[c]*std::pow(2.0,exposure))-.5)*contrast+.5;
                double l=.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2];for(int c=0;c<3;c++)rgb[c]=l+(rgb[c]-l)*saturation;
                rgb[0]+=warmth*.05;rgb[2]-=warmth*.05;double sw=1-smooth(.08,.56,l),hw=smooth(.44,.94,l),mw=std::max(0.0,1-sw-hw);
                for(int c=0;c<3;c++){rgb[c]+=sw*shifts[0][c]+mw*shifts[1][c]+hw*shifts[2][c];row[x*4+c]=(unsigned char)std::clamp(int(std::round(rgb[c]*255)),0,255);}row[x*4+3]=(unsigned char)std::clamp(int(p[3]*255),0,255);
            }
        }
    }catch(const std::exception& e){fail(env,e);}
}
