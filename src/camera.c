#include "usb.h"
#include <stdio.h>
#include <string.h>
#include <inttypes.h>

typedef struct { const char *name; uint8_t unit, selector, width, components, sign; } Control;
static const Control controls[] = {
    {"auto-exposure",1,2,1,1,0}, {"exposure-priority",1,3,1,1,0},
    {"exposure",1,4,4,1,0}, {"zoom",1,11,2,1,0}, {"pan-tilt",1,13,4,2,1},
    {"privacy",1,17,1,1,0}, {"backlight",3,1,2,1,0},
    {"brightness",3,2,2,1,1}, {"contrast",3,3,2,1,0}, {"gain",3,4,2,1,0},
    {"power-line",3,5,1,1,0}, {"hue",3,6,2,1,1}, {"saturation",3,7,2,1,0},
    {"sharpness",3,8,2,1,0}, {"gamma",3,9,2,1,0}, {"white-balance",3,10,2,1,0},
    {"auto-white-balance",3,11,1,1,0}
};
static int transfer(libusb_device_handle *h, const Control *c, uint8_t request, unsigned char *b, int size) {
    int r = libusb_control_transfer(h, request == 1 ? 0x21 : 0xa1, request,
                                   c->selector << 8, c->unit << 8, b, size, 1000);
    return r == size ? 0 : r < 0 ? r : LIBUSB_ERROR_IO;
}
static int restoreControl(libusb_device_handle *h, const Control *c, const unsigned char *before, int size) {
    unsigned char wanted[8]={0},actual[8]={0};
    memcpy(wanted,before,size);
    int r=transfer(h,c,1,wanted,size);
    if(r) {
        fprintf(stderr,"RESTORE FAILED: %s SET_CUR (%s)\n",c->name,libusb_error_name(r));
        return 1;
    }
    r=transfer(h,c,0x81,actual,size);
    if(r) {
        fprintf(stderr,"RESTORE FAILED: %s GET_CUR (%s)\n",c->name,libusb_error_name(r));
        return 1;
    }
    if(memcmp(wanted,actual,size)) {
        fprintf(stderr,"RESTORE FAILED: %s readback mismatch\n",c->name);
        return 1;
    }
    return 0;
}
static int64_t decode(const unsigned char *b, int width, int sign) {
    uint32_t n = 0;
    for (int i = 0; i < width; i++) n |= (uint32_t)b[i] << (8*i);
    if (sign && (n & (1U << (width*8-1)))) return (int64_t)n - (1LL << (width*8));
    return n;
}
static int readbackAccepted(const Control *c,const unsigned char *requested,
                            const unsigned char *actual,const unsigned char *lo,
                            const unsigned char *hi,const unsigned char *step,int size) {
    if(!memcmp(requested,actual,size))return 1;
    if(strcmp(c->name,"zoom")||c->components!=1)return 0;
    int64_t wanted=decode(requested,c->width,c->sign),got=decode(actual,c->width,c->sign);
    int64_t min=decode(lo,c->width,c->sign),max=decode(hi,c->width,c->sign);
    int64_t increment=decode(step,c->width,c->sign),delta=got-wanted;
    if(delta<0)delta=-delta;
    // Measured P21 zoom quantization: 11 -> 10 and 15 -> 13. Keep every
    // other mismatch on the existing restore path.
    return got>=min&&got<=max&&(!increment||(got-min)%increment==0)&&delta<=2;
}
static void values(const unsigned char *b, const Control *c) {
    for (int i=0; i<c->components; i++) printf("%s%" PRId64, i ? "," : "", decode(b+i*c->width,c->width,c->sign));
}
static int show(libusb_device_handle *h, const Control *c) {
    unsigned char info=0, b[8]={0}; int size=c->width*c->components;
    int r=transfer(h,c,0x86,&info,1);
    if (r) { printf("%s unavailable (%s)\n",c->name,libusb_error_name(r)); return 1; }
    printf("%s",c->name);
    const char *labels[]={"current","min","max","step","default"};
    const uint8_t requests[]={0x81,0x82,0x83,0x84,0x87};
    int failed=0;
    for (int i=0;i<5;i++) {
        r=transfer(h,c,requests[i],b,size);
        if (!r) { printf(" %s=",labels[i]); values(b,c); }
        else if(i==0) { printf(" current=unavailable"); failed=1; }
    }
    printf(" writable=%s%s\n",info&2?"yes":"no",info&4?" (disabled by automatic mode)":"");
    return failed;
}
static int set(libusb_device_handle *h, const Control *c, char **args) {
    unsigned char info=0, b[8]={0}, lo[8]={0}, hi[8]={0}, step[8]={0};
    int size=c->width*c->components;
    int r=transfer(h,c,0x86,&info,1);
    if(r || !(info&2) || (info&4)) { fprintf(stderr,"%s is unavailable, read-only, or disabled by automatic mode\n",c->name); return 1; }
    int boolean = !strcmp(c->name,"privacy") || !strcmp(c->name,"exposure-priority") || !strcmp(c->name,"auto-white-balance");
    int ae = !strcmp(c->name,"auto-exposure");
    if(!boolean && !ae) {
        if(transfer(h,c,0x82,lo,size) || transfer(h,c,0x83,hi,size) || transfer(h,c,0x84,step,size)) {
            fprintf(stderr,"Cannot read %s limits; refusing write\n",c->name); return 1;
        }
    }
    unsigned char aeModes=0;
    if(ae && transfer(h,c,0x84,&aeModes,1)) { fprintf(stderr,"Cannot read supported exposure modes\n"); return 1; }
    for(int i=0;i<c->components;i++) {
        int64_t min=boolean?0:ae?1:decode(lo+i*c->width,c->width,c->sign);
        int64_t max=boolean?1:ae?8:decode(hi+i*c->width,c->width,c->sign);
        int64_t increment=boolean||ae?1:decode(step+i*c->width,c->width,c->sign), n;
        if(p21_integer(args[i],min,max,&n) || (increment>0 && (n-min)%increment) ||
           (ae && ((n & (n-1)) || !(aeModes & n)))) {
            fprintf(stderr,"Invalid %s value; use its reported range and step (exposure modes: supported single bits)\n",c->name); return 2;
        }
        for(int j=0;j<c->width;j++) b[i*c->width+j]=(uint64_t)n>>(8*j);
    }
    unsigned char before[8]={0};
    r=transfer(h,c,0x81,before,size);
    if(r) { fprintf(stderr,"%s GET_CUR before write: %s\n",c->name,libusb_error_name(r)); return 1; }
    r=transfer(h,c,1,b,size);
    if(r) {
        fprintf(stderr,"%s SET_CUR: %s; restoring previous value\n",c->name,libusb_error_name(r));
        restoreControl(h,c,before,size);
        return 1;
    }
    unsigned char actual[8]={0};
    r=transfer(h,c,0x81,actual,size);
    if(r || !readbackAccepted(c,b,actual,lo,hi,step,size)) {
        fprintf(stderr,"%s write readback did not match (P21 may round zoom; pan/tilt requires zoom > 10)\n",c->name);
        restoreControl(h,c,before,size);
        show(h,c); return 1;
    }
    return show(h,c);
}
int p21_camera(int argc,char **argv) {
    if(argc<1) { fprintf(stderr,"camera: list | CONTROL [VALUE] (pan-tilt takes PAN TILT, in arcseconds)\n"); return 2; }
    const Control *selected=NULL;
    for(size_t i=0;i<sizeof(controls)/sizeof(*controls);i++) if(!strcmp(argv[0],controls[i].name)) selected=&controls[i];
    int listing=!strcmp(argv[0],"list") && argc==1;
    if(!listing && (!selected || (argc!=1 && argc!=1+selected->components))) { fprintf(stderr,"Unknown camera control or wrong argument count\n"); return 2; }
    libusb_context *ctx; libusb_device_handle *h;
    if(p21_usb_open(0x095d,0x9298,&ctx,&h)) return 1;
    // P21 firmware's descriptor identifies camera terminal 1, processing unit 3, VC interface 0.
    struct libusb_config_descriptor *cfg=NULL;
    int verified=0;
    if(!libusb_get_active_config_descriptor(libusb_get_device(h),&cfg)) {
        int ct=0,pu=0;
        for(int i=0;i<cfg->bNumInterfaces;i++) for(int j=0;j<cfg->interface[i].num_altsetting;j++) {
            const struct libusb_interface_descriptor *a=&cfg->interface[i].altsetting[j];
            if(a->bInterfaceNumber || a->bInterfaceClass!=14 || a->bInterfaceSubClass!=1) continue;
            for(int p=0;p+3<=a->extra_length;) {
                const unsigned char *d=a->extra+p; int n=d[0];
                if(n<3 || p+n>a->extra_length)break;
                if(n>=8 && d[1]==0x24 && d[2]==2 && d[3]==1 && d[4]==1 && d[5]==2)ct=1;
                if(n>=8 && d[1]==0x24 && d[2]==5 && d[3]==3)pu=1;
                p+=n;
            }
        }
        verified=ct&&pu; libusb_free_config_descriptor(cfg);
    }
    int result=0;
    if(!verified) { fprintf(stderr,"Unexpected P21 UVC layout; refusing controls\n"); result=1; }
    else if(listing) for(size_t i=0;i<sizeof(controls)/sizeof(*controls);i++) result|=show(h,&controls[i]);
    else result=argc==1?show(h,selected):set(h,selected,argv+1);
    libusb_close(h); libusb_exit(ctx); return result;
}
