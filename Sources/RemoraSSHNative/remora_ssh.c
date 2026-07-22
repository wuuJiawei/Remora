#include "remora_ssh.h"

#include <libssh2.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#define REMORA_SSH_CONTEXT_MAGIC 0x524D5353u
#define REMORA_SSH_CHANNEL_MAGIC 0x524D4348u

typedef enum remora_ssh_agent_phase {
    REMORA_SSH_AGENT_IDLE = 0,
    REMORA_SSH_AGENT_CONNECTING,
    REMORA_SSH_AGENT_LISTING,
    REMORA_SSH_AGENT_AUTHENTICATING
} remora_ssh_agent_phase;

typedef enum remora_ssh_shell_phase {
    REMORA_SSH_SHELL_OPENING = 0,
    REMORA_SSH_SHELL_REQUESTING_PTY,
    REMORA_SSH_SHELL_STARTING,
    REMORA_SSH_SHELL_READY,
    REMORA_SSH_SHELL_SENDING_EOF,
    REMORA_SSH_SHELL_CLOSING,
    REMORA_SSH_SHELL_WAITING_CLOSED,
    REMORA_SSH_SHELL_CLOSED
} remora_ssh_shell_phase;

struct remora_ssh_context {
    uint32_t magic;
    LIBSSH2_SESSION *session;
    int socket_descriptor;
    bool handshake_complete;
    LIBSSH2_AGENT *agent;
    struct libssh2_agent_publickey *agent_identity;
    remora_ssh_agent_phase agent_phase;
    char *agent_username;
    remora_ssh_keyboard_challenge_handler keyboard_handler;
    void *keyboard_context;
    bool keyboard_challenge_failed;
    size_t channel_count;
    bool destroy_requested;
};

struct remora_ssh_channel {
    uint32_t magic;
    remora_ssh_context *context;
    LIBSSH2_CHANNEL *channel;
    remora_ssh_shell_phase phase;
    char terminal_type[64];
    uint32_t columns;
    uint32_t rows;
    int32_t exit_status;
};

static pthread_once_t remora_ssh_backend_once = PTHREAD_ONCE_INIT;
static int remora_ssh_backend_init_result = LIBSSH2_ERROR_NONE;

static void remora_ssh_backend_initialize(void) {
    remora_ssh_backend_init_result = libssh2_init(0);
}

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
    int backend_code,
    const char *message
) {
    if (error == NULL) {
        return;
    }
    remora_ssh_error_reset(error);
    error->code = code;
    error->backend_code = (int32_t)backend_code;
    if (message != NULL) {
        (void)strncpy(error->message, message, sizeof(error->message) - 1);
    }
}

static bool remora_ssh_context_valid(const remora_ssh_context *context) {
    return context != NULL && context->magic == REMORA_SSH_CONTEXT_MAGIC &&
        context->session != NULL && !context->destroy_requested;
}

static bool remora_ssh_channel_valid(const remora_ssh_channel *channel) {
    return channel != NULL && channel->magic == REMORA_SSH_CHANNEL_MAGIC &&
        remora_ssh_context_valid(channel->context);
}

static remora_ssh_error_code remora_ssh_invalid_context(remora_ssh_error *error) {
    remora_ssh_error_set(
        error,
        REMORA_SSH_ERROR_INVALID_STATE,
        0,
        "native SSH context is closed"
    );
    return REMORA_SSH_ERROR_INVALID_STATE;
}

static remora_ssh_error_code remora_ssh_invalid_channel(remora_ssh_error *error) {
    remora_ssh_error_set(
        error,
        REMORA_SSH_ERROR_CHANNEL_CLOSED,
        0,
        "native SSH channel is closed"
    );
    return REMORA_SSH_ERROR_CHANNEL_CLOSED;
}

