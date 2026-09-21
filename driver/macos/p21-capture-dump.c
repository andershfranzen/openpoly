#include "p21-dl3-capture.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    FILE *extract;
    int list_records;
    const char *input_path;
} dump_context;

static int handle_record(uint64_t index, uint64_t offset,
                         const uint8_t *payload, uint16_t length,
                         void *opaque) {
    dump_context *context = opaque;
    if (context->list_records) {
        printf("capture=%s record=%llu offset=%llu length=%u\n",
               context->input_path, (unsigned long long)index,
               (unsigned long long)offset, length);
    }
    if (context->extract && length &&
        fwrite(payload, 1, length, context->extract) != length) {
        return -1;
    }
    return 0;
}

static void usage(const char *name) {
    fprintf(stderr,
            "usage: %s --assume-u16-lengths [--records] "
            "[--extract output.bin] capture.log [capture.log ...]\n",
            name);
}

// The recorder writes a 32-bit payload length but frames it with only its low
// 16 bits, so this parser cannot be sound without a caller-supplied bound. The
// flag is deliberately required instead of being assumed: refusing here keeps
// the tool from silently "validating" an arbitrary raw log.
static void explain_missing_assumption(const char *name) {
    fprintf(stderr,
            "%s: refusing to parse a capture without --assume-u16-lengths\n"
            "  The DisplayLink recorder writes the full 32-bit payload length\n"
            "  but the [XXXX] header encodes only its low 16 bits, so records\n"
            "  of 65536 bytes or more are indistinguishable from shorter ones.\n"
            "  Pass --assume-u16-lengths only when the records are known to be\n"
            "  at most 65535 bytes. This tool does not resynchronize on a '['\n"
            "  byte inside payload and cannot detect aliased lengths.\n",
            name);
}

int main(int argc, char **argv) {
    const char *extract_path = NULL;
    const char **input_paths = calloc((size_t)argc, sizeof(*input_paths));
    if (!input_paths) return 1;
    int input_count = 0;
    int assume_u16_lengths = 0;
    dump_context context = {0};

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--records") == 0) {
            context.list_records = 1;
        } else if (strcmp(argv[index], "--assume-u16-lengths") == 0) {
            assume_u16_lengths = 1;
        } else if (strcmp(argv[index], "--extract") == 0 && index + 1 < argc) {
            extract_path = argv[++index];
        } else if (argv[index][0] == '-') {
            usage(argv[0]);
            free(input_paths);
            return 2;
        } else {
            input_paths[input_count++] = argv[index];
        }
    }
    if (!input_count) {
        usage(argv[0]);
        free(input_paths);
        return 2;
    }
    if (!assume_u16_lengths) {
        explain_missing_assumption(argv[0]);
        free(input_paths);
        return 2;
    }
    if (extract_path) {
        // Exclusive creation prevents accidentally truncating the capture
        // itself (including through a hard link) or another analysis result.
        context.extract = fopen(extract_path, "wbx");
        if (!context.extract) {
            fprintf(stderr, "cannot create %s: %s\n", extract_path, strerror(errno));
            free(input_paths);
            return 1;
        }
    }

    p21_dl3_capture_stats total = {0};
    char error[256];
    int result = 0;
    int close_failed = 0;
    for (int index = 0; index < input_count; index++) {
        const char *input_path = input_paths[index];
        FILE *input = fopen(input_path, "rb");
        if (!input) {
            fprintf(stderr, "cannot open %s: %s\n", input_path, strerror(errno));
            result = -1;
            break;
        }
        context.input_path = input_path;
        p21_dl3_capture_stats stats = {0};
        result = p21_dl3_capture_parse_u16(input, handle_record, &context,
                                           &stats, error, sizeof(error));
        if (fclose(input) != 0) close_failed = 1;
        if (result) {
            fprintf(stderr, "invalid capture %s: %s\n", input_path, error);
            break;
        }
        total.record_count += stats.record_count;
        total.payload_bytes += stats.payload_bytes;
        total.file_bytes += stats.file_bytes;
        printf("capture=%s records=%llu payload-bytes=%llu file-bytes=%llu\n",
               input_path, (unsigned long long)stats.record_count,
               (unsigned long long)stats.payload_bytes,
               (unsigned long long)stats.file_bytes);
    }
    if (context.extract && fclose(context.extract) != 0) close_failed = 1;
    free(input_paths);
    if (result) {
        if (extract_path) remove(extract_path);
        return 1;
    }
    if (close_failed) {
        fputs("capture file close failed\n", stderr);
        if (extract_path) remove(extract_path);
        return 1;
    }

    printf("total-files=%d records=%llu payload-bytes=%llu file-bytes=%llu\n",
           input_count, (unsigned long long)total.record_count,
           (unsigned long long)total.payload_bytes,
           (unsigned long long)total.file_bytes);
    if (extract_path) printf("extracted=%s\n", extract_path);
    return 0;
}
