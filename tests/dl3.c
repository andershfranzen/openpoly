#include "../driver/macos/p21-dl3.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static const unsigned char p21_configuration[] = {
    0x09, 0x04, 0x00, 0x00, 0x02, 0xff, 0x00, 0x03, 0x00,
    0x0c, 0x5f, 0x01, 0x00, 0x0a, 0x00, 0x04, 0x04, 0x01, 0x00, 0x04, 0x00,
    0x07, 0x05, 0x02, 0x02, 0x00, 0x04, 0x00,
    0x06, 0x30, 0x00, 0x00, 0x00, 0x00,
    0x07, 0x05, 0x84, 0x02, 0x00, 0x04, 0x00,
    0x06, 0x30, 0x00, 0x00, 0x00, 0x00,
    0x09, 0x04, 0x01, 0x00, 0x00, 0xfe, 0x01, 0x01, 0x00,
    0x09, 0x21, 0x01, 0xc8, 0x00, 0x00, 0x04, 0x01, 0x01,
    0x10, 0x40, 0x0c, 0x02, 0x0f, 0x0a, 0x0b, 0x30,
    'F', 'f', 'l', 'y', 'M', 'o', 'n', 'i',
};

int main(void) {
    p21_dl3_identity identity = {0};
    char error[256];
    assert(p21_dl3_parse_config(p21_configuration, sizeof(p21_configuration),
                                &identity, error, sizeof(error)) == 0);
    assert(identity.interface_number == 0);
    assert(identity.bulk_out == 0x02);
    assert(identity.bulk_in == 0x84);
    assert(identity.max_packet_size == 1024);
    assert(identity.firmware_major == 12);
    assert(identity.firmware_minor == 2);
    assert(identity.firmware_patch == 15);
    assert(strcmp(identity.platform, "FflyMoni") == 0);

    unsigned char changed[sizeof(p21_configuration)];
    memcpy(changed, p21_configuration, sizeof(changed));
    changed[sizeof(changed) - 1] = 'x';
    assert(p21_dl3_parse_config(changed, sizeof(changed), &identity,
                                error, sizeof(error)) != 0);
    assert(strstr(error, "unsupported DL3 platform") != NULL);

    memcpy(changed, p21_configuration, sizeof(changed));
    changed[23] = 0x03;
    assert(p21_dl3_parse_config(changed, sizeof(changed), &identity,
                                error, sizeof(error)) != 0);
    assert(strstr(error, "unexpected Firefly transport shape") != NULL);

    memcpy(changed, p21_configuration, sizeof(changed));
    changed[38] = 0x00;
    changed[39] = 0x02;
    assert(p21_dl3_parse_config(changed, sizeof(changed), &identity,
                                error, sizeof(error)) != 0);
    assert(strstr(error, "packet sizes do not match") != NULL);

    memcpy(changed, p21_configuration, sizeof(changed));
    changed[7] = 0x02;
    assert(p21_dl3_parse_config(changed, sizeof(changed), &identity,
                                error, sizeof(error)) != 0);
    assert(strstr(error, "expected one ff/00/03") != NULL);

    memcpy(changed, p21_configuration, sizeof(changed));
    changed[2] = 0x02;
    assert(p21_dl3_parse_config(changed, sizeof(changed), &identity,
                                error, sizeof(error)) != 0);
    assert(strstr(error, "unexpected DL3 interface/alternate setting") != NULL);

    memcpy(changed, p21_configuration, sizeof(changed));
    changed[24] = 0x03;
    assert(p21_dl3_parse_config(changed, sizeof(changed), &identity,
                                error, sizeof(error)) != 0);
    assert(strstr(error, "non-bulk endpoint") != NULL);

    memcpy(changed, p21_configuration, sizeof(changed));
    changed[4] = 0x03;
    assert(p21_dl3_parse_config(changed, sizeof(changed), &identity,
                                error, sizeof(error)) != 0);
    assert(strstr(error, "expected exactly two DL3 endpoints") != NULL);

    unsigned char duplicate_identity[sizeof(p21_configuration) + 16];
    memcpy(duplicate_identity, p21_configuration, sizeof(p21_configuration));
    memcpy(duplicate_identity + sizeof(p21_configuration), p21_configuration + 65, 16);
    assert(p21_dl3_parse_config(duplicate_identity, sizeof(duplicate_identity),
                                &identity, error, sizeof(error)) != 0);
    assert(strstr(error, "expected one type-0x40 identity; found 2") != NULL);

    memcpy(changed, p21_configuration, sizeof(changed));
    changed[0] = 0x01;
    assert(p21_dl3_parse_config(changed, sizeof(changed), &identity,
                                error, sizeof(error)) != 0);
    assert(strstr(error, "invalid descriptor length") != NULL);

    assert(p21_dl3_parse_config(p21_configuration, sizeof(p21_configuration) - 1,
                                &identity, error, sizeof(error)) != 0);
    assert(strstr(error, "invalid descriptor length") != NULL);
    puts("P21 Firefly descriptor checks: passed");
    return 0;
}
