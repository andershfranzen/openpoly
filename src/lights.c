#define _DARWIN_C_SOURCE
#include "usb.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>

typedef struct {const char *name; unsigned short id; unsigned char led,mask;} Light;
static const Light lights[]={ {"manual",0x426,0,0},{"sensor",0x427,0,0},
    {"left",0xe34,0x13,0},{"right",0xe34,0x14,0},{"status",0xe34,0x12,0},
    {"idle",0xe33,0,1},{"incoming",0xe33,0,2},{"active",0xe33,0,4},
    {"held",0xe33,0,8},{"charging",0xe33,0,32} };
static int br_usb_error;
static double bar_time(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int br_transfer(libusb_device_handle *h,int input,unsigned char b[62]) {
    if(br_usb_error)return br_usb_error;
    int r=libusb_control_transfer(h,input?0xa1:0x21,input?1:9,input?0x1de:0x2de,3,b,62,1000);
    if(r==LIBUSB_ERROR_TIMEOUT||r==LIBUSB_ERROR_NO_DEVICE||r==LIBUSB_ERROR_PIPE) {
        br_usb_error=r;
        fprintf(stderr,"P21 USB %s; stopping transfers. Lighting restoration is unverified. Reconnect USB before retrying.\n",libusb_error_name(r));
    }
    return r;
}
// Only single-fragment, root-address BR packets are needed for these controls.
static int br_send(libusb_device_handle *h,int type,unsigned short id,const unsigned char *data,int n) {
    if(n<0||n>51||(n&&!data))return 1;
    unsigned char b[62]={0xde,1,1,0x10,(unsigned char)(6+n),0,0,0,(unsigned char)type,
        (unsigned char)(id>>8),(unsigned char)id};
    if(n)memcpy(b+11,data,n);
    int r=br_transfer(h,0,b);
    if(r!=sizeof(b)){fprintf(stderr,"BR send failed: %d\n",r);return 1;}return 0;
}
// Returns payload size, -1 for malformed packets, -2 for unrelated packets.
static int br_parse(const unsigned char *b,int n,int type,unsigned short id,unsigned char *value) {
    if(n!=62||b[0]!=0xde||b[1]!=1||b[2]!=1||b[3]!=0x10||b[4]<6||b[4]>57||b[5]||b[6]||b[7])return -1;
    if(b[9]!=(id>>8)||b[10]!=(id&255))return -2;
    if(b[8]==4||b[8]==7)return -3;
    if(b[8]!=type)return -2;
    int size=b[4]-6;memcpy(value,b+11,size);return size;
}
static int br_wait(libusb_device_handle *h,int type,unsigned short id,unsigned char *value) {
    double deadline=bar_time()+2;
    for(int i=0;i<40&&bar_time()<deadline;i++) {
        struct timespec delay={0,25000000};nanosleep(&delay,NULL);
        unsigned char b[62]={0};int r=br_transfer(h,1,b);
        if(r<0){fprintf(stderr,"BR read: %s\n",libusb_error_name(r));return -1;}
        int n=br_parse(b,r,type,id,value);
        if(n>=0)return n;
        if(n==-3){fprintf(stderr,"BR setting %04x rejected, error bytes %02x %02x\n",id,b[11],b[12]);return -1;}
    }
    fprintf(stderr,"No matching BR response for %04x\n",id);return -1;
}
static int raw_get(libusb_device_handle *h,const Light *c,int *value) {
    unsigned char b[51]={0};
    if(br_send(h,2,c->id,&c->led,c->led?1:0))return 1;
    int n=br_wait(h,3,c->id,b);
    if(c->mask && n==4){*value=!!(b[3]&c->mask);return 0;}
    if(!c->led && !c->mask && n==1 && b[0]<=1){*value=b[0];return 0;}
    // P21 1.1165.71.2094 echoes selector 12 for right-light GETs (requested 14).
    if(c->led && n==3 && (b[0]==c->led||(c->led==0x14&&b[0]==0x12)) && b[1]==0xff && b[2]<=100){*value=b[2];return 0;}
    fprintf(stderr,"Invalid %s response\n",c->name);return 1;
}
static int light_get(libusb_device_handle *h,const Light *c,int *value) {
    // GET_REPORT retains the last reply. A different setting reply fences stale reads.
    int ignored;const Light *barrier=c->id==0x426?&lights[1]:&lights[0];
    return raw_get(h,barrier,&ignored)||raw_get(h,c,value);
}
static int light_write(libusb_device_handle *h,const Light *c,int value) {
    unsigned char b[3]={c->led,0xff,(unsigned char)value};
    unsigned char masked[8]={0,0,0,value?c->mask:0,0,0,0,c->mask};
    if(br_send(h,5,c->id,c->mask?masked:c->led?b:b+2,c->mask?8:c->led?3:1))return 1;
    unsigned char reply[51];return br_wait(h,6,c->id,reply)!=0;
}
static int light_set(libusb_device_handle *h,const Light *c,int value) {
    int before,actual;
    if(light_get(h,c,&before))return 1;
    if(light_write(h,c,value)||light_get(h,c,&actual)||actual!=value) {
        fprintf(stderr,"%s write/readback failed; restoring %d\n",c->name,before);
        if(light_write(h,c,before)||light_get(h,c,&actual)||actual!=before)fprintf(stderr,"RESTORATION FAILED for %s; inspect device\n",c->name);
        return 1;
    }
    return 0;
}
// Firmware 2094's diagnostic I2C bridge. Keep access confined to the bottom chips.
static int bar_io(libusb_device_handle *h,int write,int address,int reg,unsigned char *data,int n) {
    if(n<1||n>15||!data || (address!=0x69&&address!=0x6a&&address!=0x76) ||
       (address==0x76&&(write||reg||n!=1)) || reg<0 || reg+n>15 ||
       (write&&reg<2))return 1;
    unsigned char p[35]={0,0,'I','2','C',0,0,0,0,0,0,0,0,write?4:3,
        (unsigned char)address,(unsigned char)reg,address==0x76?0:1,(unsigned char)n,0,0};
    int size=20+(write?n:0),ignored;
    if(write)memcpy(p+20,data,n);
    // One-byte chip reads have the same reply shape as mux reads; fence both.
    if(((address==0x76||(!write&&n==1))&&raw_get(h,&lights[0],&ignored))||br_send(h,5,0x31b,p,size))return 1;
    double deadline=bar_time()+2;
    for(int i=0;i<40&&bar_time()<deadline;i++) {
        struct timespec delay={0,25000000};nanosleep(&delay,NULL);
        unsigned char b[62]={0},reply[51];
        int z=br_transfer(h,1,b);
        if(z<0)break;
        int k=br_parse(b,z,write?6:10,0x31b,reply);
        if(k==-3)break;
        if(write&&k==5&&!memcmp(reply,"\0\1I2\1",5))return 0;
        if(!write&&k==n+4&&!memcmp(reply,"\0\1I2",4)){memcpy(data,reply+4,n);return 0;}
        // A successful write also emits its payload; it may replace the ACK before GET_REPORT.
        if(write&&br_parse(b,z,10,0x31b,reply)==size&&!memcmp(reply,p,size))return 0;
    }
    fprintf(stderr,"LED bridge failed (%s %02x:%02x)\n",write?"write":"read",address,reg);
    return 1;
}
static int led_channel(libusb_device_handle *h,int expected) {
    unsigned char channel;
    if(bar_io(h,0,0x76,0,&channel,1))return 1;
    // Do not change the mux behind the firmware's cached channel selection.
    if(channel!=expected){fprintf(stderr,"LED bus changed (mux=%02x, expected=%02x)\n",channel,expected);return 1;}
    return 0;
}
static int bar_read(libusb_device_handle *h,int chip,unsigned char state[15]) {
    if(led_channel(h,4)||bar_io(h,0,0x69+chip,0,state,15)||led_channel(h,4))return 1;
    if(state[0]!=0xa4){fprintf(stderr,"Unexpected bottom LED chip ID\n");return 1;}
    return 0;
}
static int bar_write(libusb_device_handle *h,int chip,int reg,unsigned char *values,int n) {
    unsigned char actual[15];
    return led_channel(h,4)||bar_io(h,1,0x69+chip,reg,values,n)||
        led_channel(h,4)||bar_io(h,0,0x69+chip,reg,actual,n)||memcmp(values,actual,n)!=0||led_channel(h,4);
}
static unsigned char bar_component(int value){return (unsigned char)((value*192+127)/255);}
static volatile sig_atomic_t bar_stopped;
static void bar_stop(int signal){(void)signal;bar_stopped=1;}
static int side_mode_get(libusb_device_handle *h,int *mode) {
    int ignored;
    if(raw_get(h,&lights[0],&ignored)||br_send(h,2,0x300,NULL,0))return 1;
    double deadline=bar_time()+2;
    for(int i=0;i<40&&bar_time()<deadline;i++) {
        struct timespec delay={0,25000000};nanosleep(&delay,NULL);
        unsigned char b[62]={0},reply[51];
        int n=br_transfer(h,1,b);
        if(n<0)break;
        int size=br_parse(b,n,3,0x300,reply);
        if(size==1&&reply[0]<=1){*mode=reply[0];return 0;}
        // Firmware 2094 denies GET0300 with 0012 while its command gate is off.
        if(size==-3&&b[8]==4&&b[4]>=8&&b[11]==0&&b[12]==0x12){*mode=0;return 0;}
    }
    fprintf(stderr,"Cannot determine side-control command gate\n");return 1;
}
static int side_send(libusb_device_handle *h,unsigned short id,const unsigned char *data,int n) {
    int ignored;
    if(raw_get(h,&lights[0],&ignored)||br_send(h,5,id,data,n))return 1;
    double deadline=bar_time()+2;
    for(int i=0;i<40&&bar_time()<deadline;i++) {
        struct timespec delay={0,25000000};nanosleep(&delay,NULL);
        unsigned char b[62]={0},reply[51];
        int z=br_transfer(h,1,b);
        if(z<0)break;
        int size=br_parse(b,z,6,id,reply);
        if(size==0)return 0;
        if(size==-3)break;
        if(id==0x300&&br_parse(b,z,10,id,reply)==n&&!memcmp(reply,data,n))return 0;
    }
    fprintf(stderr,"Side command %04x failed\n",id);return 1;
}
static int side_verify(libusb_device_handle *h,int side,int percent) {
    int component=192*percent/100;
    // ACK means queued. Verify the two responding chips; firmware also configures
    // address 68, which rejects reads on this unit and is not verified here.
    for(int attempt=0;attempt<10&&!bar_stopped;attempt++) {
        struct timespec delay={0,50000000};nanosleep(&delay,NULL);int matched=1;
        for(int chip=0;chip<2&&matched;chip++) {
            unsigned char state[15];
            if(led_channel(h,1<<side)||bar_io(h,0,0x69+chip,0,state,15)||led_channel(h,1<<side))return 1;
            if(state[0]!=0xa4)return 1;
            if(percent)for(int i=3;i<9;i++)if(state[i]!=component)matched=0;
            for(int i=9;i<15;i++)if((state[i]&0x88)!=(percent?0x88:0))matched=0;
            if(percent&&(state[2]&0xc0)!=0x80)matched=0;
        }
        if(matched)return 0;
    }
    fprintf(stderr,"Side %d did not reach requested brightness\n",side+1);return 1;
}
static int side_control(libusb_device_handle *h,int left,int right) {
    if(left<0||left>100||right<0||right>100)return 2;
    int before,actual;
    if(side_mode_get(h,&before))return 1;
    struct sigaction action={0},old_int,old_term;
    action.sa_handler=bar_stop;sigemptyset(&action.sa_mask);bar_stopped=0;
    sigaction(SIGINT,&action,&old_int);sigaction(SIGTERM,&action,&old_term);
    unsigned char on=1,restore=(unsigned char)before;
    int result=side_send(h,0x300,&on,1);
    if(!result&&(side_mode_get(h,&actual)||actual!=1))result=1;
    int levels[]={((left+9)/10)*10,((right+9)/10)*10};
    for(int side=0;side<2&&!result&&!bar_stopped;side++) {
        // Firmware labels face outward; CLI labels face the screen (visually verified).
        int device_side=1-side;
        unsigned char command[]={(unsigned char)(0x13+device_side),8,(unsigned char)levels[side]};
        result=side_send(h,0x317,command,3)||side_verify(h,device_side,levels[side]);
        if(!result)printf("side-%s=%d%% (live, verified)\n",side?"right":"left",levels[side]);
    }
    if(bar_stopped)result=1;
    if(side_send(h,0x300,&restore,1)||side_mode_get(h,&actual)||actual!=before) {
        fprintf(stderr,"Side-control command gate restoration FAILED\n");result=1;
    }
    sigaction(SIGINT,&old_int,NULL);sigaction(SIGTERM,&old_term,NULL);
    return result;
}
// Native selection keeps the firmware's mux cache consistent. It also sets dim
// white, so a newly activated channel establishes a new restoration baseline.
static int bar_activate(libusb_device_handle *h) {
    unsigned char channel;
    if(bar_io(h,0,0x76,0,&channel,1))return 1;
    if(channel==4)return 0;
    int before,actual;
    if(side_mode_get(h,&before))return 1;
    unsigned char on=1,restore=(unsigned char)before,command[]={0x12,8,10};
    int result=before?0:side_send(h,0x300,&on,1);
    if(!result&&(side_mode_get(h,&actual)||actual!=1))result=1;
    if(!result&&!bar_stopped)result=side_send(h,0x317,command,3);
    if(!before&&(side_send(h,0x300,&restore,1)||side_mode_get(h,&actual)||actual!=before)) {
        fprintf(stderr,"Bottom activation command gate restoration FAILED\n");result=1;
    }
    if(result||bar_stopped)return 1;
    for(int attempt=0;attempt<8;attempt++) {
        struct timespec delay={0,100000000};nanosleep(&delay,NULL);
        if(bar_io(h,0,0x76,0,&channel,1))return 1;
        if(channel==4){puts("Bottom channel activated; restoration baseline is dim white.");return 0;}
    }
    fprintf(stderr,"Bottom channel activation did not apply\n");return 1;
}
static int bar_cycle(libusb_device_handle *h,int64_t seconds,int64_t period,unsigned char next[2][15]) {
    int before,actual;
    if(side_mode_get(h,&before))return 1;
    unsigned char on=1,restore=(unsigned char)before;
    int result=before?0:side_send(h,0x300,&on,1);
    if(!result&&(side_mode_get(h,&actual)||actual!=1))result=1;
    // Use the hardware fade and normal firmware LED events. Repeated diagnostic
    // I2C requests stalled this unit, even with Poly's services stopped.
    const int fade_ms[]={31,63,125,250,500,1000,2000,4000};int fade=0;
    while(fade<7&&fade_ms[fade]<period*1000/6)fade++;
    for(int c=0;c<2&&!result&&!bar_stopped;c++) {
        next[c][2]=(next[c][2]&0xf8)|(unsigned char)fade;
        result=bar_write(h,c,2,next[c]+2,1);
    }
    const unsigned char colors[]={2,1,4}; // Firmware red, green, blue; hardware interpolates.
    double start=bar_time();int previous=-1,retries=0;
    if(!result){printf("Native RGB cycle: %lld-second period, %lld-second run. Ctrl+C restores.\n",(long long)period,(long long)seconds);fflush(stdout);}
    while(!result&&!bar_stopped&&bar_time()-start<seconds) {
        int phase=(int)((bar_time()-start)*3.0/period)%3;
        if(phase!=previous) {
            unsigned char command[]={0x12,colors[phase],100};
            if(side_send(h,0x317,command,3)) {
                if(br_usb_error||retries++>=2){result=1;break;}
                struct timespec delay={0,500000000};nanosleep(&delay,NULL);continue;
            }
            if(previous<0) {
                // Verify initial native rendering once; subsequent phases use
                // queued-event ACKs so the animation has no diagnostic traffic.
                struct timespec delay={0,100000000};nanosleep(&delay,NULL);
                const unsigned char rgb[3][3]={{143,0,0},{7,80,15},{5,5,112}};
                for(int c=0;c<2&&!result;c++) {
                    unsigned char state[15];
                    if(bar_read(h,c,state)||memcmp(state+3,rgb[phase],3))result=1;
                }
                if(result)fprintf(stderr,"Initial native color readback failed\n");
            }
            previous=phase;
        }
        struct timespec delay={0,100000000};nanosleep(&delay,NULL);
    }
    if(!br_usb_error&&!before&&(side_send(h,0x300,&restore,1)||side_mode_get(h,&actual)||actual!=before)) {
        fprintf(stderr,"Cycle command gate restoration FAILED\n");result=1;
    }
    if(br_usb_error){fprintf(stderr,"Cycle command gate restoration is unverified\n");result=1;}
    return result;
}
static int bar_control(libusb_device_handle *h,int argc,char **argv) {
    int state=!strcmp(argv[0],"bar-state"),cycle=!strcmp(argv[0],"cycle"),
        palette=!strcmp(argv[0],"palette"),fade=!strcmp(argv[0],"fade");
    int64_t values[8]={0},seconds=cycle?30:0,period=30;
    if(state){if(argc!=1)return 2;}
    else if(cycle){if(argc>3||(argc>=2&&p21_integer(argv[1],1,3600,&seconds))||
        (argc==3&&p21_integer(argv[2],1,3600,&period)))return 2;}
    else if(fade){if(argc!=2||p21_integer(argv[1],0,7,&values[0]))return 2;}
    else if(palette) {
        if(argc!=9||p21_integer(argv[1],1,2,&values[0])||strlen(argv[8])!=12)return 2;
        for(int i=0;i<6;i++)if(p21_integer(argv[i+2],0,255,&values[i+1]))return 2;
        for(int i=0;i<12;i++)if(!strchr("089abcdef",argv[8][i]))return 2;
    } else {
        if(argc!=4&&argc!=5)return 2;
        for(int i=0;i<3;i++)if(p21_integer(argv[i+1],0,255,&values[i]))return 2;
        if(argc==5&&p21_integer(argv[4],1,3600,&seconds))return 2;
    }
    if(!h)return 0; // Validate before opening USB.
    struct sigaction action={0},old_int,old_term;
    action.sa_handler=bar_stop;sigemptyset(&action.sa_mask);bar_stopped=0;
    sigaction(SIGINT,&action,&old_int);sigaction(SIGTERM,&action,&old_term);
    int result=0;
    unsigned char before[2][15],next[2][15];
    if(!state&&!fade&&!palette&&bar_activate(h)){result=1;goto done;}
    for(int c=0;c<2;c++)if(bar_read(h,c,before[c])){result=1;goto done;}
    memcpy(next,before,sizeof(next));
    if(state){for(int c=0;c<2;c++){printf("bar chip%d (%02x), registers 00..0e:",c+1,0x69+c);
        for(int i=0;i<15;i++)printf(" %02x",before[c][i]);puts("");}goto done;}
    if(fade)for(int c=0;c<2;c++)next[c][2]=(before[c][2]&0xf8)|(unsigned char)values[0];
    else if(palette) {
        int c=(int)values[0]-1;
        for(int i=0;i<6;i++)next[c][3+i]=bar_component((int)values[i+1]);
        for(int i=0;i<6;i++){const char *digits="0123456789abcdef";
            next[c][9+i]=(unsigned char)(((strchr(digits,argv[8][i*2])-digits)<<4)|(strchr(digits,argv[8][i*2+1])-digits));}
    } else for(int c=0;c<2;c++) {
        for(int i=0;i<3;i++)next[c][3+i]=bar_component((int)values[i]);
        memset(next[c]+9,0x88,6);
    }
    if(!fade)for(int c=0;c<2;c++)next[c][2]=(before[c][2]&0x3f)|0x80;
    if(cycle){result=bar_cycle(h,seconds,period,next);goto restore;}
    double start=bar_time();
    do {
        if(bar_stopped)break;
        for(int c=0;c<2;c++)if(!palette||c==values[0]-1) {
            if(bar_write(h,c,2,next[c]+2,fade?1:13)){result=1;break;}
        }
        if(result||!seconds)break;
        do{struct timespec delay={0,100000000};nanosleep(&delay,NULL);}
        while(!bar_stopped&&bar_time()-start<seconds);
    }while(!bar_stopped&&bar_time()-start<seconds);
restore:
    if(br_usb_error)result=1;
    else if(seconds||result||bar_stopped) {
        for(int c=0;c<2;c++)if(!palette||c==values[0]-1) {
            if(bar_write(h,c,2,before[c]+2,fade?1:13)) {
                fprintf(stderr,"Bottom chip%d restoration FAILED\n",c+1);result=1;
            }
        }
        if(!result)puts("Bottom bar restored; register readback verified.");
    }else puts("Bottom bar updated; register readback verified.");
done:
    sigaction(SIGINT,&old_int,NULL);sigaction(SIGTERM,&old_term,NULL);
    return result;
}
// Patched-firmware icon LCD (docs/icon-push-patch.md): 0x031b label "PLCD".
// The flashed patch inverts the stock status convention: a completed op gets the
// type-7 reply "00 01 PL 00"; a rejected op gets ACK + type-10 echo of the request.
// ponytail: fixed pacing, no per-chunk fencing (GET_REPORT keeps the last reply); tune if frames tear.
static const struct timespec lcd_pace={0,3000000};
static int lcd_rejected(const unsigned char *b,int z) {
    return z==62&&b[0]==0xde&&b[9]==3&&b[10]==0x1b&&(b[8]==6||(b[8]==10&&!memcmp(b+13,"PLCD",4)));
}
static int lcd_op(libusb_device_handle *h,const unsigned char *body,int n) {
    unsigned char p[51]={0,0,'P','L','C','D'};
    if(n<1||n>41)return 1;
    memcpy(p+10,body,n);
    if(br_send(h,5,0x31b,p,10+n))return 1;
    nanosleep(&lcd_pace,NULL);
    unsigned char b[62]={0};int z=br_transfer(h,1,b);
    if(z<0)return 1;
    if(lcd_rejected(b,z)){fprintf(stderr,"LCD op %c rejected\n",body[0]);return 1;}
    return 0;
}
// An invalid op is the only side-effect-free probe: patched builds reject it
// (ACK + echo); stock firmware answers type 7. The 'Q' op leaks a reply buffer.
static int lcd_query(libusb_device_handle *h) {
    int ignored;unsigned char p[11]={0,0,'P','L','C','D',0,0,0,0,'X'};
    if(raw_get(h,&lights[0],&ignored)||br_send(h,5,0x31b,p,sizeof(p)))return 1;
    double deadline=bar_time()+2;
    for(int i=0;i<40&&bar_time()<deadline;i++) {
        struct timespec delay={0,25000000};nanosleep(&delay,NULL);
        unsigned char b[62]={0};
        int z=br_transfer(h,1,b);
        if(z<0)break;
        if(lcd_rejected(b,z)){puts("LCD patch present");return 0;}
        if(z==62&&b[8]==7&&b[9]==3&&b[10]==0x1b)break;
    }
    fprintf(stderr,"LCD patch not detected (stock firmware?)\n");return 1;
}
// Frames are raw big-endian RGB565, w*h*2 bytes each; only changed chunks are resent.
static int lcd_play(libusb_device_handle *h,int x,int y,int w,int h_,const unsigned char *frames,size_t count,int ms,int loop) {
    int size=w*h_*2;unsigned char begin[5]={'B',(unsigned char)x,(unsigned char)y,(unsigned char)w,(unsigned char)h_};
    const unsigned char *last=NULL;
    if(lcd_op(h,begin,5))return 1;
    struct sigaction action={0},old_int,old_term;
    action.sa_handler=bar_stop;sigemptyset(&action.sa_mask);bar_stopped=0;
    sigaction(SIGINT,&action,&old_int);sigaction(SIGTERM,&action,&old_term);
    int result=0;
    do for(size_t f=0;f<count&&!result&&!bar_stopped;f++) {
        double start=bar_time();const unsigned char *frame=frames+f*(size_t)size;
        for(int off=0;off<size&&!result;off+=36) {
            int len=size-off<36?size-off:36;
            if(last&&!memcmp(last+off,frame+off,len))continue;
            unsigned char d[40]={'D',(unsigned char)off,(unsigned char)(off>>8),(unsigned char)len};
            memcpy(d+4,frame+off,len);result=lcd_op(h,d,4+len);
        }
        if(!result)result=lcd_op(h,(const unsigned char *)"S",1);
        last=frame;
        double left=ms/1000.0-(bar_time()-start);
        if(!result&&left>0){struct timespec t={(time_t)left,(long)((left-(time_t)left)*1e9)};nanosleep(&t,NULL);}
    } while(loop&&!result&&!bar_stopped);
    sigaction(SIGINT,&old_int,NULL);sigaction(SIGTERM,&old_term,NULL);
    return result;
}
int p21_lcd(int argc,char **argv) {
    int64_t v[6]={54,9,60,60,400,0};unsigned char *frames=NULL;size_t count=0;int size=0;
    int query=argc==1&&!strcmp(argv[0],"query");
    int fill=argc==2&&!strcmp(argv[0],"fill");
    int play=(argc==2||argc==3)&&!strcmp(argv[0],"play");
    if(!query&&!fill&&!play)goto usage;
    if(fill&&p21_integer(argv[1],0,0xffff,&v[5]))goto usage;
    if(play&&argc==3&&p21_integer(argv[2],1,60000,&v[4]))goto usage;
    size=(int)(v[2]*v[3]*2);
    if(play) {
        FILE *file=fopen(argv[1],"rb");
        if(!file){perror(argv[1]);return 1;}
        fseek(file,0,SEEK_END);long length=ftell(file);rewind(file);
        if(length<=0||length%size){fprintf(stderr,"%s: size must be a multiple of %d (60x60 RGB565BE)\n",argv[1],size);fclose(file);return 1;}
        frames=malloc((size_t)length);count=(size_t)length/(size_t)size;
        if(!frames||fread(frames,1,(size_t)length,file)!=(size_t)length){fclose(file);free(frames);fprintf(stderr,"%s: read failed\n",argv[1]);return 1;}
        fclose(file);
    } else if(fill) {
        frames=malloc((size_t)size);count=1;
        if(!frames)return 1;
        for(int i=0;i<size;i+=2){frames[i]=(unsigned char)(v[5]>>8);frames[i+1]=(unsigned char)v[5];}
    }
    char path[128];snprintf(path,sizeof(path),"/tmp/p21ctl-br-%u.lock",(unsigned)getuid());
    int lock=open(path,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(lock<0||flock(lock,LOCK_EX|LOCK_NB)){fprintf(stderr,"Cannot acquire P21 vendor-control lock\n");if(lock>=0)close(lock);free(frames);return 1;}
    libusb_context *ctx;libusb_device_handle *h;
    if(p21_usb_open(0x047f,0x431a,&ctx,&h)){close(lock);free(frames);return 1;}
    br_usb_error=0;
    int result=lcd_query(h);
    if(!result&&!query)result=lcd_play(h,(int)v[0],(int)v[1],(int)v[2],(int)v[3],frames,count,(int)v[4],play);
    libusb_close(h);libusb_exit(ctx);close(lock);free(frames);return result;
usage:
    fprintf(stderr,"lcd: query | fill RGB565 | play FILE.raw [MS_PER_FRAME]\n"
        "  FILE.raw: concatenated 60x60 big-endian RGB565 frames, looped until Ctrl+C\n");return 2;
}
int p21_lights(int argc,char **argv) {
    int sides=argc>0&&!strcmp(argv[0],"sides");int64_t left=0,right=0;
    if(sides&&(argc!=3||p21_integer(argv[1],0,100,&left)||p21_integer(argv[2],0,100,&right)))goto usage;
    int bar=argc>0&&(!strcmp(argv[0],"rgb")||!strcmp(argv[0],"cycle")||!strcmp(argv[0],"palette")||
        !strcmp(argv[0],"fade")||!strcmp(argv[0],"bar-state"));
    if(bar&&bar_control(NULL,argc,argv))goto usage;
    int list=argc==1&&!strcmp(argv[0],"list");const Light *c=NULL;int64_t value=0;
    if(argc>0)for(size_t i=0;i<sizeof(lights)/sizeof(*lights);i++)if(!strcmp(argv[0],lights[i].name))c=&lights[i];
    if(!sides&&!bar&&!list&&(!c||(argc!=1&&argc!=2)))goto usage;
    if(!sides&&!bar&&argc==2) {
        if(c->led){if(p21_integer(argv[1],0,100,&value))goto usage;}
        else if(!strcmp(argv[1],"on"))value=1;
        else if(strcmp(argv[1],"off"))goto usage;
    }
    // Coordinate our processes; Poly Studio must not issue simultaneous BR requests.
    char path[128];snprintf(path,sizeof(path),"/tmp/p21ctl-br-%u.lock",(unsigned)getuid());
    int lock=open(path,O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if(lock<0||flock(lock,LOCK_EX|LOCK_NB)){fprintf(stderr,"Cannot acquire P21 vendor-control lock\n");if(lock>=0)close(lock);return 1;}
    libusb_context *ctx;libusb_device_handle *h;
    if(p21_usb_open(0x047f,0x431a,&ctx,&h)){close(lock);return 1;}
    br_usb_error=0;int result=0;
    if(sides)result=side_control(h,(int)left,(int)right);
    else if(bar)result=bar_control(h,argc,argv);
    else if(argc==2)result=light_set(h,c,(int)value);
    if(!sides&&!bar&&!result)for(size_t i=0;i<sizeof(lights)/sizeof(*lights);i++)if(list||c==&lights[i]) {
        int actual;
        if(light_get(h,&lights[i],&actual)){result=1;if(br_usb_error)break;}
        else if(lights[i].led)printf("%s=%d%%\n",lights[i].name,actual);
        else printf("%s=%s\n",lights[i].name,actual?"on":"off");
    }
    libusb_close(h);libusb_exit(ctx);close(lock);return result;
usage:
    fprintf(stderr,"lights: list | left|right|status [0..100] | manual|sensor|idle|incoming|active|held|charging [on|off]\n"
        "  bar-state | rgb R G B [SECONDS] | cycle [SECONDS [PERIOD]] | fade 0..7\n"
        "  sides LEFT RIGHT (0..100, rounded up to 10%% steps; immediate)\n"
        "  palette CHIP R0 G0 B0 R1 G1 B1 MAP (chip 1/2; 12 selectors from 089abcdef)\n");return 2;
}
