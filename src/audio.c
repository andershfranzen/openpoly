#include "audio.h"
#include "usb.h"
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int usage(void) {
    fprintf(stderr,"audio: status | mic-volume|speaker-volume [0..100] | mic-mute|speaker-mute [on|off] | default-input|default-output\n");
    return 2;
}
static AudioObjectPropertyAddress address(UInt32 selector,UInt32 scope,UInt32 channel) {
    return (AudioObjectPropertyAddress){selector,scope,channel};
}
static int readProperty(AudioObjectID object,AudioObjectPropertyAddress a,void *value,UInt32 expected) {
    UInt32 size=expected;OSStatus error=AudioObjectGetPropertyData(object,&a,0,NULL,&size,value);
    if(error || size!=expected) { fprintf(stderr,"CoreAudio read failed: %d (bytes %u/%u)\n",(int)error,size,expected);return 1; }
    return 0;
}
static int writeProperty(AudioObjectID object,AudioObjectPropertyAddress a,const void *value,UInt32 size) {
    Boolean writable=false;OSStatus error=AudioObjectIsPropertySettable(object,&a,&writable);
    if(error || !writable) { fprintf(stderr,"CoreAudio property unavailable/read-only: %d\n",(int)error);return 1; }
    error=AudioObjectSetPropertyData(object,&a,0,NULL,size,value);
    if(error) { fprintf(stderr,"CoreAudio write failed: %d\n",(int)error);return 1; }
    return 0;
}
static int selectDevice(UInt32 scope,AudioDeviceID *device,UInt32 *channels) {
    AudioObjectPropertyAddress a=address(kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,0);
    UInt32 size=0;OSStatus error=AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&size);
    if(error || !size || size%sizeof(AudioDeviceID)) { fprintf(stderr,"Cannot enumerate audio devices: %d\n",(int)error);return 1; }
    AudioDeviceID *devices=malloc(size);if(!devices)return 1;
    if(readProperty(kAudioObjectSystemObject,a,devices,size)) { free(devices);return 1; }
    int matches=0,result=0;
    for(size_t i=0;i<size/sizeof(*devices);i++) {
        CFStringRef name=NULL;
        if(readProperty(devices[i],address(kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,0),&name,sizeof(name))) { result=1;break; }
        int match=name && CFStringCompare(name,CFSTR("Poly Studio P21"),0)==kCFCompareEqualTo;
        if(name)CFRelease(name);
        if(!match)continue;
        a=address(kAudioDevicePropertyStreamConfiguration,scope,0);
        UInt32 bytes=0;
        if(!AudioObjectHasProperty(devices[i],&a))continue;
        error=AudioObjectGetPropertyDataSize(devices[i],&a,0,NULL,&bytes);
        if(error || bytes<offsetof(AudioBufferList,mBuffers)) { result=1;break; }
        AudioBufferList *buffers=malloc(bytes);if(!buffers) { result=1;break; }
        if(readProperty(devices[i],a,buffers,bytes) || buffers->mNumberBuffers>(bytes-offsetof(AudioBufferList,mBuffers))/sizeof(AudioBuffer)) {
            free(buffers);result=1;break;
        }
        uint64_t count=0;
        for(UInt32 j=0;j<buffers->mNumberBuffers;j++)count+=buffers->mBuffers[j].mNumberChannels;
        free(buffers);
        if(count>UINT32_MAX) { result=1;break; }
        if(count) { *device=devices[i];*channels=(UInt32)count;matches++; }
    }
    free(devices);
    if(result || matches!=1) { fprintf(stderr,"Expected one P21 %s device; found %d%s\n",scope==kAudioObjectPropertyScopeInput?"input":"output",matches,result?" (enumeration error)":"");return 1; }
    return 0;
}
typedef union { Float32 volume;UInt32 mute; } Value;
static int control(AudioDeviceID device,UInt32 scope,UInt32 channels,const char *name,int mute,const char *setting) {
    Value wanted={0};int64_t n=0;
    if(setting) {
        if(mute) {
            if(strcmp(setting,"on") && strcmp(setting,"off")) { fprintf(stderr,"Mute must be on or off\n");return 2; }
            wanted.mute=!strcmp(setting,"on");
        } else {
            if(p21_integer(setting,0,100,&n)) { fprintf(stderr,"Volume must be 0..100\n");return 2; }
            wanted.volume=(Float32)n/100;
        }
    }
    UInt32 selector=mute?kAudioDevicePropertyMute:kAudioDevicePropertyVolumeScalar;
    AudioObjectPropertyAddress a=address(selector,scope,0);
    UInt32 first=AudioObjectHasProperty(device,&a)?0:1,last=first?channels:0;
    if(first>last) { fprintf(stderr,"%s unsupported\n",name);return 1; }
    size_t count=(size_t)last-first+1;
    Value *before=calloc(count,sizeof(*before));if(!before)return 1;
    int result=0;size_t written=0;
    // Preflight every channel so a missing right-channel control cannot leave a partial change.
    for(UInt32 ch=first;ch<=last;ch++) {
        a=address(selector,scope,ch);
        if(!AudioObjectHasProperty(device,&a) || readProperty(device,a,&before[ch-first],sizeof(Value))) { result=1;break; }
        if(!mute && (!isfinite(before[ch-first].volume) || before[ch-first].volume<0 || before[ch-first].volume>1)) { result=1;break; }
        if(setting) {
            Boolean writable=false;
            if(AudioObjectIsPropertySettable(device,&a,&writable) || !writable) { result=1;break; }
        }
    }
    if(!result && setting) for(UInt32 ch=first;ch<=last;ch++) {
        a=address(selector,scope,ch);
        // Include this channel in rollback even if its write returns an error.
        written++;
        if(writeProperty(device,a,&wanted,sizeof(Value))) { result=1;break; }
        Value actual={0};
        if(readProperty(device,a,&actual,sizeof(actual)) ||
           (mute?actual.mute!=wanted.mute:!isfinite(actual.volume)||fabsf(actual.volume-wanted.volume)>0.0051f)) {
            fprintf(stderr,"%s channel %u readback mismatch (requested %.3f, actual %.3f); restoring\n",name,ch,mute?(double)wanted.mute:(double)wanted.volume,mute?(double)actual.mute:(double)actual.volume);result=1;break;
        }
    }
    if(result && setting) {
        for(size_t i=0;i<written;i++) if(writeProperty(device,address(selector,scope,first+(UInt32)i),&before[i],sizeof(Value)))
            fprintf(stderr,"RESTORE FAILED: %s channel %zu\n",name,(size_t)first+i);
    }
    if(!result) for(UInt32 ch=first;ch<=last;ch++) {
        Value actual=before[ch-first];a=address(selector,scope,ch);
        if(setting && readProperty(device,a,&actual,sizeof(actual))) { result=1;break; }
        Boolean writable=false;OSStatus error=AudioObjectIsPropertySettable(device,&a,&writable);
        if(error) { result=1;break; }
        printf("%s=",name);
        if(mute)printf("%s",actual.mute?"on":"off");else printf("%.3f%%",actual.volume*100);
        printf(" channel=%u writable=%s\n",ch,writable?"yes":"no");
    }
    if(result)fprintf(stderr,"%s could not be completed\n",name);
    free(before);return result;
}
int p21_audio(int argc,char **argv) {
    if(argc<1)return usage();
    int status=!strcmp(argv[0],"status");
    int mic=!strcmp(argv[0],"mic-volume")||!strcmp(argv[0],"mic-mute")||!strcmp(argv[0],"default-input");
    int speaker=!strcmp(argv[0],"speaker-volume")||!strcmp(argv[0],"speaker-mute")||!strcmp(argv[0],"default-output");
    int select=!strcmp(argv[0],"default-input")||!strcmp(argv[0],"default-output");
    if((!status&&!mic&&!speaker)||((status||select)?argc!=1:(argc!=1&&argc!=2)))return usage();
    if(status) {
        int result=0;
        for(int input=1;input>=0;input--) {
            UInt32 scope=input?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput,channels=0;AudioDeviceID device=0;
            if(selectDevice(scope,&device,&channels)) { result=1;continue; }
            printf("%s device=%u channels=%u\n",input?"input":"output",device,channels);
            result|=control(device,scope,channels,input?"mic-volume":"speaker-volume",0,NULL);
            result|=control(device,scope,channels,input?"mic-mute":"speaker-mute",1,NULL);
        }
        return result;
    }
    UInt32 scope=mic?kAudioObjectPropertyScopeInput:kAudioObjectPropertyScopeOutput,channels=0;AudioDeviceID device=0;
    if(selectDevice(scope,&device,&channels))return 1;
    if(select) {
        AudioObjectPropertyAddress a=address(mic?kAudioHardwarePropertyDefaultInputDevice:kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,0);
        AudioDeviceID actual=0,before=0;
        if(readProperty(kAudioObjectSystemObject,a,&before,sizeof(before)))return 1;
        if(writeProperty(kAudioObjectSystemObject,a,&device,sizeof(device))||readProperty(kAudioObjectSystemObject,a,&actual,sizeof(actual))||actual!=device) {
            if(writeProperty(kAudioObjectSystemObject,a,&before,sizeof(before)))fprintf(stderr,"RESTORE FAILED: default audio device\n");
            return 1;
        }
        printf("%s=Poly Studio P21\n",argv[0]);return 0;
    }
    return control(device,scope,channels,argv[0],strstr(argv[0],"mute")!=NULL,argc==2?argv[1]:NULL);
}
