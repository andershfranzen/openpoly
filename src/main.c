#include "usb.h"
#include "audio.h"
#include <stdio.h>
#include <string.h>
int p21_lights(int argc,char **argv);
int p21_screen(int argc,char **argv);
int p21_lcd(int argc,char **argv);
int main(int argc,char **argv) {
    if(argc<2 || !strcmp(argv[1],"help") || !strcmp(argv[1],"--help")) {
        puts("p21ctl — direct Poly Studio P21 controls\n"
             "  camera list | CONTROL [VALUE]\n"
             "  camera pan-tilt [PAN TILT]\n"
             "  audio status\n"
             "  audio mic-volume|speaker-volume [0..100]\n"
             "  audio mic-mute|speaker-mute [on|off]\n"
             "  audio default-input|default-output\n"
             "  screen status | modes | mode ID\n"
             "  lights list | left|right|status [0..100]\n"
             "  lights sides LEFT RIGHT (0..100, rounds up to 10% steps, immediate)\n"
             "  lights manual|sensor|idle|incoming|active|held|charging [on|off]\n"
             "  lights bar-state | rgb R G B [SECONDS] | cycle [SECONDS [PERIOD]]\n"
             "  lights fade 0..7\n"
             "  lights palette CHIP R0 G0 B0 R1 G1 B1 MAP\n"
             "  lcd query | fill RGB565 | play FILE.raw [MS_PER_FRAME]  (patched firmware only)\n"
             "  hid status\n"
              "  hid mute-indicator|call-indicator|ring-indicator|hold-indicator [on|off]\n"
              "  hid softphone-icon [zoom|teams]\n"
             "RGB: 0..255; timed RGB/cycles restore on exit. Cycle duration and spectrum period each default to 30 seconds.\n"
             "Palette: chip 1/2, MAP is 12 selectors (0=off, 8..f=color mix).\n"
             "Read a control without a value; writes validate limits and read back.\n"
             "Camera exposure: units of 100 microseconds. Zoom: 10..40.\n"
             "Pan/tilt: arcseconds. Auto-exposure: 1=manual, 8=aperture priority.");
        return 0;
    }
    if(!strcmp(argv[1],"camera"))return p21_camera(argc-2,argv+2);
    if(!strcmp(argv[1],"audio"))return p21_audio(argc-2,argv+2);
    if(!strcmp(argv[1],"screen"))return p21_screen(argc-2,argv+2);
    if(!strcmp(argv[1],"lights"))return p21_lights(argc-2,argv+2);
    if(!strcmp(argv[1],"lcd"))return p21_lcd(argc-2,argv+2);
    if(!strcmp(argv[1],"hid"))return p21_hid(argc-2,argv+2);
    fprintf(stderr,"Unknown command; run p21ctl help\n");return 2;
}