static remora_ssh_error_code remora_ssh_map_result(
    remora_ssh_context *context,
    int result,
    const char *fallback_message,
    remora_ssh_error *error
) {
    if (result == LIBSSH2_ERROR_NONE) {
        remora_ssh_error_reset(error);
        return REMORA_SSH_ERROR_NONE;
    }
    if (result == LIBSSH2_ERROR_EAGAIN) {
        remora_ssh_error_set(
            error,
            REMORA_SSH_ERROR_WOULD_BLOCK,
            result,
            "native SSH operation would block"
        );
        return REMORA_SSH_ERROR_WOULD_BLOCK;
    }

    remora_ssh_error_code code = REMORA_SSH_ERROR_BACKEND_FAILURE;
    if (result == LIBSSH2_ERROR_AUTHENTICATION_FAILED ||
        result == LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED) {
        code = REMORA_SSH_ERROR_AUTHENTICATION_FAILED;
    } else if (result == LIBSSH2_ERROR_CHANNEL_CLOSED) {
        code = REMORA_SSH_ERROR_CHANNEL_CLOSED;
    }

    char *backend_message = NULL;
    int backend_message_length = 0;
    if (remora_ssh_context_valid(context)) {
        (void)libssh2_session_last_error(
            context->session,
            &backend_message,
            &backend_message_length,
            0
        );
    }
    const char *message = backend_message != NULL && backend_message_length > 0
        ? backend_message
        : fallback_message;
    remora_ssh_error_set(error, code, result, message);
    return code;
}

static void remora_ssh_agent_reset(remora_ssh_context *context) {
    if (context == NULL) {
        return;
    }
    if (context->agent != NULL) {
        (void)libssh2_agent_disconnect(context->agent);
        libssh2_agent_free(context->agent);
    }
    context->agent = NULL;
    context->agent_identity = NULL;
    context->agent_phase = REMORA_SSH_AGENT_IDLE;
    free(context->agent_username);
    context->agent_username = NULL;
}

static void remora_ssh_context_finalize(remora_ssh_context *context) {
    if (context == NULL || context->magic != REMORA_SSH_CONTEXT_MAGIC) {
        return;
    }
    if (context->session != NULL) {
        (void)libssh2_session_free(context->session);
        context->session = NULL;
    }
    context->magic = 0;
    free(context);
}

static void remora_ssh_keyboard_callback(
    const char *name,
    int name_length,
    const char *instruction,
    int instruction_length,
    int prompt_count,
    const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
    LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses,
    void **abstract
) {
    remora_ssh_context *context = abstract == NULL ? NULL : *abstract;
    if (!remora_ssh_context_valid(context) || context->keyboard_handler == NULL ||
        prompt_count < 0 || prompt_count > REMORA_SSH_MAX_KEYBOARD_PROMPTS) {
        if (context != NULL) {
            context->keyboard_challenge_failed = true;
        }
        return;
    }

    remora_ssh_keyboard_prompt remora_prompts[REMORA_SSH_MAX_KEYBOARD_PROMPTS];
    remora_ssh_keyboard_response remora_responses[REMORA_SSH_MAX_KEYBOARD_PROMPTS];
    memset(remora_prompts, 0, sizeof(remora_prompts));
    memset(remora_responses, 0, sizeof(remora_responses));

    for (int index = 0; index < prompt_count; index++) {
        remora_prompts[index].bytes = prompts[index].text;
        remora_prompts[index].length = prompts[index].length;
        remora_prompts[index].echo = prompts[index].echo != 0;
    }

    bool accepted = context->keyboard_handler(
        context->keyboard_context,
        (const uint8_t *)name,
        name_length > 0 ? (size_t)name_length : 0,
        (const uint8_t *)instruction,
        instruction_length > 0 ? (size_t)instruction_length : 0,
        remora_prompts,
        (size_t)prompt_count,
        remora_responses
    );
    if (!accepted) {
        context->keyboard_challenge_failed = true;
        return;
    }

    for (int index = 0; index < prompt_count; index++) {
        size_t length = remora_responses[index].length;
        if (length > REMORA_SSH_MAX_KEYBOARD_RESPONSE_BYTES || length > UINT32_MAX) {
            context->keyboard_challenge_failed = true;
            return;
        }
        responses[index].text = malloc(length + 1);
        if (responses[index].text == NULL) {
            context->keyboard_challenge_failed = true;
            return;
        }
        memcpy(responses[index].text, remora_responses[index].bytes, length);
        responses[index].text[length] = '\0';
        responses[index].length = (unsigned int)length;
    }
}

