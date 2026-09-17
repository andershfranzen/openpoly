#define libusb_control_transfer fake_transfer
#define libusb_close fake_close
#define libusb_exit fake_exit
#define p21_usb_open fake_open
#include "../src/hid.c"
#include <assert.h>

static unsigned state, expected_report, expected_mask, writes;
static int fail_write, icon_state, icon_writes, fail_icon_write;
int fake_open(uint16_t vendor,uint16_t product,libusb_context **ctx,libusb_device_handle **h) {
    assert(vendor==0x047f && product==0x431a);*ctx=NULL;*h=NULL;return 0;
}
void fake_close(libusb_device_handle *h){(void)h;}
void fake_exit(libusb_context *ctx){(void)ctx;}
int fake_transfer(libusb_device_handle *h,uint8_t type,uint8_t request,uint16_t value,
                  uint16_t index,unsigned char *b,uint16_t n,unsigned int timeout) {
    (void)h;assert(index==3 && timeout==1000);
    if(type==0xa1) {
        assert(request==1 && (value==0x305 || value==0x306));
        if(value==0x306) {
            assert(n==12);b[0]=6;b[10]=(unsigned char)(icon_state&255);b[11]=(unsigned char)(icon_state>>8);return n;
        }
        assert(n==3);
        b[0]=5;b[1]=(unsigned char)state;b[2]=(unsigned char)(state>>8);return n;
    }
    if(value==(0x200|0x0d)) {
        assert(type==0x21 && request==9 && n==4 && b[0]==0x0d && b[1]==0);
        icon_state=b[2]|(b[3]<<8);++icon_writes;
        if(fail_icon_write){fail_icon_write=0;return LIBUSB_ERROR_IO;}
        return n;
    }
    assert(type==0x21 && request==9 && value==(0x200|expected_report));
    assert(n==2 && b[0]==expected_report && b[1]<=1);
    state=b[1]?state|expected_mask:state&~expected_mask;++writes;
    if(fail_write){fail_write=0;return LIBUSB_ERROR_IO;}
    return n;
}
int main(void) {
    const struct {char *name;unsigned report,mask;} cases[]={
        {"mute-indicator",9,4},{"call-indicator",0x17,8},
        {"ring-indicator",0x18,16},{"hold-indicator",0x20,32}
    };
    for(size_t i=0;i<sizeof(cases)/sizeof(*cases);i++) {
        expected_report=cases[i].report;expected_mask=cases[i].mask;
        unsigned before=0x0e02;state=before;writes=0;
        char *on[]={cases[i].name,"on"},*off[]={cases[i].name,"off"};
        assert(p21_hid(2,on)==0 && state==(before|expected_mask) && writes==1);
        assert(p21_hid(2,off)==0 && state==before && writes==2);
        fail_write=1;writes=0;
        assert(p21_hid(2,on)!=0 && state==before && writes==2);
    }
    icon_state=22;icon_writes=0;
    // icon_set polls for the async firmware update; the fake applies it
    // synchronously, so the first readback already matches.
    char *read[]={"softphone-icon"},*teams[]={"softphone-icon","teams"},*zoom[]={"softphone-icon","zoom"};
    char *bad[]={"softphone-icon","slack"};
    assert(p21_hid(1,read)==0 && icon_writes==0);
    assert(p21_hid(2,teams)==0 && icon_state==23 && icon_writes==1);
    assert(p21_hid(2,zoom)==0 && icon_state==22 && icon_writes==2);
    assert(p21_hid(2,bad)==2 && icon_writes==2);
    fail_icon_write=1;icon_writes=0;icon_state=22;
    assert(p21_hid(2,teams)!=0 && icon_state==22 && icon_writes==2);
    puts("HID indicator wire mapping, unrelated bits and failed-write restoration: passed");
    puts("softphone-icon output packing, names and failed-write restoration: passed");
}
