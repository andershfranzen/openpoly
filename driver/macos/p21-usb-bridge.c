// SPDX-License-Identifier: GPL-2.0-only
// Bounded experimental DL3 transport. No reset, detach, DFU, or firmware writes.
#include "p21-dl3.h"
#include <libusb.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

static int vendor_processes(int list) {
    int n=proc_listallpids(NULL,0); if(n<=0)return 1;
    size_t cap=(size_t)n+1024;pid_t *ids=calloc(cap,sizeof(*ids));if(!ids)return 1;
    n=proc_listallpids(ids,(int)(cap*sizeof(*ids)));
    if(n<=0||(size_t)n>=cap){free(ids);fprintf(stderr,"process enumeration changed; retry\n");return -1;}
    int found=0;
    for(int i=0;i<n;i++) {
        char p[PROC_PIDPATHINFO_MAXSIZE];
        if(proc_pidpath(ids[i],p,sizeof(p))>0){
            char *name=strrchr(p,'/');
            if(name&&!strcmp(name+1,"DisplayLinkUserAgent"))found=1;
            const char *prefix="/Applications/DisplayLink Manager.app/";
            if(list&&!strncmp(p,prefix,strlen(prefix)))printf("%d\t%s\n",ids[i],p);
        }
    }
    free(ids);return found;
}
static int nibble(char c){return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:-1;}
int main(int argc,char **argv) {
    if(argc==2&&!strcmp(argv[1],"--vendor-pids"))return vendor_processes(1)<0?1:0;
    p21_dl3_identity id;char error[256];
    if(p21_dl3_probe(&id,error,sizeof(error))<0){fprintf(stderr,"%s\n",error);return 1;}
    if(argc!=2||strcmp(argv[1],"--session")){fprintf(stderr,"Use --session only with the vendor app stopped. Probe passed: %s.\n",id.platform);return 2;}
    if(vendor_processes(0)){fprintf(stderr,"DisplayLinkUserAgent is running\n");return 1;}
    if(id.firmware_major!=12||id.firmware_minor!=2||id.firmware_patch!=15){
        fprintf(stderr,"unverified P21 firmware; expected 12.2.15\n");return 1;
    }
    libusb_context *ctx=NULL;libusb_device_handle *handle=NULL;libusb_device **list=NULL;
    int result=libusb_init(&ctx);if(result<0)return 1;
    ssize_t count=libusb_get_device_list(ctx,&list);libusb_device *match=NULL;int matches=0;
    for(ssize_t i=0;i<count;i++){struct libusb_device_descriptor d;if(libusb_get_device_descriptor(list[i],&d)==0&&d.idVendor==P21_DISPLAY_VENDOR_ID&&d.idProduct==P21_DISPLAY_PRODUCT_ID){match=list[i];matches++;}}
    if(matches!=1){fprintf(stderr,"device changed after probe\n");result=-1;goto cleanup;}
    result=libusb_open(match,&handle);if(result<0)goto cleanup;
    result=libusb_claim_interface(handle,0);if(result<0)goto cleanup;
    // Fail closed if a client stops talking for a minute. Active sessions renew
    // this watchdog; EOF releases the interface immediately.
    alarm(60);setvbuf(stdout,NULL,_IOLBF,0);puts("READY");
    unsigned char *buf=malloc(1024*1024);char *line=NULL;size_t allocated=0;
    if(!buf){result=-1;goto release;}
    while(getline(&line,&allocated,stdin)>0){
        alarm(60);
        size_t len=strcspn(line,"\r\n");line[len]=0;int transferred=0;result=0;
        if(line[0]=='Q')break;
        if(line[0]=='W'){
            size_t bytes=(len-1)/2;
            if(len<33||(len-1)%2||bytes>1024*1024){puts("ERR invalid-write");continue;}
            for(size_t i=0;i<bytes;i++){int a=nibble(line[1+i*2]),b=nibble(line[2+i*2]);if(a<0||b<0){result=-1;break;}buf[i]=(unsigned char)((a<<4)|b);}
            if(result){puts("ERR invalid-hex");continue;}
            result=libusb_bulk_transfer(handle,0x02,buf,(int)bytes,&transferred,2000);
            if(result==0&&(size_t)transferred!=bytes)result=LIBUSB_ERROR_IO;
            if(result<0)printf("ERR %d\n",result);else printf("OK %d\n",transferred);
        }else if(line[0]=='R'){
            unsigned timeout=0;char extra;
            if(sscanf(line+1,"%u %c",&timeout,&extra)!=1||timeout<1||timeout>2000){puts("ERR invalid-timeout");continue;}
            result=libusb_bulk_transfer(handle,0x84,buf,16384,&transferred,timeout);
            if(result<0)printf("ERR %d\n",result);else{fputs("DATA ",stdout);for(int i=0;i<transferred;i++)printf("%02x",buf[i]);putchar('\n');}
        }else if(line[0]=='C'){
            unsigned type,req,value,index,length;char extra;
            if(sscanf(line+1,"%x %x %x %x %x %c",&type,&req,&value,&index,&length,&extra)!=5||length>1024){puts("ERR invalid-control");continue;}
            int permitted=(type==0x80&&req==6&&index<=0x409&&(value==0x200||value==0x300||value==0x303))||
                (type==0xc1&&index==1&&value==0&&((req==0xfe&&length==16)||(req==0xfc&&length==3)))||
                (type==0xc1&&req==0x22&&value==1&&index==0&&length==28)||
                (type==0x40&&req==0x24&&value==0&&index==0&&length==0);
            if(!permitted){puts("ERR control-not-observed");continue;}
            result=libusb_control_transfer(handle,(uint8_t)type,(uint8_t)req,(uint16_t)value,(uint16_t)index,buf,(uint16_t)length,1000);
            if(result<0)printf("ERR %d\n",result);else{fputs("DATA ",stdout);for(int i=0;i<result;i++)printf("%02x",buf[i]);putchar('\n');}
        }else puts("ERR invalid-command");
    }
    free(line);free(buf);result=0;
release:
    libusb_release_interface(handle,0);
cleanup:
    if(result<0)fprintf(stderr,"USB: %s\n",libusb_error_name(result));
    if(handle)libusb_close(handle);if(list)libusb_free_device_list(list,1);libusb_exit(ctx);return result<0?1:0;
}
