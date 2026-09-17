#define libusb_control_transfer fake_transfer
#define nanosleep fake_sleep
#define clock_gettime fake_clock_gettime
#include "../src/lights.c"
#include <assert.h>

static unsigned char registers[2][15],native_baseline[2][15],reply[62],mux=4,mode;
static int fail_write,echo_write,writes,switch_mux,mode_sets,native_bottom,mode_ack;
static int fail_timeout,fail_get_timeout,fault_at,transfers,after_fault,rgb_updates;
static int native_stream,phase_attempts,phase_count,bridges_since_phase,native_errors,fail_native_timeout;
static unsigned char phases[16];
static unsigned char stale_reply[62];
static int retain_one,stale_pending,stale_mux,stale_manual;
static double mock_time;
int fake_sleep(const struct timespec *requested,struct timespec *remaining) {
    mock_time+=requested->tv_sec+requested->tv_nsec/1e9;(void)remaining;return 0;
}
int fake_clock_gettime(clockid_t clock,struct timespec *value) {
    assert(clock==CLOCK_MONOTONIC);value->tv_sec=(time_t)mock_time;
    value->tv_nsec=(long)((mock_time-value->tv_sec)*1e9);return 0;
}
int fake_transfer(libusb_device_handle *h,uint8_t type,uint8_t request,uint16_t value,
                  uint16_t index,unsigned char *b,uint16_t n,unsigned timeout) {
    (void)h;assert(index==3&&timeout==1000&&n==62);
    transfers++;
    if(fault_at){after_fault++;return LIBUSB_ERROR_NO_DEVICE;}
    if(type==0xa1){
        assert(request==1&&value==0x1de);
        if(fail_get_timeout){fail_get_timeout=0;fault_at=transfers;return LIBUSB_ERROR_TIMEOUT;}
        if(stale_pending){stale_pending=0;memcpy(b,stale_reply,62);return n;}
        memcpy(b,reply,62);return n;
    }
    assert(type==0x21&&request==9&&value==0x2de);
    const unsigned char *payload=b+11;
    if(retain_one&&b[8]==5&&b[9]==3&&b[10]==0x1b&&
       payload[13]==3&&payload[14]!=0x76&&payload[17]==1){
        // GET_REPORT may retain the preceding reply until this read completes.
        memcpy(stale_reply,reply,62);stale_pending=1;
        if(reply[8]==10&&reply[9]==3&&reply[10]==0x1b){
            assert(reply[4]==11&&reply[15]==4);stale_mux++;
        }
        if(reply[8]==3&&reply[9]==4&&reply[10]==0x26)stale_manual++;
    }
    memset(reply,0,62);memcpy(reply,b,11);
    if(b[8]==2&&b[9]==4&&b[10]==0x26){reply[8]=3;reply[4]=7;return n;}
    if(b[9]==3&&b[10]==0){
        if(b[8]==2){
            assert(b[4]==6);reply[8]=mode?3:4;reply[4]=mode?7:8;
            if(mode)reply[11]=1;else {reply[11]=0;reply[12]=0x12;}
        }else {
            assert(b[8]==5&&b[4]==7&&b[11]<=1);mode_sets++;
            int changed=mode!=b[11];mode=b[11];
            reply[8]=changed&&!mode_ack?10:6;reply[4]=changed&&!mode_ack?7:6;
            if(changed&&!mode_ack)reply[11]=mode;
        }
        return n;
    }
    if(b[8]==5&&b[9]==3&&b[10]==0x17){
        // Reacquire through the firmware's bottom selector, never the side selectors.
        assert(mode&&b[4]==9&&b[11]==0x12);native_bottom++;
        if(b[12]==8){
            assert(b[13]==10);
            for(int c=0;c<2;c++){
                registers[c][2]=0x82;memset(registers[c]+3,19,6);
                memset(registers[c]+9,0x88,6);
            }
            memcpy(native_baseline,registers,sizeof(native_baseline));
        }else {
            assert(native_stream&&b[13]==100&&(b[12]==2||b[12]==1||b[12]==4));
            if(phase_count>=2)assert(bridges_since_phase==0);
            bridges_since_phase=0;phase_attempts++;
            if(native_errors){native_errors--;reply[8]=7;reply[4]=8;reply[12]=0x12;return n;}
            const unsigned char colors[]={2,1,4},rgb[3][3]={{143,0,0},{7,80,15},{5,5,112}};
            int phase=b[12]==2?0:b[12]==1?1:2;
            assert(b[12]==colors[phase]);
            for(int c=0;c<2;c++){
                unsigned char config=registers[c][2];memcpy(registers[c]+3,rgb[phase],3);
                memset(registers[c]+9,0x88,6);assert(registers[c][2]==config);
            }
            if(fail_native_timeout&&!--fail_native_timeout){fault_at=transfers;return LIBUSB_ERROR_TIMEOUT;}
            assert(phase_count<(int)sizeof(phases));phases[phase_count++]=b[12];
        }
        mux=4;reply[8]=6;reply[4]=6;return n;
    }
    assert(b[8]==5&&b[9]==3&&b[10]==0x1b);
    if(native_stream)bridges_since_phase++;
    unsigned char *p=b+11;assert(!memcmp(p,"\0\0I2C\0\0\0\0\0\0\0\0",13));
    int address=p[14],reg=p[15],count=p[17];assert(p[13]==3||p[13]==4);
    assert(p[18]==0&&p[19]==0&&count>=1&&count<=15);
    if(p[13]==3){
        reply[8]=10;reply[4]=10+count;memcpy(reply+11,"\0\1I2",4);
        if(address==0x76){assert(reg==0&&count==1&&p[16]==0);reply[15]=mux;}
        else {assert(mux==4&&(address==0x69||address==0x6a));assert(p[16]==1&&reg+count<=15);
            memcpy(reply+15,registers[address-0x69]+reg,count);}
    }else {
        assert(mux==4&&(address==0x69||address==0x6a));assert(reg>=2&&reg+count<=15&&p[16]==1);
        memcpy(registers[address-0x69]+reg,p+20,count);writes++;
        if(count==3){assert(reg==3);rgb_updates++;}
        if(switch_mux){switch_mux=0;mux=1;}
        if(fail_timeout){fail_timeout=0;fault_at=transfers;return LIBUSB_ERROR_TIMEOUT;}
        if(fail_write){fail_write=0;return LIBUSB_ERROR_IO;}
        if(echo_write){reply[8]=10;memcpy(reply+11,p,20+count);}
        else {reply[8]=6;reply[4]=11;memcpy(reply+11,"\0\1I2\1",5);}
    }
    return n;
}
int main(void) {
    libusb_device_handle *h=(libusb_device_handle *)(uintptr_t)1;
    unsigned char before[2][15];
    for(int c=0;c<2;c++){registers[c][0]=0xa4;registers[c][2]=0x82;
        memset(registers[c]+3,30,6);memset(registers[c]+9,0x88,6);}
    memcpy(before,registers,sizeof(before));
    char *rgb[]={"rgb","255","0","128"};
    assert(bar_control(NULL,4,rgb)==0);
    assert(bar_control(h,4,rgb)==0);
    for(int c=0;c<2;c++){assert(registers[c][3]==192&&registers[c][4]==0&&registers[c][5]==96);
        assert(registers[c][2]==0x82);}
    echo_write=1;assert(bar_control(h,4,rgb)==0);
    memcpy(registers,before,sizeof(before));fail_write=1;
    assert(bar_control(h,4,rgb)==1&&!memcmp(registers,before,sizeof(before)));
    // Regression: startup/normal firmware activity may leave a different mux channel.
    // A native bottom command must reacquire channel 04 and restore its prior gate.
    unsigned char initial_mux[]={8,1};
    for(int i=0;i<2;i++){
        mux=initial_mux[i];mode=(unsigned char)i;int previous_native=native_bottom;
        int previous_mode_sets=mode_sets;
        assert(bar_control(h,4,rgb)==0);
        assert(mux==4&&mode==i&&native_bottom>previous_native);
        if(!i)assert(mode_sets>=previous_mode_sets+2);
    }
    unsigned char test_rgb[]={1,2,3};switch_mux=1;
    assert(bar_write(h,0,3,test_rgb,3)!=0);mux=4;memcpy(registers,before,sizeof(before));
    fail_timeout=1;
    assert(bar_control(h,4,rgb)==1&&fault_at&&transfers==fault_at&&after_fault==0);
    fault_at=0;br_usb_error=0;memcpy(registers,before,sizeof(before));
    int previous_writes=writes;fail_get_timeout=1;
    assert(bar_control(h,4,rgb)==1&&fault_at&&transfers==fault_at&&after_fault==0&&writes==previous_writes);
    fault_at=0;br_usb_error=0;
    char *palette[]={"palette","2","255","0","0","0","0","255","888888ffffff"};
    assert(bar_control(h,9,palette)==0&&!memcmp(registers[0],before[0],15));
    assert(registers[1][3]==192&&registers[1][8]==192&&registers[1][12]==0xff);
    char *fade[]={"fade","7"};retain_one=1;
    assert(bar_control(h,2,fade)==0&&registers[0][2]==0x87);
    assert(stale_manual>0&&stale_mux==0);retain_one=0;
    memcpy(registers,before,sizeof(before));mode=0;native_stream=1;
    phase_attempts=phase_count=bridges_since_phase=0;int previous_updates=rgb_updates;
    char *cycle[]={"cycle","30","30"};
    assert(bar_control(h,3,cycle)==0&&phase_count==3&&phase_attempts==3&&mode==0);
    assert(phases[0]==2&&phases[1]==1&&phases[2]==4&&rgb_updates==previous_updates);
    assert(!memcmp(registers,before,sizeof(before)));native_stream=0;
    mux=8;mode=0;
    char *timed_rgb[]={"rgb","255","0","128","1"};
    assert(bar_control(h,5,timed_rgb)==0&&mode==0);
    assert(!memcmp(registers,native_baseline,sizeof(registers))&&memcmp(registers,before,sizeof(before)));
    memcpy(registers,before,sizeof(before));mux=4;mode=0;
    native_stream=1;phase_attempts=phase_count=bridges_since_phase=0;native_errors=2;
    char *retry_cycle[]={"cycle","3","30"};
    assert(bar_control(h,3,retry_cycle)==0&&phase_attempts==3&&phase_count==1&&mode==0);
    assert(!memcmp(registers,before,sizeof(before)));
    phase_attempts=phase_count=bridges_since_phase=0;native_errors=3;
    assert(bar_control(h,3,retry_cycle)==1&&phase_attempts==3&&phase_count==0&&mode==0);
    assert(!memcmp(registers,before,sizeof(before)));
    phase_attempts=phase_count=bridges_since_phase=0;fail_native_timeout=2;
    assert(bar_control(h,3,cycle)==1&&fault_at&&transfers==fault_at&&after_fault==0&&mode==1);
    fault_at=0;br_usb_error=0;native_stream=0;mode=0;memcpy(registers,before,sizeof(before));
    mux=8;int previous_native=native_bottom;previous_writes=writes;
    char *state[]={"bar-state"};
    assert(bar_control(h,1,state)==1&&bar_control(h,2,fade)==1&&bar_control(h,9,palette)==1);
    assert(native_bottom==previous_native&&writes==previous_writes);mux=4;
    rgb[1]="256";assert(bar_control(NULL,4,rgb)==2);
    palette[8]="888888gggggg";assert(bar_control(NULL,9,palette)==2);
    unsigned char color[3];bar_hue(0,color);assert(color[0]==192&&color[1]==0&&color[2]==0);
    bar_hue(512,color);assert(color[0]==0&&color[1]==192&&color[2]==0);
    bar_hue(1024,color);assert(color[0]==0&&color[1]==0&&color[2]==192);
    puts("Bottom bridge framing, RGB scaling, palette, fade, restoration and native channel reacquisition: passed");
}
