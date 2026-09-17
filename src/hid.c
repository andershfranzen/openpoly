#include "usb.h"
#include <stdio.h>
#include <string.h>
#include <time.h>
static const struct {const char *name; int report,bit;} indicators[]={
    {"mute-indicator",0x09,2},{"call-indicator",0x17,3},
    {"ring-indicator",0x18,4},{"hold-indicator",0x20,5}
};
static int feature(libusb_device_handle *h,int id,unsigned char *b,int size) {
    int r=libusb_control_transfer(h,0xa1,1,0x300|id,3,b,size,1000);
    if(r!=size || b[0]!=id) { fprintf(stderr,"HID feature %02x: invalid response (%d)\n",id,r);return 1; }
    return 0;
}
static const struct {const char *name; int value;} softphones[]={
    {"zoom",22},{"teams",23}
};
static int icon_value(libusb_device_handle *h,int *value) {
    unsigned char b[12]={0};
    if(feature(h,6,b,12))return 1;
    *value=b[10]|(b[11]<<8);return 0;
}
static const char *icon_name(int value) {
    for(size_t i=0;i<sizeof(softphones)/sizeof(*softphones);i++)
        if(softphones[i].value==value)return softphones[i].name;
    return NULL;
}
static int icon_set(libusb_device_handle *h,int value) {
    // Output 0x0d: 24-bit payload; usage f0 occupies bits 8..23, so the
    // first payload byte stays zero and the value follows little endian.
    // Firmware applies the change asynchronously (~25 ms), so poll for it.
    unsigned char out[]={0x0d,0,(unsigned char)(value&255),(unsigned char)(value>>8)};
    int r=libusb_control_transfer(h,0x21,9,0x200|0x0d,3,out,sizeof(out),1000);
    if(r!=sizeof(out)) { fprintf(stderr,"Indicator write or readback failed\n");return 1; }
    for(int i=0;i<40;i++) {
        int actual;
        if(icon_value(h,&actual))return 1;
        if(actual==value)return 0;
        struct timespec delay={0,25000000};nanosleep(&delay,NULL);
    }
    fprintf(stderr,"Indicator write or readback failed\n");return 1;
}
static int restoreIndicator(libusb_device_handle *h,int report,int bit,int previous,unsigned char b[3]) {
    unsigned char out[]={(unsigned char)report,(unsigned char)previous};
    int r=libusb_control_transfer(h,0x21,9,0x200|report,3,out,2,1000);
    if(r!=2) { fprintf(stderr,"RESTORE FAILED: indicator 0x%02x (%d)\n",report,r);return 1; }
    if(feature(h,5,b,3) || ((b[1]>>bit)&1)!=previous) {
        fprintf(stderr,"RESTORE FAILED: indicator 0x%02x readback mismatch\n",report);return 1;
    }
    return 0;
}
int p21_hid(int argc,char **argv) {
    int status=argc==1 && !strcmp(argv[0],"status");
    int report=0,bit=0,icon=argc>0&&!strcmp(argv[0],"softphone-icon");
    if(argc>0)for(size_t i=0;i<sizeof(indicators)/sizeof(*indicators);i++)
        if(!strcmp(argv[0],indicators[i].name)){report=indicators[i].report;bit=indicators[i].bit;}
    if(icon&&(argc!=1&&argc!=2)) {
        fprintf(stderr,"hid: status | mute-indicator|call-indicator|ring-indicator|hold-indicator [on|off] | softphone-icon [zoom|teams]\n"); return 2;
    }
    if(icon&&argc==2) {
        int valid=0;
        for(size_t i=0;i<sizeof(softphones)/sizeof(*softphones);i++)valid|=!strcmp(argv[1],softphones[i].name);
        if(!valid) { fprintf(stderr,"hid: status | mute-indicator|call-indicator|ring-indicator|hold-indicator [on|off] | softphone-icon [zoom|teams]\n"); return 2; }
    }
    if(!status && !icon && (!report || (argc!=1 && argc!=2) ||
        (argc==2 && strcmp(argv[1],"on") && strcmp(argv[1],"off")))) {
        fprintf(stderr,"hid: status | mute-indicator|call-indicator|ring-indicator|hold-indicator [on|off] | softphone-icon [zoom|teams]\n"); return 2;
    }
    libusb_context *ctx;libusb_device_handle *h;
    if(p21_usb_open(0x047f,0x431a,&ctx,&h))return 1;
    int result=0;
    if(status) {
        const int ids[]={1,5,6,0x9a},sizes[]={2,3,12,62};
        for(int i=0;i<4;i++) {
            unsigned char b[62]={0};
            if(feature(h,ids[i],b,sizes[i])) { result=1;continue; }
            printf("feature 0x%02x: ",ids[i]);
            for(int j=0;j<sizes[i];j++)printf("%02x%s",b[j],j+1==sizes[i]?"":" ");putchar('\n');
            if(ids[i]==5)for(size_t j=0;j<sizeof(indicators)/sizeof(*indicators);j++)
                printf("%s=%s\n",indicators[j].name,b[1]&(1<<indicators[j].bit)?"on":"off");
            if(ids[i]==6) {
                const char *name=icon_name(b[10]|(b[11]<<8));
                printf("softphone-icon=%s\n",name?name:"unknown");
            }
        }
    } else if(icon) {
        int before,actual,target=0;
        if(icon_value(h,&before))result=1;
        else {
            if(argc==2) {
                for(size_t i=0;i<sizeof(softphones)/sizeof(*softphones);i++)
                    if(!strcmp(argv[1],softphones[i].name))target=softphones[i].value;
                if(icon_set(h,target)||icon_value(h,&actual)||actual!=target) {
                    fprintf(stderr,"Indicator write or readback failed; restoring %d\n",before);
                    if(icon_set(h,before))fprintf(stderr,"RESTORE FAILED: indicator 0x0d; inspect device\n");
                    result=1;
                } else actual=target;
            } else actual=before;
            if(!result) {
                const char *name=icon_name(actual);
                printf("softphone-icon=%s\n",name?name:"unknown");
            }
        }
    } else {
        // LED page 08 usages; feature 05 mirrors their states in descriptor order.
        unsigned char b[3]={0};
        if(feature(h,5,b,3))result=1;
        else {
            int previous=(b[1]>>bit)&1;
            if(argc==2) {
                unsigned char out[]={(unsigned char)report,!strcmp(argv[1],"on")};
                int r=libusb_control_transfer(h,0x21,9,0x200|report,3,out,2,1000);
                int readback=r==2?feature(h,5,b,3):1;
                if(r!=2 || readback || ((b[1]>>bit)&1)!=out[1]) {
                    fprintf(stderr,"Indicator write or readback failed\n");result=1;
                    restoreIndicator(h,report,bit,previous,b);
                }
            }
            printf("%s=%s\n",argv[0],(b[1]>>bit)&1?"on":"off");
        }
    }
    libusb_close(h);libusb_exit(ctx);return result;
}