uint32_t remora_ssh_native_abi_version(void) {
    return REMORA_SSH_NATIVE_ABI_VERSION;
}

const char *remora_ssh_backend_version(void) {
    const char *version = libssh2_version(0);
    return version == NULL ? "unknown" : version;
}

const char *remora_ssh_crypto_backend(void) {
    return libssh2_crypto_engine() == libssh2_mbedtls ? "mbedTLS" : "unexpected";
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
            0,
            "out_context must not be null"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }
    *out_context = NULL;

    (void)pthread_once(&remora_ssh_backend_once, remora_ssh_backend_initialize);
    if (remora_ssh_backend_init_result != LIBSSH2_ERROR_NONE) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_BACKEND_UNAVAILABLE,
            remora_ssh_backend_init_result,
            "unable to initialize libssh2"
        );
        return REMORA_SSH_ERROR_BACKEND_UNAVAILABLE;
    }

    remora_ssh_context *context = calloc(1, sizeof(*context));
    if (context == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_ALLOCATION_FAILED,
            0,
            "unable to allocate native SSH context"
        );
        return REMORA_SSH_ERROR_ALLOCATION_FAILED;
    }

    context->magic = REMORA_SSH_CONTEXT_MAGIC;
    context->socket_descriptor = -1;
    context->session = libssh2_session_init_ex(NULL, NULL, NULL, context);
    if (context->session == NULL) {
        context->magic = 0;
        free(context);
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_ALLOCATION_FAILED,
            0,
            "unable to allocate libssh2 session"
        );
        return REMORA_SSH_ERROR_ALLOCATION_FAILED;
    }
    libssh2_session_set_blocking(context->session, 0);
    *out_context = context;
    return REMORA_SSH_ERROR_NONE;
}

void remora_ssh_context_destroy(remora_ssh_context **context_pointer) {
    if (context_pointer == NULL || *context_pointer == NULL) {
        return;
    }
    remora_ssh_context *context = *context_pointer;
    if (context->magic == REMORA_SSH_CONTEXT_MAGIC) {
        remora_ssh_agent_reset(context);
        context->destroy_requested = true;
        if (context->channel_count == 0) {
            remora_ssh_context_finalize(context);
        }
    }
    *context_pointer = NULL;
}

bool remora_ssh_context_is_valid(const remora_ssh_context *context) {
    return remora_ssh_context_valid(context);
}

const char *remora_ssh_error_message(const remora_ssh_error *error) {
    return error == NULL ? "" : error->message;
}

remora_ssh_error_code remora_ssh_context_handshake(
    remora_ssh_context *context,
    int socket_descriptor,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_context_valid(context)) {
        return remora_ssh_invalid_context(out_error);
    }
    if (socket_descriptor < 0 ||
        (context->socket_descriptor >= 0 && context->socket_descriptor != socket_descriptor)) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "socket descriptor changed during handshake"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }
    if (context->handshake_complete) {
        remora_ssh_error_reset(out_error);
        return REMORA_SSH_ERROR_NONE;
    }
    context->socket_descriptor = socket_descriptor;
    int result = libssh2_session_handshake(context->session, socket_descriptor);
    if (result == LIBSSH2_ERROR_NONE) {
        context->handshake_complete = true;
    }
    return remora_ssh_map_result(context, result, "SSH handshake failed", out_error);
}

uint32_t remora_ssh_context_block_directions(const remora_ssh_context *context) {
    if (!remora_ssh_context_valid(context)) {
        return REMORA_SSH_BLOCK_NONE;
    }
    int backend_directions = libssh2_session_block_directions(context->session);
    uint32_t directions = REMORA_SSH_BLOCK_NONE;
    if ((backend_directions & LIBSSH2_SESSION_BLOCK_INBOUND) != 0) {
        directions |= REMORA_SSH_BLOCK_INBOUND;
    }
    if ((backend_directions & LIBSSH2_SESSION_BLOCK_OUTBOUND) != 0) {
        directions |= REMORA_SSH_BLOCK_OUTBOUND;
    }
    return directions;
}

