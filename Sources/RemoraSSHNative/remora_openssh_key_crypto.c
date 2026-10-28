#include "remora_ssh.h"

#include <CommonCrypto/CommonCryptor.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/*
 * libssh2 ships the OpenBSD bcrypt_pbkdf implementation that its own OpenSSH
 * private key parser uses. It is built into RemoraLibSSH2, so reuse it instead
 * of maintaining a second copy of the algorithm.
 */
extern int _libssh2_bcrypt_pbkdf(
    const char *pass,
    size_t passlen,
    const uint8_t *salt,
    size_t saltlen,
    uint8_t *key,
    size_t keylen,
    unsigned int rounds
);

int32_t remora_ssh_bcrypt_pbkdf(
    const char *passphrase,
    size_t passphrase_length,
    const uint8_t *salt,
    size_t salt_length,
    uint8_t *output,
    size_t output_length,
    uint32_t rounds
) {
    if (passphrase == NULL || salt == NULL || salt_length == 0 ||
        output == NULL || output_length == 0 || rounds == 0) {
        return -1;
    }
    return _libssh2_bcrypt_pbkdf(
        passphrase,
        passphrase_length,
        salt,
        salt_length,
        output,
        output_length,
        (unsigned int)rounds
    ) == 0 ? 0 : -1;
}

static int32_t remora_ssh_aes_ctr_decrypt(
    const uint8_t *key,
    size_t key_length,
    const uint8_t *iv,
    const uint8_t *input,
    uint8_t *output,
    size_t input_length
) {
    uint8_t counter[kCCBlockSizeAES128];
    memcpy(counter, iv, kCCBlockSizeAES128);

    size_t offset = 0;
    while (offset < input_length) {
        uint8_t keystream[kCCBlockSizeAES128];
        size_t moved = 0;
        CCCryptorStatus status = CCCrypt(
            kCCEncrypt,
            kCCAlgorithmAES,
            kCCOptionECBMode,
            key,
            key_length,
            NULL,
            counter,
            sizeof(counter),
            keystream,
            sizeof(keystream),
            &moved
        );
        if (status != kCCSuccess || moved != sizeof(keystream)) {
            memset(keystream, 0, sizeof(keystream));
            return -1;
        }

        size_t block_length = input_length - offset;
        if (block_length > kCCBlockSizeAES128) {
            block_length = kCCBlockSizeAES128;
        }
        for (size_t index = 0; index < block_length; index += 1) {
            output[offset + index] = (uint8_t)(input[offset + index] ^ keystream[index]);
        }
        memset(keystream, 0, sizeof(keystream));
        offset += block_length;

        /* CTR mode advances the full 128-bit counter block, big endian. */
        for (int index = kCCBlockSizeAES128 - 1; index >= 0; index -= 1) {
            counter[index] = (uint8_t)(counter[index] + 1);
            if (counter[index] != 0) {
                break;
            }
        }
    }
    memset(counter, 0, sizeof(counter));
    return 0;
}

int32_t remora_ssh_openssh_private_key_decrypt(
    const uint8_t *key,
    size_t key_length,
    const uint8_t *iv,
    size_t iv_length,
    const uint8_t *input,
    size_t input_length,
    uint8_t *output,
    bool cipher_block_chaining
) {
    if (key == NULL || iv == NULL || input == NULL || output == NULL) {
        return -1;
    }
    if (iv_length != kCCBlockSizeAES128) {
        return -1;
    }
    if (key_length != kCCKeySizeAES128 &&
        key_length != kCCKeySizeAES192 &&
        key_length != kCCKeySizeAES256) {
        return -1;
    }

    if (cipher_block_chaining) {
        if (input_length == 0 || (input_length % kCCBlockSizeAES128) != 0) {
            return -1;
        }
        size_t moved = 0;
        CCCryptorStatus status = CCCrypt(
            kCCDecrypt,
            kCCAlgorithmAES,
            0,
            key,
            key_length,
            iv,
            input,
            input_length,
            output,
            input_length,
            &moved
        );
        return (status == kCCSuccess && moved == input_length) ? 0 : -1;
    }

    return remora_ssh_aes_ctr_decrypt(key, key_length, iv, input, output, input_length);
}
