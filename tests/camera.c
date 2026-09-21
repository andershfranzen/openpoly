#define libusb_control_transfer fake_transfer
#include "../src/camera.c"
#include <assert.h>
#include <stdlib.h>

static int current_zoom, requested_zoom, forced_readback, restores;

int fake_transfer(libusb_device_handle *h,uint8_t type,uint8_t request,uint16_t value,
                  uint16_t index,unsigned char *b,uint16_t n,unsigned timeout) {
    (void)h;
    assert(type==(request==1?0x21:0xa1));
    assert(value==11<<8&&index==1<<8&&timeout==1000);
    if(request==0x86){assert(n==1);b[0]=2;return n;}
    assert(n==2);
    int value_out=0;
    if(request==0x82)value_out=10;
    else if(request==0x83)value_out=40;
    else if(request==0x84)value_out=1;
    else if(request==0x87)value_out=10;
    else if(request==0x81)value_out=current_zoom;
    else {
        assert(request==1);
        int wanted=b[0]|(b[1]<<8);
        if(wanted==requested_zoom)current_zoom=forced_readback;
        else { current_zoom=wanted; restores++; }
        return n;
    }
    b[0]=(unsigned char)value_out;b[1]=(unsigned char)(value_out>>8);return n;
}

int p21_integer(const char *text,int64_t min,int64_t max,int64_t *value) {
    char *end=NULL;long long parsed=strtoll(text,&end,10);
    if(!text[0]||*end||parsed<min||parsed>max)return 1;
    *value=parsed;return 0;
}

int p21_usb_open(uint16_t vendor,uint16_t product,libusb_context **context,
                 libusb_device_handle **handle) {
    (void)vendor;(void)product;(void)context;(void)handle;return 1;
}

static int write_zoom(int requested,int actual) {
    current_zoom=10;requested_zoom=requested;forced_readback=actual;restores=0;
    char value[16];snprintf(value,sizeof(value),"%d",requested);char *args[]={value};
    return set((libusb_device_handle *)(uintptr_t)1,&controls[3],args);
}

int main(void) {
    assert(write_zoom(11,10)==0);
    assert(current_zoom==10&&restores==0);
    assert(write_zoom(15,13)==0);
    assert(current_zoom==13&&restores==0);
    assert(write_zoom(20,10)==1);
    assert(current_zoom==10&&restores==1);
    puts("Camera zoom quantized readback and mismatch restoration: passed");
}
