#include "../driver/macos/p21-dl3-capture.h"

#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef struct {
    unsigned calls;
    unsigned char bytes[8];
    size_t used;
} observed_records;

static int observe(uint64_t index, uint64_t offset, const uint8_t *payload,
                   uint16_t length, void *opaque) {
    observed_records *observed = opaque;
    if (index == 0) assert(offset == 0);
    if (index == 1) assert(offset == 9);
    assert(observed->used + length <= sizeof(observed->bytes));
    if (length) memcpy(observed->bytes + observed->used, payload, length);
    observed->used += length;
    observed->calls++;
    return 0;
}

typedef struct {
    unsigned calls;
    uint64_t total;
    uint16_t longest;
} length_totals;

static int measure(uint64_t index, uint64_t offset, const uint8_t *payload,
                   uint16_t length, void *opaque) {
    length_totals *totals = opaque;
    (void)index;
    (void)offset;
    (void)payload;
    totals->calls++;
    totals->total += length;
    if (length > totals->longest) totals->longest = length;
    return 0;
}

static int parse(const void *bytes, size_t length,
                 p21_dl3_capture_callback callback, void *context,
                 p21_dl3_capture_stats *stats, char *error) {
    FILE *file = tmpfile();
    assert(file != NULL);
    assert(fwrite(bytes, 1, length, file) == length);
    rewind(file);
    int result = p21_dl3_capture_parse_u16(file, callback, context, stats,
                                           error, 256);
    assert(fclose(file) == 0);
    return result;
}

static char workspace[PATH_MAX];

static int write_bytes(const char *path, const void *bytes, size_t length) {
    FILE *file = fopen(path, "wb");
    if (!file) return -1;
    int ok = fwrite(bytes, 1, length, file) == length;
    if (fclose(file) != 0) ok = 0;
    return ok ? 0 : -1;
}

static int read_bytes(const char *path, void *buffer, size_t capacity,
                      size_t *used) {
    FILE *file = fopen(path, "rb");
    if (!file) return -1;
    *used = fread(buffer, 1, capacity, file);
    fclose(file);
    return 0;
}

static int read_text(const char *path, char *buffer, size_t capacity) {
    size_t used = 0;
    if (read_bytes(path, buffer, capacity - 1, &used) != 0) return -1;
    buffer[used] = '\0';
    return 0;
}

static int run_shell(const char *command) {
    int status = system(command);
    if (status == -1 || !WIFEXITED(status)) return -1;
    return WEXITSTATUS(status);
}

// ./driver/macos/build.sh writes the CLI next to this test binary, so prefer
// argv[0]'s directory and fall back to the documented build path.
static int locate_cli(const char *argv0, char *out, size_t capacity) {
    const char *from_environment = getenv("P21_CAPTURE_DUMP");
    if (from_environment && *from_environment &&
        access(from_environment, X_OK) == 0) {
        snprintf(out, capacity, "%s", from_environment);
        return 0;
    }
    const char *slash = argv0 ? strrchr(argv0, '/') : NULL;
    if (slash) {
        snprintf(out, capacity, "%.*s/p21-capture-dump", (int)(slash - argv0),
                 argv0);
        if (access(out, X_OK) == 0) return 0;
    }
    snprintf(out, capacity, "build/p21-capture-dump");
    if (access(out, X_OK) == 0) return 0;
    return -1;
}

