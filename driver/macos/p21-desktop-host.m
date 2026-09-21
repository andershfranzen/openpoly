// SPDX-License-Identifier: GPL-2.0-only
#import "CGVirtualDisplayPrivate.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#include "p21-haar.h"
#include <stdatomic.h>
#include <signal.h>
#include <stdio.h>

@interface DesktopFrames : NSObject <SCStreamOutput>
- (CVPixelBufferRef)copyLatestAfter:(unsigned)previous number:(unsigned *)number CF_RETURNS_RETAINED;
@end
@implementation DesktopFrames {
    NSCondition *_lock;
    CVPixelBufferRef _latest;
    unsigned _number;
}
- (instancetype)init { if ((self=[super init])) _lock=[NSCondition new];return self; }
- (void)dealloc { if (_latest) CVPixelBufferRelease(_latest); }
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type!=SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments=(__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample,false);
    NSNumber *status=attachments.firstObject[SCStreamFrameInfoStatus];
    if(status && status.integerValue!=SCFrameStatusComplete)return;
    CVPixelBufferRef p=CMSampleBufferGetImageBuffer(sample);
    if (!p || CVPixelBufferGetWidth(p)!=1920 || CVPixelBufferGetHeight(p)!=1080 ||
        CVPixelBufferGetPixelFormatType(p)!=kCVPixelFormatType_32BGRA) return;
    CVPixelBufferRetain(p);
    [_lock lock];CVPixelBufferRef old=_latest;_latest=p;_number++;[_lock broadcast];[_lock unlock];
    if(old)CVPixelBufferRelease(old);
}
- (CVPixelBufferRef)copyLatestAfter:(unsigned)previous number:(unsigned *)number {
    [_lock lock];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:0.25];
    while(_number==previous)if(![_lock waitUntilDate:deadline])break;
    CVPixelBufferRef p=_number==previous?NULL:_latest;
    if(p)CVPixelBufferRetain(p);*number=_number;[_lock unlock];return p;
}
@end

