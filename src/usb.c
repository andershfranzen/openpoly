#include "usb.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
int p21_integer(const char *text, int64_t min, int64_t max, int64_t *value) {
    char *end; errno = 0;
    long long n = strtoll(text, &end, 10);
    if (errno || !*text || *end || n < min || n > max) return -1;
    *value = n; return 0;
}
int p21_usb_open(uint16_t vendor, uint16_t product, libusb_context **context, libusb_device_handle **handle) {
    int r = libusb_init(context);
    if (r) { fprintf(stderr, "USB initialization: %s\n", libusb_error_name(r)); return 1; }
    libusb_device **devices; ssize_t count = libusb_get_device_list(*context, &devices);
    if (count < 0) { fprintf(stderr, "USB enumeration failed\n"); libusb_exit(*context); return 1; }
    libusb_device *match = NULL; int matches = 0;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor d;
        if (!libusb_get_device_descriptor(devices[i], &d) && d.idVendor == vendor && d.idProduct == product) {
            match = devices[i]; matches++;
        }
    }
    r = matches == 1 ? libusb_open(match, handle) : LIBUSB_ERROR_NO_DEVICE;
    libusb_free_device_list(devices, 1);
    if (r) {
        fprintf(stderr, "%04x:%04x: %s (matching devices: %d)\n", vendor, product, libusb_error_name(r), matches);
        libusb_exit(*context); return 1;
    }
    return 0;
}
