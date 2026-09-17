#ifndef P21_USB_H
#define P21_USB_H
#include <libusb.h>
#include <stdint.h>
int p21_usb_open(uint16_t vendor, uint16_t product, libusb_context **context, libusb_device_handle **handle);
int p21_camera(int argc, char **argv);
int p21_hid(int argc, char **argv);
int p21_integer(const char *text, int64_t min, int64_t max, int64_t *value);
#endif