bool remora_ssh_context_is_authenticated(const remora_ssh_context *context) {
    return remora_ssh_context_valid(context) &&
        libssh2_userauth_authenticated(context->session) != 0;
}

remora_ssh_error_code remora_ssh_context_host_key(
    remora_ssh_context *context,
    remora_ssh_host_key *out_host_key,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_context_valid(context)) {
        return remora_ssh_invalid_context(out_error);
    }
    if (!context->handshake_complete || out_host_key == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_STATE,
            0,
            "host key requested before handshake"
        );
        return REMORA_SSH_ERROR_INVALID_STATE;
    }

    size_t raw_key_length = 0;
    int key_type = LIBSSH2_HOSTKEY_TYPE_UNKNOWN;
    const char *raw_key = libssh2_session_hostkey(
        context->session,
        &raw_key_length,
        &key_type
    );
    const char *sha256 = libssh2_hostkey_hash(
        context->session,
        LIBSSH2_HOSTKEY_HASH_SHA256
    );
    if (raw_key == NULL || raw_key_length == 0 || sha256 == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_HOST_KEY_UNAVAILABLE,
            libssh2_session_last_errno(context->session),
            "server host key is unavailable"
        );
        return REMORA_SSH_ERROR_HOST_KEY_UNAVAILABLE;
    }

    memset(out_host_key, 0, sizeof(*out_host_key));
    out_host_key->algorithm = (remora_ssh_host_key_algorithm)key_type;
    memcpy(out_host_key->sha256, sha256, REMORA_SSH_HOST_KEY_SHA256_LENGTH);
    remora_ssh_error_reset(out_error);
    return REMORA_SSH_ERROR_NONE;
}

remora_ssh_error_code remora_ssh_context_authentication_methods(
    remora_ssh_context *context,
    const char *username,
    char *buffer,
    size_t buffer_capacity,
    size_t *out_length,
    remora_ssh_error *out_error
) {
    if (out_length != NULL) {
        *out_length = 0;
    }
    if (!remora_ssh_context_valid(context)) {
        return remora_ssh_invalid_context(out_error);
    }
    if (!context->handshake_complete || username == NULL || out_length == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "authentication method arguments are invalid"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }

    char *methods = libssh2_userauth_list(
        context->session,
        username,
        (unsigned int)strlen(username)
    );
    if (methods == NULL) {
        int backend_code = libssh2_session_last_errno(context->session);
        if (backend_code == LIBSSH2_ERROR_NONE &&
            libssh2_userauth_authenticated(context->session) != 0) {
            remora_ssh_error_reset(out_error);
            return REMORA_SSH_ERROR_NONE;
        }
        return remora_ssh_map_result(
            context,
            backend_code,
            "unable to read authentication methods",
            out_error
        );
    }

    size_t methods_length = strlen(methods);
    *out_length = methods_length;
    if (buffer == NULL || buffer_capacity <= methods_length) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_BUFFER_TOO_SMALL,
            0,
            "authentication method buffer is too small"
        );
        return REMORA_SSH_ERROR_BUFFER_TOO_SMALL;
    }
    memcpy(buffer, methods, methods_length + 1);
    remora_ssh_error_reset(out_error);
    return REMORA_SSH_ERROR_NONE;
}

remora_ssh_error_code remora_ssh_context_authenticate_password(
    remora_ssh_context *context,
    const char *username,
    const char *password,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_context_valid(context)) {
        return remora_ssh_invalid_context(out_error);
    }
    if (username == NULL || password == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "password authentication arguments are invalid"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }
    int result = libssh2_userauth_password_ex(
        context->session,
        username,
        (unsigned int)strlen(username),
        password,
        (unsigned int)strlen(password),
        NULL
    );
    return remora_ssh_map_result(context, result, "password authentication failed", out_error);
}

