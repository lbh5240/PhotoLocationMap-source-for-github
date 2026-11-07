#include "AstroCore.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <numeric>
#include <limits>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <cstdint>
#include <cstdio>

namespace astra {
namespace {
double median(std::vector<double> v) {
    if(v.empty()) return 0;
    auto m=v.begin()+v.size()/2;
    std::nth_element(v.begin(), m, v.end()); return *m;
}
double dist(const Star& a,const Star& b) {return std::hypot(a.x-b.x,a.y-b.y);}
std::pair<double,double> map(const Transform& t,double x,double y) {
    return {t.a*x-t.b*y+t.tx,t.b*x+t.a*y+t.ty};
}
struct Match {int r,s;};
std::vector<Match> match(const std::vector<Star>& r,const std::vector<Star>& s,const Transform& t,double threshold) {
    std::vector<Match> out; std::vector<bool> used(s.size());
    for(size_t i=0;i<r.size();i++) {
        auto p=map(t,r[i].x,r[i].y); double best=threshold*threshold; int k=-1;
        for(size_t j=0;j<s.size();j++) if(!used[j]) {
            double dx=p.first-s[j].x,dy=p.second-s[j].y,d=dx*dx+dy*dy;
            if(d<best) { best=d;k=int(j); }
        }
        if(k>=0) {used[k]=true;out.push_back({int(i),k});}
    } return out;
}
Transform fit(const std::vector<Star>& r,const std::vector<Star>& s,const std::vector<Match>& pairs) {
    double rx=0,ry=0,sx=0,sy=0;
    for(auto m:pairs) {rx+=r[m.r].x;ry+=r[m.r].y;sx+=s[m.s].x;sy+=s[m.s].y;}
    double n=pairs.size();rx/=n;ry/=n;sx/=n;sy/=n;
    double den=0,real=0,imag=0;
    for(auto m:pairs) {double x=r[m.r].x-rx,y=r[m.r].y-ry,u=s[m.s].x-sx,v=s[m.s].y-sy;
        den+=x*x+y*y;real+=x*u+y*v;imag+=x*v-y*u;}
    if(den<1e-9) throw std::runtime_error("Degenerate star geometry");
    Transform t; t.a=real/den;t.b=imag/den;t.tx=sx-t.a*rx+t.b*ry;t.ty=sy-t.b*rx-t.a*ry;
    t.matches=int(pairs.size());double sq=0;
    for(auto m:pairs) {auto p=map(t,r[m.r].x,r[m.r].y);sq+=std::pow(p.first-s[m.s].x,2)+std::pow(p.second-s[m.s].y,2);}
    t.rms=std::sqrt(sq/n);return t;
}
struct Triangle {double x,y;std::array<int,3> ids;};
std::vector<Triangle> triangles(const std::vector<Star>& s) {
    std::vector<Triangle> out; int count=std::min(28,int(s.size()));
    for(int i=0;i<count;i++) for(int j=i+1;j<count;j++) for(int k=j+1;k<count;k++) {
        std::array<std::pair<double,int>,3> edges={{{dist(s[j],s[k]),i},{dist(s[i],s[k]),j},{dist(s[i],s[j]),k}}};
        std::sort(edges.begin(),edges.end());
        if(edges[0].first<12||edges[2].first<35) continue;
        double cross=std::abs((s[j].x-s[i].x)*(s[k].y-s[i].y)-(s[j].y-s[i].y)*(s[k].x-s[i].x));
        if(cross/(edges[2].first*edges[2].first)<0.06) continue;
        out.push_back({edges[0].first/edges[2].first,edges[1].first/edges[2].first,{edges[0].second,edges[1].second,edges[2].second}});
    }
    std::sort(out.begin(),out.end(),[](auto& a,auto& b){return a.x<b.x;}); return out;
}
struct File {
    int fd=-1; size_t bytes;
    explicit File(const std::string& p,size_t n):bytes(n) {
        fd=open(p.c_str(),O_RDONLY);
        struct stat st{};
        if(fd<0||fstat(fd,&st)||uint64_t(st.st_size)!=uint64_t(n)) {
            if(fd>=0)close(fd);
            fd=-1;throw std::runtime_error("Invalid or missing float cache: "+p);
        }
    }
    ~File(){if(fd>=0)close(fd);}
    File(const File&)=delete;File& operator=(const File&)=delete;
    File(File&& o) noexcept:fd(o.fd),bytes(o.bytes){o.fd=-1;}
};
float unpackHalf(uint16_t value) {
    static const auto table=[] {
        std::array<float, 65536> values{};
        for(size_t i=0;i<values.size();i++) {
            const int exponent=(i>>10)&31, fraction=i&1023;
            float number;
            if(exponent==0) number=std::ldexp(float(fraction),-24);
            else if(exponent==31) number=fraction ? std::numeric_limits<float>::quiet_NaN() : std::numeric_limits<float>::infinity();
            else number=std::ldexp(float(1024+fraction),exponent-25);
            values[i]=(i&32768)?-number:number;
        }
        return values;
    }();
    return table[value];
}
struct Window {
    void* ptr=MAP_FAILED;size_t len=0;const char* data=nullptr;int first,last,width;bool half;
    Window(int fd,int w,int h,int y0,int y1,bool useHalf):first(std::clamp(y0,0,h-1)),last(std::clamp(y1,0,h-1)),width(w),half(useHalf) {
        if(last<first)std::swap(first,last);
        const size_t pixelBytes=half?8:16;
        size_t start=size_t(first)*w*pixelBytes, end=size_t(last+1)*w*pixelBytes;
        size_t page=size_t(sysconf(_SC_PAGESIZE)),base=(start/page)*page;
        len=end-base;ptr=mmap(nullptr,len,PROT_READ,MAP_PRIVATE,fd,off_t(base));
        if(ptr==MAP_FAILED)throw std::runtime_error("Cannot map cache window");
        data=static_cast<const char*>(ptr)+(start-base);
    }
    ~Window(){if(ptr!=MAP_FAILED)munmap(ptr,len);}
    bool sample(int h,double x,double y,float* out) const {
        if(!std::isfinite(x)||!std::isfinite(y)||x<0||y<0||x>width-1||y>h-1)return false;
        int x0=int(x),y0=int(y),x1=std::min(x0+1,width-1),y1=std::min(y0+1,h-1);
        if(y0<first||y1>last)return false;
        double fx=x-x0,fy=y-y0;
        for(int c=0;c<3;c++) {
            auto at=[&](int px,int py){const auto index=(size_t(py-first)*width+px)*4+c;return half ? unpackHalf(reinterpret_cast<const uint16_t*>(data)[index]) : reinterpret_cast<const float*>(data)[index];};
            out[c]=float((1-fy)*((1-fx)*at(x0,y0)+fx*at(x1,y0))+fy*((1-fx)*at(x0,y1)+fx*at(x1,y1)));
            if(!std::isfinite(out[c]))return false;
        } return true;
    }
};
void writeAll(int fd,const void* data,size_t n) {
    const char* p=static_cast<const char*>(data);
    while(n) {ssize_t r=write(fd,p,n);if(r<0&&errno==EINTR)continue;if(r<=0)throw std::runtime_error("Cannot write result (storage full?)");p+=r;n-=size_t(r);}
}
}

Analysis analyze(const float* rgba,int w,int h,double skyFraction) {
    if(!rgba||w<16||h<16||!std::isfinite(skyFraction)||skyFraction<=0||skyFraction>1)throw std::runtime_error("Invalid analysis input");
    std::vector<double> lum(size_t(w)*h),samples;
    int minY=std::clamp(int(h*(1-skyFraction)),0,h-1);
    for(int y=0;y<h;y++)for(int x=0;x<w;x++) {
        size_t p=size_t(y)*w+x;double l=0.2126*rgba[p*4]+0.7152*rgba[p*4+1]+0.0722*rgba[p*4+2];
        lum[p]=std::isfinite(l)?l:0;if(y>=minY&&x%7==0&&y%7==0)samples.push_back(lum[p]);
    }
    Analysis a;a.background=median(samples);for(auto& v:samples)v=std::abs(v-a.background);
    a.noise=std::max(1e-7,1.4826*median(samples));
    std::vector<Star> candidates;
    for(int y=std::max(minY+5,5);y<h-5;y++)for(int x=5;x<w-5;x++) {
        double peak=lum[size_t(y)*w+x];if(peak<a.background+6*a.noise)continue;
        bool maximum=true;
        for(int dy=-2;dy<=2&&maximum;dy++)for(int dx=-2;dx<=2;dx++) if((dx||dy)&&lum[size_t(y+dy)*w+x+dx]>=peak){maximum=false;break;}
        if(!maximum)continue;
        std::vector<double> ring;for(int dy=-5;dy<=5;dy++)for(int dx=-5;dx<=5;dx++)if(std::abs(dx)>=4||std::abs(dy)>=4)ring.push_back(lum[size_t(y+dy)*w+x+dx]);
        double bg=median(ring),mass=0,cx=0,cy=0;
        if(peak-bg<6*a.noise)continue;
        for(int dy=-3;dy<=3;dy++)for(int dx=-3;dx<=3;dx++) {double v=std::max(0.0,lum[size_t(y+dy)*w+x+dx]-bg);mass+=v;cx+=v*(x+dx);cy+=v*(y+dy);}
        if(mass<=0)continue;
        cx/=mass;cy/=mass;double xx=0,yy=0,xy=0;
        for(int dy=-3;dy<=3;dy++)for(int dx=-3;dx<=3;dx++) {double v=std::max(0.0,lum[size_t(y+dy)*w+x+dx]-bg),u=x+dx-cx,z=y+dy-cy;xx+=v*u*u;yy+=v*z*z;xy+=v*u*z;}
        xx/=mass;yy/=mass;xy/=mass;double d=std::hypot(xx-yy,2*xy),small=(xx+yy-d)*0.5,large=(xx+yy+d)*0.5;
        // Reject isolated hot pixels and strongly elongated detections.
        if(small<0.12||large>9||large/std::max(small,0.01)>4)continue;
        candidates.push_back({cx,cy,mass,std::sqrt(xx+yy)});
    }
    std::sort(candidates.begin(),candidates.end(),[](auto& l,auto& r){return l.flux>r.flux;});
    for(auto s:candidates) {bool near=false;for(auto t:a.stars)if(dist(s,t)<8){near=true;break;}if(!near)a.stars.push_back(s);if(a.stars.size()==160)break;}
    std::vector<double> radii;for(auto s:a.stars)radii.push_back(s.radius);
    a.quality=a.stars.empty()?0:std::sqrt(double(a.stars.size()))/std::max(0.1,median(radii));return a;
}

Transform align(const Analysis& ref,const Analysis& src) {
    if(ref.stars.size()<8||src.stars.size()<8)throw std::runtime_error("Fewer than 8 usable stars; adjust sky region or exclude frame");
    auto rt=triangles(ref.stars),st=triangles(src.stars);Transform best;int bestCount=0;double bestRMS=1e9;
    for(auto& r:rt) {
        auto begin=std::lower_bound(st.begin(),st.end(),r.x-0.004,[](auto& t,double x){return t.x<x;});
        for(auto it=begin;it!=st.end()&&it->x<r.x+0.004;it++) {
            if(std::abs(it->y-r.y)>0.004)continue;
            std::vector<Match> seed;for(int i=0;i<3;i++)seed.push_back({r.ids[i],it->ids[i]});
            Transform t=fit(ref.stars,src.stars,seed);double scale=std::hypot(t.a,t.b);
            if(scale<0.94||scale>1.06||t.rms>1.5)continue;
            auto matches=match(ref.stars,src.stars,t,2.5);
            if(int(matches.size())<bestCount||matches.size()<8)continue;
            t=fit(ref.stars,src.stars,matches);matches=match(ref.stars,src.stars,t,1.8);
            if(matches.size()<8)continue;
            t=fit(ref.stars,src.stars,matches);
            if(int(matches.size())>bestCount||(int(matches.size())==bestCount&&t.rms<bestRMS)){best=t;bestCount=int(matches.size());bestRMS=t.rms;}
            if(bestCount>=int(std::min(ref.stars.size(),src.stars.size())*0.85))return best;
        }
    }
    if(bestCount<std::max(8,int(std::min(ref.stars.size(),src.stars.size())*0.15))||bestRMS>1.6)throw std::runtime_error("Star registration failed: insufficient consistent matches");
    return best;
}

Transform liftToFullResolution(Transform t,double scale) {
    if(!(scale>0&&scale<=1))throw std::runtime_error("Invalid proxy scale");
    t.tx=t.tx/scale+(t.a-t.b-1)*(scale-1)/(2*scale);
    t.ty=t.ty/scale+(t.a+t.b-1)*(scale-1)/(2*scale);
    t.rms/=scale;return t;
}

void stack(const std::vector<Input>& inputs,int w,int h,const Settings& cfg,const std::string& output,std::atomic<bool>& cancel,const std::function<void(double)>& progress) {
    if(inputs.size()<2||inputs.size()>512||w<2||h<2||w>30000||h>30000||!(cfg.sigma>=1&&cfg.sigma<=8)||!(cfg.minimumCoverage>0&&cfg.minimumCoverage<=1))throw std::runtime_error("Invalid stack configuration");
    std::vector<File> files;files.reserve(inputs.size());
    for(auto& in:inputs){if(!(in.weight>0&&std::isfinite(in.weight)))throw std::runtime_error("Invalid frame weight");files.emplace_back(in.path,size_t(w)*h*(in.half?8:16));}
    std::string temp=output+".partial";int out=open(temp.c_str(),O_CREAT|O_TRUNC|O_WRONLY,0600);
    if(out<0)throw std::runtime_error("Cannot create stack output");
    try {
        const bool landscape=cfg.mode==Mode::landscape;
        const size_t n=inputs.size();
        const int tw=256,th=std::clamp(int(786432/(n*tw*(landscape?2:1))),4,32);
        std::vector<float> rows(size_t(w)*th*4),values(n*tw*th*3),ground(landscape?values.size():0);
        std::vector<unsigned char> valid(n*tw*th),groundValid(landscape?valid.size():0);
        std::vector<double> v(n),wt(n),sorted(n),deviation(n);
        for(int y0=0;y0<h;y0+=th) {
            int hh=std::min(th,h-y0);std::fill(rows.begin(),rows.end(),0);
            for(int x0=0;x0<w;x0+=tw) {
                if(cancel.load())throw std::runtime_error("Cancelled");
                int ww=std::min(tw,w-x0);size_t pixels=size_t(ww)*hh;
                std::fill(valid.begin(),valid.end(),0);std::fill(groundValid.begin(),groundValid.end(),0);
                for(size_t f=0;f<n;f++) {
                    if(cancel.load())throw std::runtime_error("Cancelled");
                    Transform t=cfg.mode==Mode::trails?Transform{}:inputs[f].transform;
                    std::array<std::pair<double,double>,4> corners={map(t,x0,y0),map(t,x0+ww-1,y0),map(t,x0,y0+hh-1),map(t,x0+ww-1,y0+hh-1)};
                    double lo=h,hi=0;for(auto p:corners){lo=std::min(lo,p.second);hi=std::max(hi,p.second);}
                    {Window win(files[f].fd,w,h,int(std::floor(lo))-1,int(std::ceil(hi))+1,inputs[f].half);
                    for(int y=0;y<hh;y++)for(int x=0;x<ww;x++){size_t p=size_t(y)*ww+x;auto s=map(t,x0+x,y0+y);valid[f*pixels+p]=win.sample(h,s.first,s.second,&values[(f*pixels+p)*3]);}}
                    if(cfg.mode==Mode::landscape) {
                        Window win(files[f].fd,w,h,y0,y0+hh,inputs[f].half);
                        for(int y=0;y<hh;y++)for(int x=0;x<ww;x++){size_t p=size_t(y)*ww+x;groundValid[f*pixels+p]=win.sample(h,x0+x,y0+y,&ground[(f*pixels+p)*3]);}
                    }
                }
                auto combine=[&](size_t p,int c,const std::vector<float>& vals,const std::vector<unsigned char>& mask,bool trails)->std::pair<float,bool> {
                    size_t count=0;for(size_t f=0;f<n;f++)if(mask[f*pixels+p]){v[count]=vals[(f*pixels+p)*3+c];wt[count]=inputs[f].weight;count++;}
                    if(count<size_t(std::max(2,int(std::ceil(n*cfg.minimumCoverage)))))return {0,false};
                    if(trails)return {float(*std::max_element(v.begin(),v.begin()+count)),true};
                    double center=0,limit=std::numeric_limits<double>::infinity();
                    if(count>=5) {
                        std::copy(v.begin(),v.begin()+count,sorted.begin());auto m=sorted.begin()+count/2;std::nth_element(sorted.begin(),m,sorted.begin()+count);center=*m;
                        for(size_t j=0;j<count;j++)deviation[j]=std::abs(v[j]-center);
                        auto dm=deviation.begin()+count/2;std::nth_element(deviation.begin(),dm,deviation.begin()+count);
                        limit=cfg.sigma*std::max(1e-6,1.4826*(*dm));
                    }
                    double sum=0,weights=0;for(size_t j=0;j<count;j++)if(std::abs(v[j]-center)<=limit){sum+=v[j]*wt[j];weights+=wt[j];}
                    if(weights==0)return {float(center),true};
                    return {float(sum/weights),true};
                };
                for(int y=0;y<hh;y++)for(int x=0;x<ww;x++) {
                    size_t p=size_t(y)*ww+x,d=(size_t(y)*w+x0+x)*4;bool good=true;
                    double sky=1;
                    if(cfg.mode==Mode::landscape){double topFraction=1.0-double(y0+y)/std::max(1,h-1),f=std::max(cfg.feather,1e-6);sky=std::clamp((cfg.skyFraction-topFraction)/f+0.5,0.0,1.0);sky=sky*sky*(3-2*sky);}
                    for(int c=0;c<3;c++) {
                        auto a=combine(p,c,values,valid,cfg.mode==Mode::trails);
                        if(cfg.mode==Mode::landscape&&sky<1){auto b=combine(p,c,ground,groundValid,false);rows[d+c]=float(a.first*sky+b.first*(1-sky));good&=(sky<1e-6||a.second)&&b.second;}
                        else {rows[d+c]=a.first;good&=a.second;}
                    }
                    rows[d+3]=good?1:0;if(!good)for(int c=0;c<3;c++)rows[d+c]=0;
                }
            }
            writeAll(out,rows.data(),size_t(w)*hh*16);progress(double(y0+hh)/h);
        }
        if(cancel.load())throw std::runtime_error("Cancelled");
        if(fsync(out))throw std::runtime_error("Cannot flush stack output");
        close(out);out=-1;
        if(rename(temp.c_str(),output.c_str()))throw std::runtime_error("Cannot commit stack output");
    }catch(...){if(out>=0)close(out);unlink(temp.c_str());throw;}
}
}
