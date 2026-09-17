#include <assert.h>
#include "../src/camera.c"
#include "../src/lights.c"
int main(void) {
    int64_t n;
    assert(p21_integer("-128",-128,128,&n)==0 && n==-128);
    assert(p21_integer("128",-128,128,&n)==0 && n==128);
    assert(p21_integer("129",-128,128,&n)!=0);
    assert(p21_integer("",0,255,&n)!=0);
    assert(p21_integer("12x",0,255,&n)!=0);
    assert(p21_integer("999999999999999999999999",0,255,&n)!=0);
    const unsigned char neg16[]={0x80,0xff};
    const unsigned char neg32[]={0x60,0x73,0xff,0xff};
    assert(decode(neg16,2,1)==-128);
    assert(decode(neg16,2,0)==65408);
    assert(decode(neg32,4,1)==-36000);
    assert(decode((unsigned char[]){0xa0,0x8c,0,0},4,1)==36000);
    assert(br_send(NULL,2,0xe34,NULL,-1)==1);
    assert(br_send(NULL,2,0xe34,NULL,52)==1);
    assert(br_send(NULL,2,0xe34,NULL,1)==1);
    unsigned char report[62]={0xde,1,1,0x10,9,0,0,0,3,0x0e,0x34,0x13,0xff,50}, payload[51];
    assert(br_parse(report,62,3,0xe34,payload)==3 && payload[2]==50);
    assert(br_parse(report,14,3,0xe34,payload)==-1);
    assert(br_parse(report,62,3,0x426,payload)==-2);
    report[4]=58; assert(br_parse(report,62,3,0xe34,payload)==-1);
    report[4]=8;report[8]=4;assert(br_parse(report,62,3,0xe34,payload)==-3);
    report[8]=6;assert(br_parse(report,62,3,0xe34,payload)==-2);
    puts("BR framing, truncation, unrelated replies and errors: passed");
    puts("integer boundaries and UVC signed decoding: passed");
}