remora_ssh_error_code remora_ssh_context_authenticate_private_key(
    remora_ssh_context *context,
    const char *username,
    const char *public_key_path,
    const char *private_key_path,
    const char *passphrase,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_context_valid(context)) {
        return remora_ssh_invalid_context(out_error);
    }
    if (username == NULL || private_key_path == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "private-key authentication arguments are invalid"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }
    int result = libssh2_userauth_publickey_fromfile_ex(
        context->session,
        username,
        (unsigned int)strlen(username),
        public_key_path,
        private_key_path,
        passphrase
    );
    return remora_ssh_map_result(context, result, "private-key authentication failed", out_error);
}

remora_ssh_error_code remora_ssh_context_authenticate_agent(
    remora_ssh_context *context,
    const char *username,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_context_valid(context)) {
        return remora_ssh_invalid_context(out_error);
    }
    if (username == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "agent authentication username is missing"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }

    if (context->agent_phase == REMORA_SSH_AGENT_IDLE) {
        context->agent = libssh2_agent_init(context->session);
        context->agent_username = strdup(username);
        if (context->agent == NULL || context->agent_username == NULL) {
            remora_ssh_agent_reset(context);
            remora_ssh_error_set(
                out_error,
                REMORA_SSH_ERROR_ALLOCATION_FAILED,
                0,
                "unable to initialize SSH agent authentication"
            );
            return REMORA_SSH_ERROR_ALLOCATION_FAILED;
        }
        context->agent_phase = REMORA_SSH_AGENT_CONNECTING;
    } else if (strcmp(context->agent_username, username) != 0) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_STATE,
            0,
            "agent authentication username changed"
        );
        return REMORA_SSH_ERROR_INVALID_STATE;
    }

    if (context->agent_phase == REMORA_SSH_AGENT_CONNECTING) {
        int result = libssh2_agent_connect(context->agent);
        if (result != LIBSSH2_ERROR_NONE) {
            return remora_ssh_map_result(context, result, "unable to connect to SSH agent", out_error);
        }
        context->agent_phase = REMORA_SSH_AGENT_LISTING;
    }

    if (context->agent_phase == REMORA_SSH_AGENT_LISTING) {
        int result = libssh2_agent_list_identities(context->agent);
        if (result != LIBSSH2_ERROR_NONE) {
            return remora_ssh_map_result(context, result, "unable to list SSH agent identities", out_error);
        }
        context->agent_phase = REMORA_SSH_AGENT_AUTHENTICATING;
        context->agent_identity = NULL;
    }

    while (context->agent_phase == REMORA_SSH_AGENT_AUTHENTICATING) {
        if (context->agent_identity == NULL) {
            struct libssh2_agent_publickey *identity = NULL;
            int result = libssh2_agent_get_identity(context->agent, &identity, NULL);
            if (result == 1) {
                remora_ssh_agent_reset(context);
                remora_ssh_error_set(
                    out_error,
                    REMORA_SSH_ERROR_AUTHENTICATION_FAILED,
                    LIBSSH2_ERROR_AUTHENTICATION_FAILED,
                    "SSH agent has no usable identity"
                );
                return REMORA_SSH_ERROR_AUTHENTICATION_FAILED;
            }
            if (result != LIBSSH2_ERROR_NONE) {
                return remora_ssh_map_result(context, result, "unable to read SSH agent identity", out_error);
            }
            context->agent_identity = identity;
        }

        int result = libssh2_agent_userauth(context->agent, username, context->agent_identity);
        if (result == LIBSSH2_ERROR_NONE) {
            remora_ssh_agent_reset(context);
            remora_ssh_error_reset(out_error);
            return REMORA_SSH_ERROR_NONE;
        }
        if (result == LIBSSH2_ERROR_EAGAIN) {
            return remora_ssh_map_result(context, result, "SSH agent authentication would block", out_error);
        }

        struct libssh2_agent_publickey *next_identity = NULL;
        int next_result = libssh2_agent_get_identity(
            context->agent,
            &next_identity,
            context->agent_identity
        );
        if (next_result == LIBSSH2_ERROR_NONE) {
            context->agent_identity = next_identity;
            continue;
        }
        remora_ssh_agent_reset(context);
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_AUTHENTICATION_FAILED,
            result,
            "SSH agent identities were rejected"
        );
        return REMORA_SSH_ERROR_AUTHENTICATION_FAILED;
    }

    return remora_ssh_invalid_context(out_error);
}

