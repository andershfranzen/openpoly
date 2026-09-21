#include "p21-dl3-capture.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { P21_CAPTURE_HEADER_SIZE = 6 };

static int fail(char *error, size_t error_length, const char *format, ...) {
    if (error && error_length) {
        va_list arguments;
        va_start(arguments, format);
        vsnprintf(error, error_length, format, arguments);
        va_end(arguments);
    }
    return -1;
}

static int uppercase_hex_value(unsigned char byte) {
    if (byte >= '0' && byte <= '9') return byte - '0';
    if (byte >= 'A' && byte <= 'F') return byte - 'A' + 10;
    return -1;
}

int p21_dl3_capture_parse_u16(FILE *input,
                              p21_dl3_capture_callback callback,
                              void *context,
                              p21_dl3_capture_stats *stats,
                              char *error,
                              size_t error_length) {
    if (!input) return fail(error, error_length, "missing capture input");

    p21_dl3_capture_stats parsed = {0};
    uint8_t *payload = NULL;
    size_t payload_capacity = 0;

    for (;;) {
        unsigned char header[P21_CAPTURE_HEADER_SIZE];
        size_t header_bytes = fread(header, 1, sizeof(header), input);
        if (header_bytes == 0) {
            if (ferror(input)) {
                free(payload);
                return fail(error, error_length,
                            "capture read failed at byte %llu",
                            (unsigned long long)parsed.file_bytes);
            }
            break;
        }
        if (header_bytes != sizeof(header)) {
            uint64_t offset = parsed.file_bytes;
            parsed.file_bytes += header_bytes;
            free(payload);
            return fail(error, error_length,
                        "truncated record header at byte %llu (%zu of %d bytes)",
                        (unsigned long long)offset, header_bytes,
                        P21_CAPTURE_HEADER_SIZE);
        }

        uint64_t record_offset = parsed.file_bytes;
        parsed.file_bytes += sizeof(header);
        if (header[0] != '[' || header[5] != ']') {
            free(payload);
            return fail(error, error_length,
                        "invalid record framing at byte %llu",
                        (unsigned long long)record_offset);
        }

        unsigned length = 0;
        for (size_t index = 1; index <= 4; index++) {
            int digit = uppercase_hex_value(header[index]);
            if (digit < 0) {
                free(payload);
                return fail(error, error_length,
                            "invalid uppercase hex length at byte %llu",
                            (unsigned long long)(record_offset + index));
            }
            length = length * 16u + (unsigned)digit;
        }

        // The recorder skips zero and negative lengths, so it never writes a
        // zero-byte record. A "[0000]" header can only mean a corrupt stream or
        // a wrapped 65536-byte payload, and accepting it would silently invent
        // an empty record.
        if (length == 0) {
            free(payload);
            return fail(error, error_length,
                        "zero-length record header at byte %llu: no zero-byte "
                        "records; [0000] may encode a wrapped length",
                        (unsigned long long)record_offset);
        }

        if (length > payload_capacity) {
            uint8_t *resized = realloc(payload, length);
            if (!resized) {
                free(payload);
                return fail(error, error_length,
                            "cannot allocate %u-byte record payload", length);
            }
            payload = resized;
            payload_capacity = length;
        }
        if (length) {
            size_t payload_bytes = fread(payload, 1, length, input);
            parsed.file_bytes += payload_bytes;
            if (payload_bytes != length) {
                free(payload);
                return fail(error, error_length,
                            "truncated payload for record %llu at byte %llu "
                            "(%zu of %u bytes)",
                            (unsigned long long)parsed.record_count,
                            (unsigned long long)(record_offset + sizeof(header)),
                            payload_bytes, length);
            }
        }

        if (callback && callback(parsed.record_count, record_offset, payload,
                                 (uint16_t)length, context)) {
            free(payload);
            return fail(error, error_length,
                        "capture callback failed for record %llu",
                        (unsigned long long)parsed.record_count);
        }
        parsed.record_count++;
        parsed.payload_bytes += length;
    }

    free(payload);
    if (stats) *stats = parsed;
    if (error && error_length) error[0] = '\0';
    return 0;
}
