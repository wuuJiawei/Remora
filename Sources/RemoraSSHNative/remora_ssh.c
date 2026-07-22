#include "remora_ssh.h"

#include <stdlib.h>
#include <string.h>

#define REMORA_SSH_CONTEXT_MAGIC 0x524D5353u

struct remora_ssh_context {
    uint32_t magic;
};

static void remora_ssh_error_reset(remora_ssh_error *error) {
    if (error == NULL) {
        return;
    }

    memset(error, 0, sizeof(*error));
    error->code = REMORA_SSH_ERROR_NONE;
}

static void remora_ssh_error_set(
    remora_ssh_error *error,
    remora_ssh_error_code code,
    const char *message
) {
    if (error == NULL) {
        return;
    }

    remora_ssh_error_reset(error);
    error->code = code;
    if (message != NULL) {
        (void)strncpy(error->message, message, sizeof(error->message) - 1);
    }
}

uint32_t remora_ssh_native_abi_version(void) {
    return REMORA_SSH_NATIVE_ABI_VERSION;
}

remora_ssh_error_code remora_ssh_context_create(
    remora_ssh_context **out_context,
    remora_ssh_error *out_error
) {
    remora_ssh_error_reset(out_error);
    if (out_context == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            "out_context must not be null"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }

    *out_context = NULL;
    remora_ssh_context *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_ALLOCATION_FAILED,
            "unable to allocate native SSH context"
        );
        return REMORA_SSH_ERROR_ALLOCATION_FAILED;
    }

    context->magic = REMORA_SSH_CONTEXT_MAGIC;
    *out_context = context;
    return REMORA_SSH_ERROR_NONE;
}

void remora_ssh_context_destroy(remora_ssh_context **context) {
    if (context == NULL || *context == NULL) {
        return;
    }

    (*context)->magic = 0;
    free(*context);
    *context = NULL;
}

bool remora_ssh_context_is_valid(const remora_ssh_context *context) {
    return context != NULL && context->magic == REMORA_SSH_CONTEXT_MAGIC;
}

const char *remora_ssh_error_message(const remora_ssh_error *error) {
    return error == NULL ? "" : error->message;
}
