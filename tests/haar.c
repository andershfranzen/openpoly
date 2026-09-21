// SPDX-License-Identifier: GPL-2.0-only
#include "../driver/macos/p21-haar.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc,char **argv) {
    uint8_t *pixels=malloc(1920*1080*4),encoded[P21_HAAR_STRIP_CAPACITY];assert(pixels);
    assert(!p21_haar_strip(NULL,7680,0,0,encoded,sizeof(encoded)));
    assert(!p21_haar_strip(pixels,7679,0,0,encoded,sizeof(encoded)));
    assert(!p21_haar_strip(pixels,7680,1,0,encoded,sizeof(encoded)));
    for(unsigned pattern=0;pattern<7;pattern++) {
        for(unsigned y=0;y<1080;y++)for(unsigned x=0;x<1920;x++) {
            unsigned r=0,g=0,b=0;
            switch(pattern) {
                case 0:r=g=b=0;break;
                case 1:r=g=b=41;break;
                case 2:r=255;break;
                case 3:g=255;break;
                case 4:r=g=b=255;break;
                case 5:r=g=b=x%8<4?0:255;break;
                case 6:r=g=b=((x/8)+8*(y/8))%128;break;
            }
            size_t i=((size_t)y*1920+x)*4;pixels[i]=b;pixels[i+1]=g;pixels[i+2]=r;pixels[i+3]=255;
        }
        size_t n=p21_haar_strip(pixels,7680,0,0,encoded,sizeof(encoded));
        assert(n>=20&&n%4==0&&n<=sizeof(encoded));
        assert(!p21_haar_strip(pixels,7680,0,0,encoded,n-1));
        n=p21_haar_strip(pixels,7680,0,0,encoded,sizeof(encoded));
        if(argc==2&&!strcmp(argv[1],"--vectors"))assert(fwrite(encoded,1,n,stdout)==n);
        assert(p21_haar_strip(pixels,7680,1856,1072,encoded,sizeof(encoded)));
    }
    unsigned random=12345;for(size_t i=0;i<1920*1080*4;i++){random^=random<<13;random^=random>>17;random^=random<<5;pixels[i]=(uint8_t)random;}
    size_t reduced=0;
    for(unsigned y=0;y<1088;y+=16)for(unsigned x=0;x<1920;x+=64){
        size_t n=p21_haar_strip_detail(pixels,7680,x,y,encoded,sizeof(encoded),4);
        assert(n&&n%4==0);reduced+=n;
    }
    assert(reduced<=0x180000-0x24b0);
    free(pixels);return 0;
}
