#include <CoreGraphics/CoreGraphics.h>
#include "usb.h"
#include <stdio.h>
#include <string.h>
static void printMode(CGDisplayModeRef m) {
    printf("mode=%u %zux%zu pixels=%zux%zu refresh=%.2fHz\n",CGDisplayModeGetIODisplayModeID(m),
           CGDisplayModeGetWidth(m),CGDisplayModeGetHeight(m),CGDisplayModeGetPixelWidth(m),
           CGDisplayModeGetPixelHeight(m),CGDisplayModeGetRefreshRate(m));
}
static CGError applyMode(CGDirectDisplayID display,CGDisplayModeRef mode) {
    CGDisplayConfigRef config=NULL;CGError error=CGBeginDisplayConfiguration(&config);
    if(error)return error;
    error=CGConfigureDisplayWithDisplayMode(config,display,mode,NULL);
    if(error) { CGCancelDisplayConfiguration(config);return error; }
    return CGCompleteDisplayConfiguration(config,kCGConfigureForSession);
}
static int restoreMode(CGDirectDisplayID display,CGDisplayModeRef before) {
    CGError error=applyMode(display,before);
    if(error) { fprintf(stderr,"RESTORE FAILED: display mode (%d)\n",error);return 1; }
    CGDisplayModeRef actual=CGDisplayCopyDisplayMode(display);
    int mismatch=!actual || CGDisplayModeGetIODisplayModeID(actual)!=CGDisplayModeGetIODisplayModeID(before);
    if(actual)CGDisplayModeRelease(actual);
    if(mismatch) { fprintf(stderr,"RESTORE FAILED: display mode readback mismatch\n");return 1; }
    return 0;
}
int p21_screen(int argc,char **argv) {
    int status=argc==1&&!strcmp(argv[0],"status"), modes=argc==1&&!strcmp(argv[0],"modes");
    int set=argc==2&&!strcmp(argv[0],"mode");int64_t id=0;
    if((!status&&!modes&&!set)||(set&&p21_integer(argv[1],0,UINT32_MAX,&id))) {
        fprintf(stderr,"screen: status | modes | mode ID\n");return 2;
    }
    CGDirectDisplayID displays[32],display=0;uint32_t count=0;int matches=0;
    if(CGGetOnlineDisplayList(32,displays,&count)!=kCGErrorSuccess) { fprintf(stderr,"Display enumeration failed\n");return 1; }
    for(uint32_t i=0;i<count;i++) if(CGDisplayVendorNumber(displays[i])==0x4199 && CGDisplayModelNumber(displays[i])==1) {
        display=displays[i];matches++;
    }
    if(matches!=1) { fprintf(stderr,"Expected one P21 display (PLY vendor 4199, model 1); found %d. Check DisplayLink Manager.\n",matches);return 1; }
    if(status) {
        CGDisplayModeRef m=CGDisplayCopyDisplayMode(display);
        if(!m)return 1;
        printf("Poly Studio P21 display=%u rotation=%.0f degrees ",display,CGDisplayRotation(display));
        printMode(m);CGDisplayModeRelease(m);return 0;
    }
    CFArrayRef list=CGDisplayCopyAllDisplayModes(display,NULL);
    if(!list) { fprintf(stderr,"No display modes available\n");return 1; }
    CGDisplayModeRef selected=NULL;
    for(CFIndex i=0;i<CFArrayGetCount(list);i++) {
        CGDisplayModeRef m=(CGDisplayModeRef)CFArrayGetValueAtIndex(list,i);
        if(modes)printMode(m);
        if(CGDisplayModeGetIODisplayModeID(m)==id)selected=m;
    }
    int result=0;
    if(set) {
        if(!selected) { fprintf(stderr,"Mode ID is not available; run screen modes\n");result=2; }
        else {
            CGDisplayModeRef before=CGDisplayCopyDisplayMode(display);
            if(!before) { fprintf(stderr,"Cannot read current display mode\n");result=1; }
            CGError error=before?applyMode(display,selected):kCGErrorFailure;
            if(error) { fprintf(stderr,"Display configuration failed: %d\n",error);result=1; }
            else {
                CGDisplayModeRef actual=CGDisplayCopyDisplayMode(display);
                if(!actual || CGDisplayModeGetIODisplayModeID(actual)!=id) {
                    fprintf(stderr,"Display mode readback mismatch; restoring\n");
                    if(actual)CGDisplayModeRelease(actual);
                    restoreMode(display,before);result=1;
                } else { printMode(actual);CGDisplayModeRelease(actual); }
            }
            if(error && before)restoreMode(display,before);
            if(before)CGDisplayModeRelease(before);
        }
    }
    CFRelease(list);return result;
}