remora_ssh_error_code remora_ssh_context_authenticate_keyboard_interactive(
    remora_ssh_context *context,
    const char *username,
    remora_ssh_keyboard_challenge_handler challenge_handler,
    void *challenge_context,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_context_valid(context)) {
        return remora_ssh_invalid_context(out_error);
    }
    if (username == NULL || challenge_handler == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "keyboard-interactive authentication arguments are invalid"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }

    context->keyboard_handler = challenge_handler;
    context->keyboard_context = challenge_context;
    context->keyboard_challenge_failed = false;
    int result = libssh2_userauth_keyboard_interactive_ex(
        context->session,
        username,
        (unsigned int)strlen(username),
        remora_ssh_keyboard_callback
    );
    context->keyboard_handler = NULL;
    context->keyboard_context = NULL;

    if (context->keyboard_challenge_failed) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_CHALLENGE_CANCELLED,
            result,
            "keyboard-interactive challenge was cancelled"
        );
        return REMORA_SSH_ERROR_CHALLENGE_CANCELLED;
    }
    return remora_ssh_map_result(
        context,
        result,
        "keyboard-interactive authentication failed",
        out_error
    );
}

remora_ssh_error_code remora_ssh_channel_create_shell(
    remora_ssh_context *context,
    const char *terminal_type,
    uint32_t columns,
    uint32_t rows,
    remora_ssh_channel **out_channel,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_context_valid(context)) {
        return remora_ssh_invalid_context(out_error);
    }
    if (!remora_ssh_context_is_authenticated(context) || out_channel == NULL ||
        terminal_type == NULL || terminal_type[0] == '\0' || columns == 0 || rows == 0) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "shell channel arguments are invalid"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }
    *out_channel = NULL;

    remora_ssh_channel *channel = calloc(1, sizeof(*channel));
    if (channel == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_ALLOCATION_FAILED,
            0,
            "unable to allocate native SSH channel"
        );
        return REMORA_SSH_ERROR_ALLOCATION_FAILED;
    }
    channel->magic = REMORA_SSH_CHANNEL_MAGIC;
    channel->context = context;
    channel->phase = REMORA_SSH_SHELL_OPENING;
    channel->columns = columns;
    channel->rows = rows;
    (void)strncpy(channel->terminal_type, terminal_type, sizeof(channel->terminal_type) - 1);
    context->channel_count += 1;
    *out_channel = channel;
    remora_ssh_error_reset(out_error);
    return REMORA_SSH_ERROR_NONE;
}

remora_ssh_error_code remora_ssh_channel_start(
    remora_ssh_channel *channel,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_channel_valid(channel)) {
        return remora_ssh_invalid_channel(out_error);
    }
    remora_ssh_context *context = channel->context;

    if (channel->phase == REMORA_SSH_SHELL_OPENING) {
        channel->channel = libssh2_channel_open_session(context->session);
        if (channel->channel == NULL) {
            int result = libssh2_session_last_errno(context->session);
            return remora_ssh_map_result(context, result, "unable to open SSH channel", out_error);
        }
        channel->phase = REMORA_SSH_SHELL_REQUESTING_PTY;
    }

    if (channel->phase == REMORA_SSH_SHELL_REQUESTING_PTY) {
        int result = libssh2_channel_request_pty_ex(
            channel->channel,
            channel->terminal_type,
            (unsigned int)strlen(channel->terminal_type),
            NULL,
            0,
            (int)channel->columns,
            (int)channel->rows,
            0,
            0
        );
        if (result != LIBSSH2_ERROR_NONE) {
            return remora_ssh_map_result(context, result, "unable to request remote PTY", out_error);
        }
        channel->phase = REMORA_SSH_SHELL_STARTING;
    }

    if (channel->phase == REMORA_SSH_SHELL_STARTING) {
        int result = libssh2_channel_shell(channel->channel);
        if (result != LIBSSH2_ERROR_NONE) {
            return remora_ssh_map_result(context, result, "unable to start remote shell", out_error);
        }
        channel->phase = REMORA_SSH_SHELL_READY;
    }

    if (channel->phase != REMORA_SSH_SHELL_READY) {
        return remora_ssh_invalid_channel(out_error);
    }
    remora_ssh_error_reset(out_error);
    return REMORA_SSH_ERROR_NONE;
}

