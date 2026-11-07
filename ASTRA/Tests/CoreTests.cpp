#include "../Core/AstroCore.hpp"
#include <random>
#include <fstream>
#include <iostream>
#include <filesystem>
#include <stdexcept>
#include <cmath>
using namespace astra;
static void check(bool ok,const std::string& msg){if(!ok)throw std::runtime_error(msg);}
static void save(const std::string& p,const std::vector<float>& v){std::ofstream f(p,std::ios::binary);f.write((const char*)v.data(),v.size()*4);}
static std::vector<float> load(const std::string& p,int w,int h){std::vector<float> v(size_t(w)*h*4);std::ifstream f(p,std::ios::binary);f.read((char*)v.data(),v.size()*4);return v;}
int main(int argc,char** argv) {
    std::string dir=argc>1?argv[1]:"/tmp/astra-core-tests";std::filesystem::create_directories(dir);
    try {
        std::mt19937 gen(41);std::uniform_real_distribution<double> xy(35,470);Analysis a,b;
        Transform truth;truth.a=1.002*std::cos(.13);truth.b=1.002*std::sin(.13);truth.tx=12.4;truth.ty=-9.2;
        std::normal_distribution<double> perturb(0,.08);
        for(int i=0;i<65;i++){Star s{xy(gen),xy(gen),100.0-i,1.5};a.stars.push_back(s);if(i%7)b.stars.push_back({truth.a*s.x-truth.b*s.y+truth.tx+perturb(gen),truth.b*s.x+truth.a*s.y+truth.ty+perturb(gen),s.flux,1.5});}
        for(int i=0;i<18;i++)b.stars.push_back({xy(gen),xy(gen),15.0-i*.1,1.5});
        auto t=align(a,b);check(t.matches>=50&&std::abs(t.tx-truth.tx)<.1&&std::abs(t.ty-truth.ty)<.1&&t.rms<.2,"rotation/scale/translation alignment with missing stars and outliers");
        std::cout<<"PASS star matching: "<<t.matches<<" inliers, "<<t.rms<<" px RMS\n";
        double scale=.19,offset=(scale-1)/2;auto lifted=liftToFullResolution(truth,scale);
        double fx=1400.3,fy=2200.8,px=scale*fx+offset,py=scale*fy+offset;
        double sourceX=(truth.a*px-truth.b*py+truth.tx-offset)/scale,sourceY=(truth.b*px+truth.a*py+truth.ty-offset)/scale;
        check(std::abs(lifted.a*fx-lifted.b*fy+lifted.tx-sourceX)<1e-9&&std::abs(lifted.b*fx+lifted.a*fy+lifted.ty-sourceY)<1e-9,"pixel-center transform lift");
        std::cout<<"PASS full-resolution pixel-center mapping\n";
        Analysis unrelated;for(int i=0;i<60;i++)unrelated.stars.push_back({xy(gen),xy(gen),70.0-i,1.5});bool rejected=false;
        try{align(a,unrelated);}catch(...){rejected=true;}check(rejected,"unrelated frame rejection");
        std::cout<<"PASS unrelated frame rejection\n";
        const int aw=512,ah=512;std::vector<float> image(size_t(aw)*ah*4);std::normal_distribution<float> noise(0,.0008);
        for(size_t p=0;p<image.size()/4;p++){float v=.01f+noise(gen);for(int c=0;c<3;c++)image[p*4+c]=v;image[p*4+3]=1;}
        for(int i=0;i<45;i++){double sx=xy(gen),sy=xy(gen);for(int y=int(sy)-5;y<=int(sy)+5;y++)for(int x=int(sx)-5;x<=int(sx)+5;x++)for(int c=0;c<3;c++)image[(size_t(y)*aw+x)*4+c]+=.2f*std::exp(-((x-sx)*(x-sx)+(y-sy)*(y-sy))/2.0);}
        image[(200*aw+250)*4]=50;image[(200*aw+250)*4+1]=50;image[(200*aw+250)*4+2]=50;
        auto detected=analyze(image.data(),aw,ah);check(detected.stars.size()>=30&&detected.stars.size()<60,"Gaussian star detection/hot pixel rejection");
        auto sky=analyze(image.data(),aw,ah,.4);for(auto s:sky.stars)check(s.y>ah*.6,"sky region restricts detection");
        std::cout<<"PASS detector: "<<detected.stars.size()<<" stars and manual sky region\n";
        // Integrated regression: detect stars in real float rasters, register,
        // bilinearly resample, stack, then measure recovered star positions.
        std::vector<Star> field;for(int i=0;i<35;i++)field.push_back({xy(gen),xy(gen),.5-double(i)*.006,1.3});
        std::vector<Input> integrated;Analysis reference;
        for(int frame=0;frame<7;frame++) {
            double angle=frame*.003;Transform motion;motion.a=std::cos(angle);motion.b=std::sin(angle);motion.tx=frame*1.31;motion.ty=-frame*.87;
            std::vector<float> im(size_t(aw)*ah*4);
            for(size_t p=0;p<im.size()/4;p++){float value=.02f+noise(gen);for(int c=0;c<3;c++)im[p*4+c]=value;im[p*4+3]=1;}
            for(auto s:field){double sx=motion.a*s.x-motion.b*s.y+motion.tx,sy=motion.b*s.x+motion.a*s.y+motion.ty;for(int y=int(sy)-5;y<=int(sy)+5;y++)for(int x=int(sx)-5;x<=int(sx)+5;x++)if(x>=0&&y>=0&&x<aw&&y<ah)for(int c=0;c<3;c++)im[(size_t(y)*aw+x)*4+c]+=float(s.flux*std::exp(-((x-sx)*(x-sx)+(y-sy)*(y-sy))/(2*s.radius*s.radius)));}
            auto detectedFrame=analyze(im.data(),aw,ah);Transform measured;
            if(frame==0)reference=detectedFrame;else measured=align(reference,detectedFrame);
            auto path=dir+"/integrated"+std::to_string(frame);save(path,im);integrated.push_back({path,measured,1});
        }
        Settings integratedConfig;std::atomic<bool> integratedCancel(false);
        stack(integrated,aw,ah,integratedConfig,dir+"/integrated-result",integratedCancel,[](double){});
        auto integratedImage=load(dir+"/integrated-result",aw,ah);auto stackedStars=analyze(integratedImage.data(),aw,ah);auto measuredFinal=align(reference,stackedStars);
        check(std::abs(measuredFinal.tx)<.15&&std::abs(measuredFinal.ty)<.15&&measuredFinal.rms<.18,"full pixel pipeline preserves star centroids");
        std::cout<<"PASS integrated detection -> registration -> pixel stack: "<<measuredFinal.rms<<" px RMS\n";
        int w=96,h=80;std::vector<Input> ins;std::normal_distribution<float> n(0,.02);double inputVar=0;
        for(int f=0;f<15;f++){std::vector<float> v(size_t(w)*h*4);for(int p=0;p<w*h;p++){float delta=n(gen);inputVar+=delta*delta;for(int c=0;c<3;c++)v[p*4+c]=.25f+delta;v[p*4+3]=1;}if(f==3)for(int c=0;c<3;c++)v[(30*w+40)*4+c]=8;std::string p=dir+"/f"+std::to_string(f);save(p,v);ins.push_back({p,{},1});}
        Settings cfg;std::atomic<bool> cancel(false);double progress=0;std::string output=dir+"/result";
        stack(ins,w,h,cfg,output,cancel,[&](double p){check(p>=progress,"monotonic progress");progress=p;});auto result=load(output,w,h);double variance=0,mean=0;
        for(int p=0;p<w*h;p++){variance+=std::pow(result[p*4]-.25,2);mean+=result[p*4];check(result[p*4+3]==1,"valid coverage");}
        double ratio=std::sqrt(variance/(w*h))/std::sqrt(inputVar/(15*w*h));check(ratio<.4&&std::abs(result[(30*w+40)*4]-.25)<.05,"noise reduction and sigma rejection");
        std::cout<<"PASS real pixel stack: noise ratio "<<ratio<<", outlier="<<result[(30*w+40)*4]<<"\n";
        cfg.mode=Mode::trails;stack(ins,w,h,cfg,dir+"/trails",cancel,[](double){});auto trail=load(dir+"/trails",w,h);check(trail[(30*w+40)*4]==8,"trails maximum blend");std::cout<<"PASS trails maximum\n";
        // A +3 pixel reference->source shift must sample source x+3, not x-3.
        std::vector<Input> shifted;for(int f=0;f<5;f++){std::vector<float> v(size_t(w)*h*4,1);for(int y=0;y<h;y++)for(int x=0;x<w;x++)for(int c=0;c<3;c++)v[(y*w+x)*4+c]=float(x-f)/w;auto p=dir+"/s"+std::to_string(f);save(p,v);Transform tr;tr.tx=f;shifted.push_back({p,tr,1});}
        cfg.mode=Mode::sky;stack(shifted,w,h,cfg,dir+"/shift",cancel,[](double){});auto sh=load(dir+"/shift",w,h);check(std::abs(sh[(40*w+30)*4]-30.0/w)<1e-6,"warp direction");check(sh[(40*w+w-1)*4+3]==0,"partial coverage alpha");
        cfg.mode=Mode::landscape;cfg.skyFraction=.5;cfg.feather=.05;stack(shifted,w,h,cfg,dir+"/land",cancel,[](double){});auto land=load(dir+"/land",w,h);check(std::abs(land[(70*w+30)*4]-30.0/w)<1e-6&&std::abs(land[(5*w+30)*4]-28.0/w)<1e-6,"separate sky and foreground blend");std::cout<<"PASS warp direction, edge alpha, independent landscape\n";
        auto before=load(output,w,h);cancel.store(true);rejected=false;try{stack(ins,w,h,cfg,output,cancel,[](double){});}catch(...){rejected=true;}check(rejected&&load(output,w,h)==before&&!std::filesystem::exists(output+".partial"),"atomic cancellation preserves previous result");std::cout<<"PASS cancellation and atomic output\n";
        cancel.store(false);auto corrupt=ins;corrupt[0].path=dir+"/missing";rejected=false;try{stack(corrupt,w,h,cfg,output,cancel,[](double){});}catch(...){rejected=true;}check(rejected,"missing cache error");std::cout<<"PASS missing cache error\nALL CORE TESTS PASSED\n";return 0;
    }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}
}