static void check_framing(void) {
    // A valid fixture must not rely on accepting [0000]; the recorder never
    // emits a zero-byte record.
    static const unsigned char valid[] = {
        '[', '0', '0', '0', '3', ']', 0x00, 0x5b, 0xff,
        '[', '0', '0', '0', '2', ']', 0x41, 0x42
    };
    observed_records observed = {0};
    p21_dl3_capture_stats stats = {0};
    char error[256];
    assert(parse(valid, sizeof(valid), observe, &observed, &stats, error) == 0);
    assert(observed.calls == 2);
    assert(observed.used == 5);
    assert(memcmp(observed.bytes, "\0[\xff" "AB", 5) == 0);
    assert(stats.record_count == 2);
    assert(stats.payload_bytes == 5);
    assert(stats.file_bytes == sizeof(valid));

    static const unsigned char short_header[] = "[000";
    assert(parse(short_header, sizeof(short_header) - 1, NULL, NULL,
                 NULL, error) != 0);
    assert(strstr(error, "truncated record header") != NULL);

    static const unsigned char bad_frame[] = "{0000]";
    assert(parse(bad_frame, sizeof(bad_frame) - 1, NULL, NULL,
                 NULL, error) != 0);
    assert(strstr(error, "invalid record framing") != NULL);

    static const unsigned char lowercase_hex[] = "[000a]0123456789";
    assert(parse(lowercase_hex, sizeof(lowercase_hex) - 1, NULL, NULL,
                 NULL, error) != 0);
    assert(strstr(error, "uppercase hex") != NULL);

    static const unsigned char truncated_payload[] = "[0004]abc";
    assert(parse(truncated_payload, sizeof(truncated_payload) - 1, NULL, NULL,
                 NULL, error) != 0);
    assert(strstr(error, "truncated payload") != NULL);

    // A zero-length header is never produced by the recorder, and it is also
    // what a wrapped 65536-byte payload would look like.
    static const unsigned char zero_record[] = "[0000]";
    assert(parse(zero_record, sizeof(zero_record) - 1, NULL, NULL,
                 NULL, error) != 0);
    assert(strstr(error, "[0000]") != NULL);

    static const unsigned char zero_after_valid[] = "[0002]AB[0000]";
    assert(parse(zero_after_valid, sizeof(zero_after_valid) - 1, NULL, NULL,
                 NULL, error) != 0);
    assert(strstr(error, "zero-length record header") != NULL);

    // The largest length the framing can represent must still round-trip.
    static const unsigned char boundary_header[] = "[FFFF]";
    size_t header_length = sizeof(boundary_header) - 1;
    size_t boundary_length = 65535;
    unsigned char *boundary = malloc(header_length + boundary_length);
    assert(boundary != NULL);
    memcpy(boundary, boundary_header, header_length);
    memset(boundary + header_length, 0xa5, boundary_length);
    length_totals totals = {0};
    assert(parse(boundary, header_length + boundary_length, measure, &totals,
                 &stats, error) == 0);
    assert(totals.calls == 1);
    assert(totals.total == 65535);
    assert(totals.longest == 65535);
    assert(stats.record_count == 1);
    assert(stats.payload_bytes == 65535);
    free(boundary);

    // Payload bytes that look like framing must be consumed as payload and
    // never used to resynchronize.
    static const unsigned char payload_bracket[] = "[0006][0000]";
    assert(parse(payload_bracket, sizeof(payload_bracket) - 1, NULL, NULL,
                 &stats, error) == 0);
    assert(stats.record_count == 1);
    assert(stats.payload_bytes == 6);
}