remora_ssh_error_code remora_ssh_channel_read(
    remora_ssh_channel *channel,
    remora_ssh_channel_stream stream,
    uint8_t *buffer,
    size_t buffer_capacity,
    size_t *out_length,
    remora_ssh_error *out_error
) {
    if (out_length != NULL) {
        *out_length = 0;
    }
    if (!remora_ssh_channel_valid(channel)) {
        return remora_ssh_invalid_channel(out_error);
    }
    if (channel->phase != REMORA_SSH_SHELL_READY || buffer == NULL ||
        buffer_capacity == 0 || out_length == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "channel read arguments are invalid"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }
    int stream_identifier = stream == REMORA_SSH_CHANNEL_STANDARD_ERROR
        ? SSH_EXTENDED_DATA_STDERR
        : 0;
    ssize_t result = libssh2_channel_read_ex(
        channel->channel,
        stream_identifier,
        (char *)buffer,
        buffer_capacity
    );
    if (result >= 0) {
        *out_length = (size_t)result;
        remora_ssh_error_reset(out_error);
        return REMORA_SSH_ERROR_NONE;
    }
    return remora_ssh_map_result(
        channel->context,
        (int)result,
        "unable to read SSH channel",
        out_error
    );
}

remora_ssh_error_code remora_ssh_channel_write(
    remora_ssh_channel *channel,
    const uint8_t *bytes,
    size_t length,
    size_t *out_written,
    remora_ssh_error *out_error
) {
    if (out_written != NULL) {
        *out_written = 0;
    }
    if (!remora_ssh_channel_valid(channel)) {
        return remora_ssh_invalid_channel(out_error);
    }
    if (channel->phase != REMORA_SSH_SHELL_READY ||
        (bytes == NULL && length > 0) || out_written == NULL) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "channel write arguments are invalid"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }
    if (length == 0) {
        remora_ssh_error_reset(out_error);
        return REMORA_SSH_ERROR_NONE;
    }
    ssize_t result = libssh2_channel_write_ex(
        channel->channel,
        0,
        (const char *)bytes,
        length
    );
    if (result >= 0) {
        *out_written = (size_t)result;
        remora_ssh_error_reset(out_error);
        return REMORA_SSH_ERROR_NONE;
    }
    return remora_ssh_map_result(
        channel->context,
        (int)result,
        "unable to write SSH channel",
        out_error
    );
}

remora_ssh_error_code remora_ssh_channel_resize(
    remora_ssh_channel *channel,
    uint32_t columns,
    uint32_t rows,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_channel_valid(channel)) {
        return remora_ssh_invalid_channel(out_error);
    }
    if (channel->phase != REMORA_SSH_SHELL_READY || columns == 0 || rows == 0) {
        remora_ssh_error_set(
            out_error,
            REMORA_SSH_ERROR_INVALID_ARGUMENT,
            0,
            "channel resize arguments are invalid"
        );
        return REMORA_SSH_ERROR_INVALID_ARGUMENT;
    }
    int result = libssh2_channel_request_pty_size_ex(
        channel->channel,
        (int)columns,
        (int)rows,
        0,
        0
    );
    if (result == LIBSSH2_ERROR_NONE) {
        channel->columns = columns;
        channel->rows = rows;
    }
    return remora_ssh_map_result(channel->context, result, "unable to resize remote PTY", out_error);
}

