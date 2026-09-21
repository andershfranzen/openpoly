#include "p21-dl3.h"

#include <libusb.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

enum {
    P21_DESCRIPTOR_INTERFACE = 0x04,
    P21_DESCRIPTOR_ENDPOINT = 0x05,
    P21_DESCRIPTOR_IDENTITY = 0x40,
    P21_CLASS_VENDOR = 0xff,
    P21_SUBCLASS_DL3 = 0x00,
    P21_PROTOCOL_DL3 = 0x03,
    P21_TRANSFER_BULK = 0x02,
};

static int fail(char *error, size_t error_length, const char *format, ...) {
    if (error && error_length) {
        va_list arguments;
        va_start(arguments, format);
        vsnprintf(error, error_length, format, arguments);
        va_end(arguments);
    }
    return -1;
}

int p21_dl3_parse_config(const uint8_t *bytes, size_t length,
                         p21_dl3_identity *identity, char *error,
                         size_t error_length) {
    if (!bytes || !identity) return fail(error, error_length, "invalid descriptor input");

    p21_dl3_identity parsed = {0};
    int in_dl3_interface = 0;
    int dl3_interfaces = 0;
    int identities = 0;
    int out_endpoints = 0;
    int in_endpoints = 0;
    int dl3_endpoint_descriptors = 0;
    int dl3_declared_endpoints = -1;
    int dl3_alternate_setting = -1;

    for (size_t offset = 0; offset < length;) {
        if (length - offset < 2)
            return fail(error, error_length, "truncated descriptor header at byte %zu", offset);
        size_t descriptor_length = bytes[offset];
        uint8_t descriptor_type = bytes[offset + 1];
        if (descriptor_length < 2 || descriptor_length > length - offset)
            return fail(error, error_length, "invalid descriptor length at byte %zu", offset);

        const uint8_t *descriptor = bytes + offset;
        if (descriptor_type == P21_DESCRIPTOR_INTERFACE) {
            in_dl3_interface = 0;
            if (descriptor_length >= 9 && descriptor[5] == P21_CLASS_VENDOR &&
                descriptor[6] == P21_SUBCLASS_DL3 && descriptor[7] == P21_PROTOCOL_DL3) {
                in_dl3_interface = 1;
                dl3_interfaces++;
                parsed.interface_number = descriptor[2];
                dl3_alternate_setting = descriptor[3];
                dl3_declared_endpoints = descriptor[4];
            }
        } else if (descriptor_type == P21_DESCRIPTOR_ENDPOINT && in_dl3_interface) {
            dl3_endpoint_descriptors++;
            if (descriptor_length < 7)
                return fail(error, error_length, "short DL3 endpoint descriptor");
            if ((descriptor[3] & LIBUSB_TRANSFER_TYPE_MASK) != P21_TRANSFER_BULK)
                return fail(error, error_length, "DL3 interface contains a non-bulk endpoint");
            uint8_t endpoint = descriptor[2];
            uint16_t packet = (uint16_t)descriptor[4] | (uint16_t)descriptor[5] << 8;
            if (endpoint & LIBUSB_ENDPOINT_IN) {
                parsed.bulk_in = endpoint;
                in_endpoints++;
            } else {
                parsed.bulk_out = endpoint;
                out_endpoints++;
            }
            if (!parsed.max_packet_size) parsed.max_packet_size = packet;
            if (parsed.max_packet_size != packet)
                return fail(error, error_length, "DL3 endpoint packet sizes do not match");
        } else if (descriptor_type == P21_DESCRIPTOR_IDENTITY && descriptor_length >= 16) {
            parsed.firmware_major = descriptor[2];
            parsed.firmware_minor = descriptor[3];
            parsed.firmware_patch = descriptor[4];
            memcpy(parsed.platform, descriptor + 8, 8);
            parsed.platform[8] = '\0';
            for (size_t i = 0; i < 8; i++) {
                if (parsed.platform[i] == '\0' || parsed.platform[i] == ' ') {
                    parsed.platform[i] = '\0';
                    break;
                }
            }
            identities++;
        }
        offset += descriptor_length;
    }

    if (dl3_interfaces != 1)
        return fail(error, error_length, "expected one ff/00/03 DL3 interface; found %d",
                    dl3_interfaces);
    if (parsed.interface_number != 0 || dl3_alternate_setting != 0)
        return fail(error, error_length,
                    "unexpected DL3 interface/alternate setting %u/%d",
                    parsed.interface_number, dl3_alternate_setting);
    if (dl3_declared_endpoints != 2 || dl3_endpoint_descriptors != 2)
        return fail(error, error_length,
                    "expected exactly two DL3 endpoints; descriptor declares %d and contains %d",
                    dl3_declared_endpoints, dl3_endpoint_descriptors);
    if (out_endpoints != 1 || in_endpoints != 1)
        return fail(error, error_length, "expected one bulk endpoint in each direction; found %d/%d",
                    out_endpoints, in_endpoints);
    if (identities != 1)
        return fail(error, error_length, "expected one type-0x40 identity; found %d", identities);
    if (strcmp(parsed.platform, "FflyMoni") != 0)
        return fail(error, error_length, "unsupported DL3 platform '%s'", parsed.platform);
    if (parsed.bulk_out != 0x02 || parsed.bulk_in != 0x84 || parsed.max_packet_size != 1024)
        return fail(error, error_length,
                    "unexpected Firefly transport shape (out=%02x in=%02x packet=%u)",
                    parsed.bulk_out, parsed.bulk_in, parsed.max_packet_size);

    *identity = parsed;
    if (error && error_length) error[0] = '\0';
    return 0;
}

