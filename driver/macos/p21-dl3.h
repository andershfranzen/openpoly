#ifndef P21_DL3_H
#define P21_DL3_H

#include <stddef.h>
#include <stdint.h>

#define P21_DISPLAY_VENDOR_ID 0x17e9
#define P21_DISPLAY_PRODUCT_ID 0xff18

typedef struct {
    uint16_t bcd_usb;
    uint16_t bcd_device;
    uint8_t interface_number;
    uint8_t bulk_out;
    uint8_t bulk_in;
    uint16_t max_packet_size;
    uint8_t firmware_major;
    uint8_t firmware_minor;
    uint8_t firmware_patch;
    char platform[9];
} p21_dl3_identity;

// Parses a raw USB configuration-descriptor stream. Exposed for offline tests.
int p21_dl3_parse_config(const uint8_t *bytes, size_t length,
                         p21_dl3_identity *identity, char *error,
                         size_t error_length);

// Enumerates the P21 display function and reads descriptors only. It never opens,
// claims, resets, detaches, or writes to the device.
int p21_dl3_probe(p21_dl3_identity *identity, char *error,
                  size_t error_length);

#endif
