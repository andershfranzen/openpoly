#define libusb_control_transfer fake_transfer
#define nanosleep fake_sleep
#include "../src/lights.c"
#include <assert.h>

static unsigned char registers[3][3][15],reply[62],mux,mode;
static int mode_ack,mode_sets,side_sets,reads[2][3],fail_side,bad_register,bad_id;
static int mode_error,invalid_mode,bad_echo,wrong_mux;

int fake_sleep(const struct timespec *requested,struct timespec *remaining) {
    (void)requested;(void)remaining;return 0;
}
static void frame(const unsigned char *request,int type,int size) {
    memset(reply,0,sizeof(reply));memcpy(reply,request,11);
    reply[8]=(unsigned char)type;reply[4]=(unsigned char)(6+size);
}
int fake_transfer(libusb_device_handle *h,uint8_t type,uint8_t request,uint16_t value,
                  uint16_t index,unsigned char *b,uint16_t n,unsigned timeout) {
    assert(h&&index==3&&timeout==1000&&n==62);
    if(type==0xa1){assert(request==1&&value==0x1de);memcpy(b,reply,62);return n;}
    assert(type==0x21&&request==9&&value==0x2de);
    assert(b[0]==0xde&&b[1]==1&&b[2]==1&&b[3]==0x10&&!b[5]&&!b[6]&&!b[7]);
    int command=(b[9]<<8)|b[10],size=b[4]-6;unsigned char *p=b+11;
    if(b[8]==2&&command==0x426){assert(size==0);frame(b,3,1);reply[11]=0;return n;}
    if(command==0x300){
        if(b[8]==2){
            assert(size==0);frame(b,mode?3:4,mode?1:2);
            if(mode)reply[11]=invalid_mode?2:1;else {reply[11]=0;reply[12]=(unsigned char)mode_error;}
        }else {
            assert(b[8]==5&&size==1&&p[0]<=1);mode_sets++;
            int changed=mode!=p[0];mode=p[0];
            frame(b,changed&&!mode_ack?10:6,changed&&!mode_ack?1:0);
            if(changed&&!mode_ack)reply[11]=(unsigned char)(mode^(bad_echo&&mode));
        }
        return n;
    }
    if(command==0x317){
        assert(b[8]==5&&size==3&&mode&&p[1]==8&&(p[0]==0x13||p[0]==0x14));
        assert(p[2]<=100&&p[2]%10==0);side_sets++;
        assert(p[0]==(side_sets==1?0x14:0x13)); // Left/right as the user faces the screen.
        if(fail_side&&!--fail_side)return LIBUSB_ERROR_IO;
        int channel=p[0]-0x13;unsigned char intensity=(unsigned char)(192*p[2]/100);
        for(int c=0;c<3;c++){
            if(p[2])memset(registers[channel][c]+3,intensity,6);
            memset(registers[channel][c]+9,p[2]?0x88:0,6);
        }
        mux=wrong_mux?4:(unsigned char)(1<<channel);frame(b,6,0);return n;
    }
    assert(b[8]==5&&command==0x31b&&size==20);
    assert(!memcmp(p,"\0\0I2C\0\0\0\0\0\0\0\0",13));
    assert(p[13]==3&&p[18]==0&&p[19]==0); // Side verification must never write I2C.
    int address=p[14],reg=p[15],count=p[17];assert(count>=1&&reg+count<=15);
    frame(b,10,count+4);memcpy(reply+11,"\0\1I2",4);
    if(address==0x76){assert(reg==0&&count==1&&p[16]==0);reply[15]=mux;}
    else {
        assert(address>=0x69&&address<=0x6a&&p[16]==1&&(mux==1||mux==2));
        int channel=mux==1?0:1,chip=address-0x69;reads[channel][chip]++;
        memcpy(reply+15,registers[channel][chip]+reg,count);
        if(bad_register&&reg<=3&&reg+count>3)reply[15+3-reg]^=1;
        if(bad_id&&reg==0)reply[15]=0;
    }
    return n;
}
static void reset(unsigned char prior_mode) {
    memset(registers,0,sizeof(registers));memset(reply,0,sizeof(reply));
    memset(reads,0,sizeof(reads));mode=prior_mode;mux=4;
    mode_ack=mode_sets=side_sets=fail_side=bad_register=bad_id=0;
    invalid_mode=bad_echo=wrong_mux=0;mode_error=0x12;
    for(int s=0;s<3;s++)for(int c=0;c<3;c++){
        registers[s][c][0]=0xa4;registers[s][c][2]=0x82;
        memset(registers[s][c]+3,30,6);memset(registers[s][c]+9,0x88,6);
    }
}
static void expected(int side,int brightness) {
    side=1-side;
    for(int c=0;c<3;c++){
        assert((c==2||reads[side][c]>0)&&registers[side][c][2]==0x82);
        for(int r=3;r<9;r++)if(brightness)assert(registers[side][c][r]==192*brightness/100);
        for(int r=9;r<15;r++)assert(registers[side][c][r]==(brightness?0x88:0));
    }
}
int main(void) {
    libusb_device_handle *h=(libusb_device_handle *)(uintptr_t)1;
    unsigned char bottom[3][15];reset(0);memcpy(bottom,registers[2],sizeof(bottom));
    assert(side_control(h,21,99)==0&&mode==0&&mode_sets==2&&side_sets==2);
    expected(0,30);expected(1,100);assert(!memcmp(bottom,registers[2],sizeof(bottom)));
    reset(1);assert(side_control(h,50,30)==0&&mode==1&&mode_sets==2);expected(0,50);expected(1,30);
    reset(0);mode_ack=1;assert(side_control(h,10,10)==0&&mode==0&&mode_sets==2);
    reset(0);assert(side_control(h,0,0)==0&&mode==0);expected(0,0);expected(1,0);
    reset(0);fail_side=1;assert(side_control(h,50,50)==1&&mode==0&&mode_sets==2);
    reset(0);fail_side=2;assert(side_control(h,80,100)==1&&mode==0&&mode_sets==2&&side_sets==2);
    expected(0,80);assert(registers[0][0][3]==30);
    reset(0);bad_register=1;assert(side_control(h,50,50)==1&&mode==0&&mode_sets==2);
    reset(1);bad_id=1;assert(side_control(h,50,50)==1&&mode==1&&mode_sets==2);
    reset(0);mode_error=0x13;assert(side_control(h,50,50)==1&&mode_sets==0&&side_sets==0);
    reset(1);invalid_mode=1;assert(side_control(h,50,50)==1&&mode_sets==0&&side_sets==0);
    reset(0);bad_echo=1;assert(side_control(h,50,50)==1&&mode==0&&mode_sets==2&&side_sets==0);
    reset(0);wrong_mux=1;assert(side_control(h,50,50)==1&&mode==0&&mode_sets==2);
    puts("Side gate responses/restoration, native packets, rounding and readback: passed");
}