int p21_dl3_probe(p21_dl3_identity *identity, char *error, size_t error_length) {
    if (!identity) return fail(error, error_length, "missing probe result");

    libusb_context *context = NULL;
    int result = libusb_init(&context);
    if (result != LIBUSB_SUCCESS)
        return fail(error, error_length, "USB initialization failed: %s", libusb_error_name(result));

    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(context, &devices);
    if (count < 0) {
        libusb_exit(context);
        return fail(error, error_length, "USB enumeration failed: %s", libusb_error_name((int)count));
    }

    libusb_device *match = NULL;
    struct libusb_device_descriptor device_descriptor = {0};
    int matches = 0;
    for (ssize_t index = 0; index < count; index++) {
        struct libusb_device_descriptor candidate;
        if (libusb_get_device_descriptor(devices[index], &candidate) == LIBUSB_SUCCESS &&
            candidate.idVendor == P21_DISPLAY_VENDOR_ID &&
            candidate.idProduct == P21_DISPLAY_PRODUCT_ID) {
            match = devices[index];
            device_descriptor = candidate;
            matches++;
        }
    }

    if (matches != 1) {
        libusb_free_device_list(devices, 1);
        libusb_exit(context);
        return fail(error, error_length, "expected one 17e9:ff18 P21 display; found %d", matches);
    }

    struct libusb_config_descriptor *configuration = NULL;
    result = libusb_get_active_config_descriptor(match, &configuration);
    if (result != LIBUSB_SUCCESS)
        result = libusb_get_config_descriptor(match, 0, &configuration);
    if (result != LIBUSB_SUCCESS) {
        libusb_free_device_list(devices, 1);
        libusb_exit(context);
        return fail(error, error_length, "cannot read P21 configuration: %s", libusb_error_name(result));
    }

    // libusb splits class/vendor descriptors into `extra` blocks. Rebuild a
    // standard descriptor stream so the same strict parser is used for live
    // devices and captured fixtures.
    uint8_t raw[1024];
    size_t used = 0;
#define APPEND(DATA, LENGTH) do { \
        size_t append_length = (size_t)(LENGTH); \
        if (append_length > sizeof(raw) - used) { \
            libusb_free_config_descriptor(configuration); \
            libusb_free_device_list(devices, 1); \
            libusb_exit(context); \
            return fail(error, error_length, "P21 configuration exceeds probe buffer"); \
        } \
        memcpy(raw + used, (DATA), append_length); \
        used += append_length; \
    } while (0)

    for (uint8_t interface_index = 0; interface_index < configuration->bNumInterfaces;
         interface_index++) {
        const struct libusb_interface *interface = &configuration->interface[interface_index];
        for (int alternate_index = 0; alternate_index < interface->num_altsetting;
             alternate_index++) {
            const struct libusb_interface_descriptor *alternate =
                &interface->altsetting[alternate_index];
            uint8_t interface_bytes[9] = {
                9, P21_DESCRIPTOR_INTERFACE, alternate->bInterfaceNumber,
                alternate->bAlternateSetting, alternate->bNumEndpoints,
                alternate->bInterfaceClass, alternate->bInterfaceSubClass,
                alternate->bInterfaceProtocol, alternate->iInterface
            };
            APPEND(interface_bytes, sizeof(interface_bytes));
            if (alternate->extra_length > 0) APPEND(alternate->extra, alternate->extra_length);
            for (uint8_t endpoint_index = 0; endpoint_index < alternate->bNumEndpoints;
                 endpoint_index++) {
                const struct libusb_endpoint_descriptor *endpoint =
                    &alternate->endpoint[endpoint_index];
                uint8_t endpoint_bytes[7] = {
                    7, P21_DESCRIPTOR_ENDPOINT, endpoint->bEndpointAddress,
                    endpoint->bmAttributes, (uint8_t)endpoint->wMaxPacketSize,
                    (uint8_t)(endpoint->wMaxPacketSize >> 8), endpoint->bInterval
                };
                APPEND(endpoint_bytes, sizeof(endpoint_bytes));
            }
        }
    }
#undef APPEND

    p21_dl3_identity parsed = {0};
    result = p21_dl3_parse_config(raw, used, &parsed, error, error_length);
    if (!result) {
        parsed.bcd_usb = device_descriptor.bcdUSB;
        parsed.bcd_device = device_descriptor.bcdDevice;
        *identity = parsed;
    }
    libusb_free_config_descriptor(configuration);
    libusb_free_device_list(devices, 1);
    libusb_exit(context);
    return result;
}