static void check_cli(const char *argv0) {
    char cli[PATH_MAX];
    if (locate_cli(argv0, cli, sizeof(cli)) != 0) {
        fprintf(stderr,
                "cannot find build/p21-capture-dump for the CLI contract "
                "checks; run ./driver/macos/build.sh or ./script/test.sh "
                "first\n");
        exit(1);
    }

    char directory[] = "/tmp/p21-capture-cli-XXXXXX";
    assert(mkdtemp(directory) != NULL);
    snprintf(workspace, sizeof(workspace), "%s", directory);

    static const unsigned char valid[] = {
        '[', '0', '0', '0', '3', ']', 0x00, 0x5b, 0xff,
        '[', '0', '0', '0', '2', ']', 0x41, 0x42
    };
    static const unsigned char zero_record[] = "[0000]";
    static const unsigned char truncated_payload[] = "[0004]abc";
    static const unsigned char keep[] = "keep-me";

    char valid_path[PATH_MAX], zero_path[PATH_MAX], trunc_path[PATH_MAX];
    char boundary_path[PATH_MAX], keep_path[PATH_MAX];
    char out_path[PATH_MAX], err_path[PATH_MAX], extract_path[PATH_MAX];
    char command[4096], text[4096];
    snprintf(valid_path, sizeof(valid_path), "%s/valid.log", workspace);
    snprintf(zero_path, sizeof(zero_path), "%s/zero.log", workspace);
    snprintf(trunc_path, sizeof(trunc_path), "%s/trunc.log", workspace);
    snprintf(boundary_path, sizeof(boundary_path), "%s/boundary.log", workspace);
    snprintf(keep_path, sizeof(keep_path), "%s/keep.bin", workspace);
    snprintf(out_path, sizeof(out_path), "%s/stdout.txt", workspace);
    snprintf(err_path, sizeof(err_path), "%s/stderr.txt", workspace);
    assert(write_bytes(valid_path, valid, sizeof(valid)) == 0);
    assert(write_bytes(zero_path, zero_record, sizeof(zero_record) - 1) == 0);
    assert(write_bytes(trunc_path, truncated_payload,
                       sizeof(truncated_payload) - 1) == 0);
    assert(write_bytes(keep_path, keep, sizeof(keep) - 1) == 0);
    {
        static const unsigned char header[] = "[FFFF]";
        size_t header_length = sizeof(header) - 1;
        size_t length = 65535;
        unsigned char *boundary = malloc(header_length + length);
        assert(boundary != NULL);
        memcpy(boundary, header, header_length);
        memset(boundary + header_length, 0x5a, length);
        assert(write_bytes(boundary_path, boundary, header_length + length) == 0);
        free(boundary);
    }

    // Without the explicit assumption the CLI must refuse before it lists,
    // extracts, or creates any output.
    snprintf(extract_path, sizeof(extract_path), "%s/refused.bin", workspace);
    snprintf(command, sizeof(command),
             "'%s' --records --extract '%s' '%s' >'%s' 2>'%s'", cli,
             extract_path, valid_path, out_path, err_path);
    assert(run_shell(command) != 0);
    assert(read_text(err_path, text, sizeof(text)) == 0);
    assert(strstr(text, "--assume-u16-lengths") != NULL);
    assert(read_text(out_path, text, sizeof(text)) == 0);
    assert(strstr(text, "record=") == NULL);
    assert(access(extract_path, F_OK) != 0);

    // A pre-existing analysis result must survive a refused run untouched.
    snprintf(command, sizeof(command),
             "'%s' --extract '%s' '%s' >'%s' 2>'%s'", cli, keep_path,
             valid_path, out_path, err_path);
    assert(run_shell(command) != 0);
    {
        unsigned char kept[16];
        size_t kept_used = 0;
        assert(read_bytes(keep_path, kept, sizeof(kept), &kept_used) == 0);
        assert(kept_used == sizeof(keep) - 1);
        assert(memcmp(kept, keep, sizeof(keep) - 1) == 0);
    }

    snprintf(command, sizeof(command),
             "'%s' --assume-u16-lengths --records '%s' >'%s' 2>'%s'", cli,
             valid_path, out_path, err_path);
    assert(run_shell(command) == 0);
    assert(read_text(out_path, text, sizeof(text)) == 0);
    assert(strstr(text, "record=0") != NULL);
    assert(strstr(text, "record=1") != NULL);
    assert(strstr(text, "length=3") != NULL);
    assert(strstr(text, "length=2") != NULL);

    snprintf(extract_path, sizeof(extract_path), "%s/payload.bin", workspace);
    snprintf(command, sizeof(command),
             "'%s' --assume-u16-lengths --extract '%s' '%s' >'%s' 2>'%s'", cli,
             extract_path, valid_path, out_path, err_path);
    assert(run_shell(command) == 0);
    {
        unsigned char payload[16];
        size_t payload_used = 0;
        assert(read_bytes(extract_path, payload, sizeof(payload),
                          &payload_used) == 0);
        assert(payload_used == 5);
        assert(memcmp(payload, "\0[\xff" "AB", 5) == 0);
    }

    // The 65535-byte boundary must survive the full CLI path.
    snprintf(extract_path, sizeof(extract_path), "%s/boundary.bin", workspace);
    snprintf(command, sizeof(command),
             "'%s' --assume-u16-lengths --records --extract '%s' '%s' >'%s' "
             "2>'%s'",
             cli, extract_path, boundary_path, out_path, err_path);
    assert(run_shell(command) == 0);
    assert(read_text(out_path, text, sizeof(text)) == 0);
    assert(strstr(text, "length=65535") != NULL);
    {
        FILE *boundary = fopen(extract_path, "rb");
        assert(boundary != NULL);
        assert(fseek(boundary, 0, SEEK_END) == 0);
        assert(ftell(boundary) == 65535);
        assert(fclose(boundary) == 0);
    }

    // A zero-length header (a wrapped 65536-byte payload) must fail and must
    // not leave a partial extraction behind.
    snprintf(extract_path, sizeof(extract_path), "%s/zero.bin", workspace);
    snprintf(command, sizeof(command),
             "'%s' --assume-u16-lengths --extract '%s' '%s' >'%s' 2>'%s'", cli,
             extract_path, zero_path, out_path, err_path);
    assert(run_shell(command) != 0);
    assert(read_text(err_path, text, sizeof(text)) == 0);
    assert(strstr(text, "[0000]") != NULL);
    assert(access(extract_path, F_OK) != 0);

    // Truncated payloads must fail and clean up the partial extraction.
    snprintf(extract_path, sizeof(extract_path), "%s/trunc.bin", workspace);
    snprintf(command, sizeof(command),
             "'%s' --assume-u16-lengths --extract '%s' '%s' >'%s' 2>'%s'", cli,
             extract_path, trunc_path, out_path, err_path);
    assert(run_shell(command) != 0);
    assert(access(extract_path, F_OK) != 0);

    // Exclusive creation must never truncate an existing result.
    snprintf(command, sizeof(command),
             "'%s' --assume-u16-lengths --extract '%s' '%s' >'%s' 2>'%s'", cli,
             keep_path, valid_path, out_path, err_path);
    assert(run_shell(command) != 0);
    {
        unsigned char kept[16];
        size_t kept_used = 0;
        assert(read_bytes(keep_path, kept, sizeof(kept), &kept_used) == 0);
        assert(kept_used == sizeof(keep) - 1);
        assert(memcmp(kept, keep, sizeof(keep) - 1) == 0);
    }

    snprintf(command, sizeof(command), "rm -rf '%s'", workspace);
    assert(run_shell(command) == 0);
}

int main(int argc, char **argv) {
    (void)argc;
    check_framing();
    check_cli(argv[0]);
    puts("P21 DL3 capture framing checks: passed");
    return 0;
}
