#ifndef P21_DL3_CAPTURE_H
#define P21_DL3_CAPTURE_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
    uint64_t record_count;
    uint64_t payload_bytes;
    uint64_t file_bytes;
} p21_dl3_capture_stats;

typedef int (*p21_dl3_capture_callback)(uint64_t record_index,
                                        uint64_t record_offset,
                                        const uint8_t *payload,
                                        uint16_t payload_length,
                                        void *context);

// Parses DisplayLink Manager's raw Dl3UsbData_*.log framing under an explicit
// 16-bit length assumption. A record is a six-byte ASCII header, "[XXXX]",
// followed by exactly XXXX binary payload bytes. XXXX is four uppercase ASCII
// hexadecimal digits, because that is the format emitted by the recorder. The
// callback may be NULL when only validation/statistics are required. A nonzero
// callback result stops parsing and is reported as an error.
//
// Precondition. Static analysis of DisplayLink Manager 16.2.39 (ARM64
// 0x10039dea0) shows the recorder writes the full 32-bit payload length with
// `basic_ostream::write`, while the "[XXXX]" header encodes only the low 16
// bits of that value (bits 15..0 as four uppercase nibbles). No upper bound of
// 65535 bytes has been established anywhere in the producer. This parser treats
// XXXX as the entire payload length, which is sound only for logs whose records
// are known to be at most 65535 bytes. Payload lengths that differ by a
// multiple of 65536 produce identical headers, so a record of 65536 bytes or
// more cannot be detected from the framing alone: the caller owns that
// assumption.
//
// The recorder never emits a zero-length record, so a "[0000]" header is
// rejected instead of being accepted as an empty record. That header can also
// be the alias of a wrapped 65536-byte payload.
//
// The parser consumes exactly the declared payload bytes and never
// resynchronizes on a '[' byte found inside payload.
int p21_dl3_capture_parse_u16(FILE *input,
                              p21_dl3_capture_callback callback,
                              void *context,
                              p21_dl3_capture_stats *stats,
                              char *error,
                              size_t error_length);

#endif
