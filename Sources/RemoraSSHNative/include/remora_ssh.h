#ifndef REMORA_SSH_H
#define REMORA_SSH_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define REMORA_SSH_NATIVE_ABI_VERSION 1
#define REMORA_SSH_ERROR_MESSAGE_CAPACITY 256

typedef struct remora_ssh_context remora_ssh_context;

typedef enum remora_ssh_error_code {
    REMORA_SSH_ERROR_NONE = 0,
    REMORA_SSH_ERROR_INVALID_ARGUMENT = 1,
    REMORA_SSH_ERROR_ALLOCATION_FAILED = 2,
    REMORA_SSH_ERROR_INVALID_STATE = 3,
    REMORA_SSH_ERROR_BACKEND_UNAVAILABLE = 4
} remora_ssh_error_code;

typedef struct remora_ssh_error {
    remora_ssh_error_code code;
    int32_t backend_code;
    char message[REMORA_SSH_ERROR_MESSAGE_CAPACITY];
} remora_ssh_error;

uint32_t remora_ssh_native_abi_version(void);

remora_ssh_error_code remora_ssh_context_create(
    remora_ssh_context **out_context,
    remora_ssh_error *out_error
);

void remora_ssh_context_destroy(remora_ssh_context **context);

bool remora_ssh_context_is_valid(const remora_ssh_context *context);

const char *remora_ssh_error_message(const remora_ssh_error *error);

#ifdef __cplusplus
}
#endif

#endif
