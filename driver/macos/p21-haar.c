// SPDX-License-Identifier: GPL-2.0-only
// Haar transform and entropy grammar adapted from FireBurn/linux vino-v3,
// drivers/gpu/drm/vino/video/haar/{strip,transform}.rs (GPL-2.0).
// Firefly uses narrow significance/DC and wide AC, with four-byte record alignment.
#include "p21-haar.h"
#include <string.h>
#include <stdlib.h>

typedef struct { uint8_t data[8192]; size_t bits; int failed; } bits;
typedef struct { int q[3][64]; unsigned last[3]; } block;
static void u16(uint8_t *p, unsigned v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
static void bit(bits *b, unsigned v) {
    if (b->bits >= sizeof(b->data)*8) { b->failed=1; return; }
    b->data[b->bits/8] |= (uint8_t)((v&1) << (b->bits%8)); b->bits++;
}
static void unary(bits *b, unsigned count, int terminate, unsigned payload, int wide) {
    if (wide) {
        for (unsigned i=0;i<count;i++) bit(b,1);
        if (terminate) bit(b,0);
        for (unsigned i=count;i>0;i--) bit(b,payload>>(i-1));
    } else {
        for (unsigned i=0;i<count;i++) { bit(b,1);bit(b,payload>>i); }
        if (terminate) bit(b,0);
    }
}
static unsigned category(unsigned v) { unsigned n=0; while(v) { n++;v>>=1; } return n; }
static void escape(bits *b, int value, unsigned maximum, int wide) {
    if (!value) { bit(b,0);return; }
    unsigned magnitude=(unsigned)abs(value),c=category(magnitude);
    if (c>maximum) { c=maximum; magnitude=(1u<<c)-1; }
    unsigned offset=magnitude-(1u<<(c-1));
    unary(b,c,c<maximum,(offset<<1)|(value>0),wide);
}
static void chroma_position(bits *b, unsigned last) {
    if (!last) { bit(b,0);return; }
    unsigned c=category(last+1)-1;
    unary(b,c,1,last-((1u<<c)-1),0);
}
static void significance(bits *b, const block *blk) {
    chroma_position(b,blk->last[0]);chroma_position(b,blk->last[1]);
    unsigned last=blk->last[2],c=last?category(64-last)-1:6;
    unary(b,c,1,64-(1u<<c)-last,0);
}
static void level(const int *src,unsigned n,int *ll,int *hl,int *lh,int *hh) {
    unsigned h=n/2;
    for(unsigned y=0;y<h;y++) for(unsigned x=0;x<h;x++) {
        int a=src[2*y*n+2*x],b=src[2*y*n+2*x+1];
        int c=src[(2*y+1)*n+2*x],d=src[(2*y+1)*n+2*x+1];
        unsigned i=y*h+x;
        ll[i]=a+b+c+d;hl[i]=a-b+c-d;lh[i]=a+b-c-d;hh[i]=a-b-c+d;
    }
}
static void transform(const int *src,int *out) {
    int ll1[16],hl1[16],lh1[16],hh1[16],ll2[4],hl2[4],lh2[4],hh2[4];
    int ll3,hl3,lh3,hh3;
    static const unsigned scan[16]={0,2,8,10,1,3,9,11,4,6,12,14,5,7,13,15};
    level(src,8,ll1,hl1,lh1,hh1);level(ll1,4,ll2,hl2,lh2,hh2);level(ll2,2,&ll3,&hl3,&lh3,&hh3);
    out[0]=ll3>>6;out[1]=hl3>>6;out[2]=lh3>>6;out[3]=hh3>>6;
    for(unsigned i=0;i<4;i++){out[4+i]=hl2[i]>>6;out[8+i]=lh2[i]>>6;out[12+i]=hh2[i]>>6;}
    for(unsigned i=0;i<16;i++){out[16+i]=hl1[scan[i]]>>6;out[32+i]=lh1[scan[i]]>>6;out[48+i]=hh1[scan[i]]>>6;}
}
static int quantize(int v,unsigned plane,unsigned i) {
    if (!i) return (v+(plane==2?8:32))>>(plane==2?4:6);
    if (plane!=2) {
        unsigned shift=i==3|| (i>=12&&i<48) ? 5 : i>=48 ? 6 : 4;
        return (v+(1<<(shift-1)))>>shift;
    }
    if(i<3) return (v+8)>>4;
    if(i==3) return (v+16)>>5;
    if(i<12) return (v+2)>>2;
    if(i<16) return (v+4)>>3;
    if(i<48) return v/2; // This band truncates towards zero, including negative values.
    return (v+2)>>2;
}
static void gather(const uint8_t *src,size_t stride,unsigned x,unsigned y,block *blk,unsigned limit) {
    int samples[3][64],coefficients[64];
    memset(blk,0,sizeof(*blk));
    for(unsigned row=0;row<8;row++) for(unsigned col=0;col<8;col++) {
        unsigned yy=y+row;if(yy>=1080)yy=1079;
        const uint8_t *p=src+yy*stride+(x+col)*4;
        int b=p[0],g=p[1],r=p[2],i=(int)(row*8+col);
        samples[0][i]=64*(b-g);samples[1][i]=64*(r-g);
        samples[2][i]=64*g+64*((r+b-2*g)>>2);
    }
    for(unsigned plane=0;plane<3;plane++) {
        transform(samples[plane],coefficients);
        for(unsigned i=0;i<64;i++) {
            blk->q[plane][i]=i<limit?quantize(coefficients[i],plane,i):0;
            if(i&&blk->q[plane][i])blk->last[plane]=i;
        }
    }
}
size_t p21_haar_strip_detail(const uint8_t *src,size_t stride,unsigned x,unsigned y,uint8_t *out,size_t cap,unsigned limit) {
    if(limit!=4&&limit!=64)return 0;
    if(!src||!out||stride<1920*4||stride>32768||x>=1920||y>=1088||x%64||y%16)return 0;
    block blocks[16];bits main={0},rows[2]={{0},{0}};
    for(unsigned k=0;k<16;k++) { gather(src,stride,x+(k%8)*8,y+(k/8)*8,&blocks[k],limit);significance(&main,&blocks[k]); }
    int previous[3]={0};
    for(unsigned k=0;k<16;k++) for(unsigned plane=0;plane<3;plane++) {
        int dc=blocks[k].q[plane][0];escape(&main,dc-previous[plane],10,0);previous[plane]=dc;
    }
    for(unsigned k=0;k<16;k++) for(unsigned plane=0;plane<3;plane++)
        for(unsigned i=1;i<=blocks[k].last[plane];i++) escape(&rows[k/8],blocks[k].q[plane][i],plane==2?9:10,1);
    if(main.failed||rows[0].failed||rows[1].failed)return 0;
    size_t mainBytes=(main.bits+7)/8,row0Bytes=(rows[0].bits+7)/8,row1Bytes=(rows[1].bits+7)/8;
    size_t offset0=16+((mainBytes+1)&~(size_t)1)+2,offset1=offset0+((row0Bytes+1)&~(size_t)1);
    size_t total=(offset1+((row1Bytes+1)&~(size_t)1)+2+3)&~(size_t)3,body=total-2;
    if(total>cap||body>65535)return 0;
    memset(out,0,total);u16(out,(unsigned)body);u16(out+2,0x2801);u16(out+4,x);u16(out+6,y);
    u16(out+12,(unsigned)offset0);u16(out+14,(unsigned)offset1);
    memcpy(out+18,main.data,mainBytes);memcpy(out+2+offset0,rows[0].data,row0Bytes);memcpy(out+2+offset1,rows[1].data,row1Bytes);
    return total;
}
size_t p21_haar_strip(const uint8_t *src,size_t stride,unsigned x,unsigned y,uint8_t *out,size_t cap) {
    return p21_haar_strip_detail(src,stride,x,y,out,cap,64);
}
