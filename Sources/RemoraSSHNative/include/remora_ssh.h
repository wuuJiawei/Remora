#ifndef REMORA_SSH_H
#define REMORA_SSH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define REMORA_SSH_NATIVE_ABI_VERSION 2
#define REMORA_SSH_ERROR_MESSAGE_CAPACITY 256
#define REMORA_SSH_MAX_KEYBOARD_PROMPTS 16
#define REMORA_SSH_MAX_KEYBOARD_RESPONSE_BYTES 4096
#define REMORA_SSH_HOST_KEY_SHA256_LENGTH 32

typedef struct remora_ssh_context remora_ssh_context;
typedef struct remora_ssh_channel remora_ssh_channel;

typedef enum remora_ssh_error_code {
    REMORA_SSH_ERROR_NONE = 0,
    REMORA_SSH_ERROR_INVALID_ARGUMENT = 1,
    REMORA_SSH_ERROR_ALLOCATION_FAILED = 2,
    REMORA_SSH_ERROR_INVALID_STATE = 3,
    REMORA_SSH_ERROR_BACKEND_UNAVAILABLE = 4,
    REMORA_SSH_ERROR_WOULD_BLOCK = 5,
    REMORA_SSH_ERROR_BACKEND_FAILURE = 6,
    REMORA_SSH_ERROR_BUFFER_TOO_SMALL = 7,
    REMORA_SSH_ERROR_AUTHENTICATION_FAILED = 8,
    REMORA_SSH_ERROR_HOST_KEY_UNAVAILABLE = 9,
    REMORA_SSH_ERROR_CHALLENGE_CANCELLED = 10,
    REMORA_SSH_ERROR_CHANNEL_CLOSED = 11
} remora_ssh_error_code;

typedef enum remora_ssh_block_direction {
    REMORA_SSH_BLOCK_NONE = 0,
    REMORA_SSH_BLOCK_INBOUND = 1 << 0,
    REMORA_SSH_BLOCK_OUTBOUND = 1 << 1
} remora_ssh_block_direction;

typedef enum remora_ssh_host_key_algorithm {
    REMORA_SSH_HOST_KEY_UNKNOWN = 0,
    REMORA_SSH_HOST_KEY_RSA = 1,
    REMORA_SSH_HOST_KEY_DSS = 2,
    REMORA_SSH_HOST_KEY_ECDSA_256 = 3,
    REMORA_SSH_HOST_KEY_ECDSA_384 = 4,
    REMORA_SSH_HOST_KEY_ECDSA_521 = 5,
    REMORA_SSH_HOST_KEY_ED25519 = 6
} remora_ssh_host_key_algorithm;

typedef enum remora_ssh_channel_stream {
    REMORA_SSH_CHANNEL_STANDARD_OUTPUT = 0,
    REMORA_SSH_CHANNEL_STANDARD_ERROR = 1
} remora_ssh_channel_stream;

typedef struct remora_ssh_error {
    remora_ssh_error_code code;
    int32_t backend_code;
    char message[REMORA_SSH_ERROR_MESSAGE_CAPACITY];
} remora_ssh_error;

typedef struct remora_ssh_host_key {
    remora_ssh_host_key_algorithm algorithm;
    uint8_t sha256[REMORA_SSH_HOST_KEY_SHA256_LENGTH];
} remora_ssh_host_key;

typedef struct remora_ssh_keyboard_prompt {
    const uint8_t *bytes;
    size_t length;
    bool echo;
} remora_ssh_keyboard_prompt;

typedef struct remora_ssh_keyboard_response {
    uint8_t bytes[REMORA_SSH_MAX_KEYBOARD_RESPONSE_BYTES];
    size_t length;
} remora_ssh_keyboard_response;

typedef bool (*remora_ssh_keyboard_challenge_handler)(
    void *context,
    const uint8_t *name,
    size_t name_length,
    const uint8_t *instruction,
    size_t instruction_length,
    const remora_ssh_keyboard_prompt *prompts,
    size_t prompt_count,
    remora_ssh_keyboard_response *responses
);

uint32_t remora_ssh_native_abi_version(void);
const char *remora_ssh_backend_version(void);
const char *remora_ssh_crypto_backend(void);

remora_ssh_error_code remora_ssh_context_create(
    remora_ssh_context **out_context,
    remora_ssh_error *out_error
);

void remora_ssh_context_destroy(remora_ssh_context **context);
bool remora_ssh_context_is_valid(const remora_ssh_context *context);
const char *remora_ssh_error_message(const remora_ssh_error *error);

remora_ssh_error_code remora_ssh_context_handshake(
    remora_ssh_context *context,
    int socket_descriptor,
    remora_ssh_error *out_error
);

uint32_t remora_ssh_context_block_directions(const remora_ssh_context *context);
bool remora_ssh_context_is_authenticated(const remora_ssh_context *context);

remora_ssh_error_code remora_ssh_context_host_key(
    remora_ssh_context *context,
    remora_ssh_host_key *out_host_key,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_context_authentication_methods(
    remora_ssh_context *context,
    const char *username,
    char *buffer,
    size_t buffer_capacity,
    size_t *out_length,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_context_authenticate_password(
    remora_ssh_context *context,
    const char *username,
    const char *password,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_context_authenticate_private_key(
    remora_ssh_context *context,
    const char *username,
    const char *public_key_path,
    const char *private_key_path,
    const char *passphrase,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_context_authenticate_agent(
    remora_ssh_context *context,
    const char *username,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_context_authenticate_keyboard_interactive(
    remora_ssh_context *context,
    const char *username,
    remora_ssh_keyboard_challenge_handler challenge_handler,
    void *challenge_context,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_channel_create_shell(
    remora_ssh_context *context,
    const char *terminal_type,
    uint32_t columns,
    uint32_t rows,
    remora_ssh_channel **out_channel,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_channel_create_exec(
    remora_ssh_context *context,
    const char *command,
    remora_ssh_channel **out_channel,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_channel_start(
    remora_ssh_channel *channel,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_channel_read(
    remora_ssh_channel *channel,
    remora_ssh_channel_stream stream,
    uint8_t *buffer,
    size_t buffer_capacity,
    size_t *out_length,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_channel_write(
    remora_ssh_channel *channel,
    const uint8_t *bytes,
    size_t length,
    size_t *out_written,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_channel_send_eof(
    remora_ssh_channel *channel,
    remora_ssh_error *out_error
);

remora_ssh_error_code remora_ssh_channel_resize(
    remora_ssh_channel *channel,
    uint32_t columns,
    uint32_t rows,
    remora_ssh_error *out_error
);

bool remora_ssh_channel_is_eof(const remora_ssh_channel *channel);
int32_t remora_ssh_channel_exit_status(const remora_ssh_channel *channel);

remora_ssh_error_code remora_ssh_channel_close(
    remora_ssh_channel *channel,
    remora_ssh_error *out_error
);

void remora_ssh_channel_destroy(remora_ssh_channel **channel);
bool remora_ssh_channel_is_valid(const remora_ssh_channel *channel);

#ifdef __cplusplus
}
#endif

#endif