static void put32(uint8_t *b,uint32_t n) { for(unsigned i=0;i<4;i++)b[i]=(uint8_t)(n>>(8*i)); }
typedef struct { uint8_t *previous;uint8_t *strips[2040];size_t sizes[2040];unsigned lastNumber,detail; } FrameCache;
static int sendFrame(DesktopFrames *sink,FrameCache *cache,uint8_t *encoded,size_t capacity,unsigned detail) {
    unsigned number=0;CVPixelBufferRef pixels=[sink copyLatestAfter:cache->lastNumber number:&number];size_t used=0;
    if(pixels) {
        if(CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly)!=kCVReturnSuccess) { CVPixelBufferRelease(pixels);return -1; }
        const uint8_t *src=CVPixelBufferGetBaseAddress(pixels);size_t stride=CVPixelBufferGetBytesPerRow(pixels);
        __block _Atomic int failed=0;
        // Eight independent ranges share immutable input and own disjoint cache
        // entries. A full repaint can use several cores without queueing frames.
        dispatch_apply(8,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t range){
            for(unsigned index=(unsigned)range*255;index<(range+1)*255;index++) {
                unsigned x=index%30*64,y=index/30*16;int changed=!cache->sizes[index]||cache->detail!=detail;
                for(unsigned row=0;row<16&&!changed;row++) {
                    unsigned yy=y+row;if(yy>=1080)yy=1079;
                    changed=memcmp(src+yy*stride+x*4,cache->previous+yy*7680+x*4,256)!=0;
                }
                if(changed) {
                    uint8_t strip[P21_HAAR_STRIP_CAPACITY];
                    size_t n=p21_haar_strip_detail(src,stride,x,y,strip,sizeof(strip),detail);
                    if(!n){atomic_store(&failed,1);break;}
                    uint8_t *allocation=realloc(cache->strips[index],n);
                    if(!allocation){atomic_store(&failed,1);break;}
                    cache->strips[index]=allocation;cache->sizes[index]=n;memcpy(allocation,strip,n);
                }
            }
        });
        for(unsigned index=0;index<2040&&!atomic_load(&failed);index++){
            size_t n=cache->sizes[index];if(n>capacity-used){atomic_store(&failed,1);break;}
            memcpy(encoded+used,cache->strips[index],n);used+=n;
        }
        if(!atomic_load(&failed)){for(unsigned row=0;row<1080;row++)memcpy(cache->previous+row*7680,src+row*stride,7680);cache->lastNumber=number;cache->detail=detail;}
        CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);CVPixelBufferRelease(pixels);
        if(atomic_load(&failed))return -1;
    }
    uint8_t header[16]="P21FRAM1";put32(header+8,(uint32_t)used);put32(header+12,number);
    if(fwrite(header,1,16,stdout)!=16 || (used&&fwrite(encoded,1,used,stdout)!=used) || fflush(stdout))return -1;
    return 0;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        unsigned seconds=60,width=1920,height=1080,refreshHz=60;
        if(argc!=1&&argc!=2&&argc!=5)return 2;
        unsigned *values[]={&seconds,&width,&height,&refreshHz};
        for(int i=1;i<argc;i++) {
            char *end=NULL;long n=strtol(argv[i],&end,10);
            if(end==argv[i]||*end||n<0||n>3600)return 2;*values[i-1]=(unsigned)n;
        }
        if(!((width==1920&&height==1080)||(width==1600&&height==900)||
             (width==1280&&height==720)||(width==960&&height==540))||
           (refreshHz!=60&&refreshHz!=30))return 2;
        signal(SIGPIPE,SIG_IGN);
        CGVirtualDisplayDescriptor *descriptor=[CGVirtualDisplayDescriptor new];
        descriptor.name=@"Poly Studio P21 — OpenPoly";
        descriptor.maxPixelsWide=1920;descriptor.maxPixelsHigh=1080;
        descriptor.sizeInMillimeters=CGSizeMake(527,296);descriptor.vendorID=0x4199;
        descriptor.productID=1;descriptor.serialNum=0x503231;descriptor.queue=dispatch_get_main_queue();
        CGVirtualDisplay *display=[[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        CGVirtualDisplaySettings *settings=[CGVirtualDisplaySettings new];settings.hiDPI=0;
        settings.modes=@[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:refreshHz]];
        if(!display||![display applySettings:settings]) { fputs("cannot create virtual display\n",stderr);return 1; }
        __block SCDisplay *target=nil;__block NSError *error=nil;
        for(unsigned attempt=0;attempt<30&&!target;attempt++) {
            dispatch_semaphore_t ready=dispatch_semaphore_create(0);
            [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *e) {
                error=e;for(SCDisplay *d in content.displays)if(d.displayID==display.displayID)target=d;dispatch_semaphore_signal(ready);
            }];
            if(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC)))return 1;
            if(error)break;
            if(!target)[NSThread sleepForTimeInterval:0.1];
        }
        if(!target) { fprintf(stderr,"display capture unavailable: %s\n",error.localizedDescription.UTF8String?:"display discovery timed out");return 1; }
        SCContentFilter *filter=[[SCContentFilter alloc] initWithDisplay:target excludingWindows:@[]];
        SCStreamConfiguration *cfg=[SCStreamConfiguration new];cfg.width=1920;cfg.height=1080;
        cfg.scalesToFit=YES;
        cfg.minimumFrameInterval=CMTimeMake(1,refreshHz);cfg.pixelFormat=kCVPixelFormatType_32BGRA;
        cfg.queueDepth=3;cfg.showsCursor=YES;cfg.capturesAudio=NO;
        SCStream *stream=[[SCStream alloc] initWithFilter:filter configuration:cfg delegate:nil];
        DesktopFrames *sink=[DesktopFrames new];
        if(![stream addStreamOutput:sink type:SCStreamOutputTypeScreen sampleHandlerQueue:dispatch_queue_create("openpoly.frames",DISPATCH_QUEUE_SERIAL) error:&error])return 1;
        dispatch_semaphore_t started=dispatch_semaphore_create(0);
        [stream startCaptureWithCompletionHandler:^(NSError *e){error=e;dispatch_semaphore_signal(started);}];
        if(dispatch_semaphore_wait(started,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))||error)return 1;
        fprintf(stderr,"openpoly virtual display %u ready at %ux%u %uHz, panel 1920x1080 60Hz\n",display.displayID,width,height,refreshHz);
        _Atomic int *done=calloc(1,sizeof(*done));if(!done)return 1;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            @autoreleasepool {
                size_t capacity=16*1024*1024;uint8_t *encoded=malloc(capacity);
                FrameCache *cache=calloc(1,sizeof(*cache));if(cache)cache->previous=malloc(1920*1080*4);
                if(encoded&&cache&&cache->previous) {
                    char command[16];
                    while(fgets(command,sizeof(command),stdin)) {
                        unsigned detail=64;
                        if(!strcmp(command,"L\n")){detail=4;cache->lastNumber=0;}
                        else if(!strcmp(command,"R\n"))cache->lastNumber=0;
                        else if(strcmp(command,"F\n"))break;
                        if(sendFrame(sink,cache,encoded,capacity,detail))break;
                    }
                }
                free(encoded);
                if(cache){for(unsigned i=0;i<2040;i++)free(cache->strips[i]);free(cache->previous);free(cache);}
                atomic_store(done,1);
            }
        });
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
        while(!atomic_load(done)&&(seconds==0||[end timeIntervalSinceNow]>0))
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        dispatch_semaphore_t stopped=dispatch_semaphore_create(0);
        [stream stopCaptureWithCompletionHandler:^(NSError *e){(void)e;dispatch_semaphore_signal(stopped);}];
        dispatch_semaphore_wait(stopped,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC));
        // The request worker can still be blocked on stdin when the deadline
        // expires. Process exit owns its lifetime, including the atomic flag.
        return 0;
    }
}