bool remora_ssh_channel_is_eof(const remora_ssh_channel *channel) {
    return remora_ssh_channel_valid(channel) && channel->channel != NULL &&
        libssh2_channel_eof(channel->channel) != 0;
}

int32_t remora_ssh_channel_exit_status(const remora_ssh_channel *channel) {
    if (!remora_ssh_channel_valid(channel)) {
        return -1;
    }
    if (channel->channel != NULL) {
        return (int32_t)libssh2_channel_get_exit_status(channel->channel);
    }
    return channel->exit_status;
}

remora_ssh_error_code remora_ssh_channel_close(
    remora_ssh_channel *channel,
    remora_ssh_error *out_error
) {
    if (!remora_ssh_channel_valid(channel)) {
        return remora_ssh_invalid_channel(out_error);
    }
    remora_ssh_context *context = channel->context;
    if (channel->phase == REMORA_SSH_SHELL_CLOSED) {
        remora_ssh_error_reset(out_error);
        return REMORA_SSH_ERROR_NONE;
    }
    if (channel->channel == NULL) {
        channel->phase = REMORA_SSH_SHELL_CLOSED;
        remora_ssh_error_reset(out_error);
        return REMORA_SSH_ERROR_NONE;
    }

    if (channel->phase < REMORA_SSH_SHELL_SENDING_EOF) {
        channel->phase = REMORA_SSH_SHELL_SENDING_EOF;
    }
    if (channel->phase == REMORA_SSH_SHELL_SENDING_EOF) {
        int result = libssh2_channel_send_eof(channel->channel);
        if (result != LIBSSH2_ERROR_NONE) {
            return remora_ssh_map_result(context, result, "unable to send channel EOF", out_error);
        }
        channel->phase = REMORA_SSH_SHELL_CLOSING;
    }
    if (channel->phase == REMORA_SSH_SHELL_CLOSING) {
        int result = libssh2_channel_close(channel->channel);
        if (result != LIBSSH2_ERROR_NONE) {
            return remora_ssh_map_result(context, result, "unable to close SSH channel", out_error);
        }
        channel->phase = REMORA_SSH_SHELL_WAITING_CLOSED;
    }
    if (channel->phase == REMORA_SSH_SHELL_WAITING_CLOSED) {
        int result = libssh2_channel_wait_closed(channel->channel);
        if (result != LIBSSH2_ERROR_NONE) {
            return remora_ssh_map_result(context, result, "remote SSH channel did not close", out_error);
        }
        channel->exit_status = (int32_t)libssh2_channel_get_exit_status(channel->channel);
        (void)libssh2_channel_free(channel->channel);
        channel->channel = NULL;
        channel->phase = REMORA_SSH_SHELL_CLOSED;
    }
    remora_ssh_error_reset(out_error);
    return REMORA_SSH_ERROR_NONE;
}

void remora_ssh_channel_destroy(remora_ssh_channel **channel_pointer) {
    if (channel_pointer == NULL || *channel_pointer == NULL) {
        return;
    }
    remora_ssh_channel *channel = *channel_pointer;
    if (channel->magic == REMORA_SSH_CHANNEL_MAGIC) {
        remora_ssh_context *context = channel->context;
        if (channel->channel != NULL && context != NULL &&
            context->magic == REMORA_SSH_CONTEXT_MAGIC && context->session != NULL) {
            (void)libssh2_channel_free(channel->channel);
            channel->channel = NULL;
        }
        if (context != NULL && context->magic == REMORA_SSH_CONTEXT_MAGIC &&
            context->channel_count > 0) {
            context->channel_count -= 1;
            if (context->destroy_requested && context->channel_count == 0) {
                remora_ssh_context_finalize(context);
            }
        }
        channel->context = NULL;
        channel->magic = 0;
    }
    free(channel);
    *channel_pointer = NULL;
}

bool remora_ssh_channel_is_valid(const remora_ssh_channel *channel) {
    return remora_ssh_channel_valid(channel);
}
