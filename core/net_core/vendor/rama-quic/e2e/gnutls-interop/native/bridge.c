/* Test-only bridge to GnuTLS's public TLS and crypto APIs. No QUIC engine lives
 * here. */
#include <errno.h>
#include <gnutls/crypto.h>
#include <gnutls/gnutls.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if GNUTLS_VERSION_NUMBER < 0x030702
#error "GnuTLS 3.7.2 or newer is required"
#endif

#define BRIDGE_LIMIT (1u << 20)
struct event_info {
    int kind, level;
    size_t read_size, write_size, size;
};

struct event {
    struct event_info info;
    struct event *next;
    unsigned char data[];
};

struct session {
    gnutls_session_t tls;
    gnutls_certificate_credentials_t credentials;
    unsigned char *local_params, *peer_params;
    char *verification_name;
    size_t local_size, peer_size, queued;
    struct event *head, *tail;
    int complete;
};

int qg_init(void) {
    return gnutls_global_init();
}

const char *qg_version(void) {
    return gnutls_check_version(NULL);
}

const char *qg_error(int code) {
    return gnutls_strerror(code);
}

static int queue_event(struct session *s, int kind, int level, const void *first, size_t first_size,
                       const void *second, size_t second_size) {
    if (first_size > BRIDGE_LIMIT || second_size > BRIDGE_LIMIT - first_size ||
        s->queued > BRIDGE_LIMIT - first_size - second_size)
        return GNUTLS_E_MEMORY_ERROR;
    size_t size = first_size + second_size;
    struct event *e = calloc(1, sizeof(*e) + size);
    if (!e)
        return GNUTLS_E_MEMORY_ERROR;
    e->info.kind = kind;
    e->info.level = level;
    e->info.size = size;
    if (kind == 1) {
        e->info.read_size = first_size;
        e->info.write_size = second_size;
    }
    if (first_size)
        memcpy(e->data, first, first_size);
    if (second_size)
        memcpy(e->data + first_size, second, second_size);
    if (s->tail)
        s->tail->next = e;
    else
        s->head = e;
    s->tail = e;
    s->queued += size;
    return 0;
}

static int handshake_output(gnutls_session_t tls, gnutls_record_encryption_level_t level,
                            gnutls_handshake_description_t type, const void *data, size_t size) {
    if (type == GNUTLS_HANDSHAKE_CHANGE_CIPHER_SPEC)
        return 0;
    return queue_event(gnutls_session_get_ptr(tls), 0, level, data, size, NULL, 0);
}

static int secrets(gnutls_session_t tls, gnutls_record_encryption_level_t level, const void *read,
                   const void *write, size_t size) {
    if (size != 32 || gnutls_cipher_get(tls) != GNUTLS_CIPHER_AES_128_GCM)
        return GNUTLS_E_UNWANTED_ALGORITHM;
    return queue_event(gnutls_session_get_ptr(tls), 1, level, read, read ? size : 0, write,
                       write ? size : 0);
}

static int receive_params(gnutls_session_t tls, const unsigned char *data, size_t size) {
    struct session *s = gnutls_session_get_ptr(tls);
    if (size > BRIDGE_LIMIT || s->peer_params)
        return GNUTLS_E_RECEIVED_ILLEGAL_PARAMETER;
    s->peer_params = malloc(size ? size : 1);
    if (!s->peer_params)
        return GNUTLS_E_MEMORY_ERROR;
    if (size)
        memcpy(s->peer_params, data, size);
    s->peer_size = size;
    return 0;
}

static int send_params(gnutls_session_t tls, gnutls_buffer_t buffer) {
    struct session *s = gnutls_session_get_ptr(tls);
    return gnutls_buffer_append_data(buffer, s->local_params, s->local_size);
}

static ssize_t no_records(gnutls_transport_ptr_t ptr, void *data, size_t size) {
    (void)ptr;
    (void)data;
    (void)size;
    errno = EAGAIN;
    return -1;
}

void qg_free(struct session *s) {
    if (!s)
        return;
    if (s->tls)
        gnutls_deinit(s->tls);
    if (s->credentials)
        gnutls_certificate_free_credentials(s->credentials);
    while (s->head) {
        struct event *e = s->head;
        s->head = e->next;
        gnutls_memset(e->data, 0, e->info.size);
        free(e);
    }
    free(s->local_params);
    free(s->peer_params);
    free(s->verification_name);
    free(s);
}

int qg_new(struct session **output, int server, const char *ca, const char *certificate,
           const char *key, const char *name, const unsigned char *alpn, size_t alpn_size,
           const unsigned char *params, size_t params_size) {
    *output = NULL;
    if (params_size > BRIDGE_LIMIT || alpn_size > 255 || !alpn_size)
        return GNUTLS_E_INVALID_REQUEST;
    struct session *s = calloc(1, sizeof(*s));
    if (!s)
        return GNUTLS_E_MEMORY_ERROR;
    int result = gnutls_certificate_allocate_credentials(&s->credentials);
    if (result < 0)
        goto fail;
    if (server) {
        result = gnutls_certificate_set_x509_key_file(s->credentials, certificate, key,
                                                      GNUTLS_X509_FMT_PEM);
    } else {
        result = gnutls_certificate_set_x509_trust_file(s->credentials, ca, GNUTLS_X509_FMT_PEM);
        if (result == 0)
            result = GNUTLS_E_NO_CERTIFICATE_FOUND;
    }
    if (result < 0)
        goto fail;
    result = gnutls_init(&s->tls, (server ? GNUTLS_SERVER : GNUTLS_CLIENT) | GNUTLS_NONBLOCK |
                                      GNUTLS_NO_END_OF_EARLY_DATA | GNUTLS_NO_AUTO_SEND_TICKET);
    if (result < 0)
        goto fail;
    gnutls_session_set_ptr(s->tls, s);
    result = gnutls_priority_set_direct(
        s->tls,
        "NORMAL:-VERS-ALL:+VERS-TLS1.3:-CIPHER-ALL:+AES-128-GCM:-GROUP-ALL:+"
        "GROUP-X25519:%DISABLE_TLS13_COMPAT_MODE",
        NULL);
    if (result < 0)
        goto fail;
    result = gnutls_credentials_set(s->tls, GNUTLS_CRD_CERTIFICATE, s->credentials);
    if (result < 0)
        goto fail;
    if (!server) {
        result = gnutls_server_name_set(s->tls, GNUTLS_NAME_DNS, name, strlen(name));
        if (result < 0)
            goto fail;
        /* GnuTLS retains the verification name until the session is deinitialized.
         */
        s->verification_name = malloc(strlen(name) + 1);
        if (!s->verification_name) {
            result = GNUTLS_E_MEMORY_ERROR;
            goto fail;
        }
        memcpy(s->verification_name, name, strlen(name) + 1);
        gnutls_session_set_verify_cert(s->tls, s->verification_name, 0);
    }
    gnutls_datum_t protocol = {(unsigned char *)alpn, (unsigned int)alpn_size};
    result = gnutls_alpn_set_protocols(s->tls, &protocol, 1, GNUTLS_ALPN_MANDATORY);
    if (result < 0)
        goto fail;
    s->local_params = malloc(params_size ? params_size : 1);
    if (!s->local_params) {
        result = GNUTLS_E_MEMORY_ERROR;
        goto fail;
    }
    if (params_size)
        memcpy(s->local_params, params, params_size);
    s->local_size = params_size;
    result = gnutls_session_ext_register(
        s->tls, "QUIC parameters", 57, GNUTLS_EXT_TLS, receive_params, send_params, NULL, NULL,
        NULL, GNUTLS_EXT_FLAG_TLS | GNUTLS_EXT_FLAG_CLIENT_HELLO | GNUTLS_EXT_FLAG_EE);
    if (result < 0)
        goto fail;
    gnutls_handshake_set_read_function(s->tls, handshake_output);
    gnutls_handshake_set_secret_function(s->tls, secrets);
    gnutls_transport_set_pull_function(s->tls, no_records);
    *output = s;
    return 0;
fail:
    qg_free(s);
    return result;
}

int qg_step(struct session *s, int level, const unsigned char *data, size_t size) {
    int result;
    if (size) {
        result = gnutls_handshake_write(s->tls, level, data, size);
        if (result < 0 && result != GNUTLS_E_AGAIN && result != GNUTLS_E_INTERRUPTED)
            return result;
    }
    if (s->complete)
        return 0;
    result = gnutls_handshake(s->tls);
    if (result == GNUTLS_E_AGAIN || result == GNUTLS_E_INTERRUPTED)
        return 1;
    if (result == 0) {
        if (gnutls_protocol_get_version(s->tls) != GNUTLS_TLS1_3)
            return GNUTLS_E_UNWANTED_ALGORITHM;
        s->complete = 1;
    }
    return result;
}

int qg_peek(struct session *s, struct event_info *info) {
    if (!s->head)
        return 0;
    *info = s->head->info;
    return 1;
}

int qg_take(struct session *s, unsigned char *data, size_t size) {
    if (!s->head || size != s->head->info.size)
        return GNUTLS_E_INVALID_REQUEST;
    struct event *e = s->head;
    if (size)
        memcpy(data, e->data, size);
    s->head = e->next;
    if (!s->head)
        s->tail = NULL;
    s->queued -= size;
    gnutls_memset(e->data, 0, size);
    free(e);
    return 0;
}

int qg_peer_params(struct session *s, const unsigned char **data, size_t *size) {
    *data = s->peer_params;
    *size = s->peer_size;
    return s->peer_params != NULL;
}

int qg_alpn(struct session *s, const unsigned char **data, size_t *size) {
    gnutls_datum_t selected;
    int result = gnutls_alpn_get_selected_protocol(s->tls, &selected);
    if (result < 0)
        return result;
    *data = selected.data;
    *size = selected.size;
    return 0;
}

int qg_peer_cert(struct session *s, unsigned index, const unsigned char **data, size_t *size) {
    unsigned count = 0;
    const gnutls_datum_t *certs = gnutls_certificate_get_peers(s->tls, &count);
    if (index >= count)
        return 0;
    *data = certs[index].data;
    *size = certs[index].size;
    return 1;
}

unsigned qg_verify_status(struct session *s) {
    return gnutls_session_get_verify_cert_status(s->tls);
}

int qg_alert(struct session *s, int error) {
    if (error == GNUTLS_E_FATAL_ALERT_RECEIVED)
        return gnutls_alert_get(s->tls);
    int level;
    return gnutls_error_to_alert(error, &level);
}

int qg_export(struct session *s, const unsigned char *label, size_t label_size,
              const unsigned char *context, size_t context_size, unsigned char *out, size_t size) {
    return gnutls_prf_rfc5705(s->tls, label_size, (const char *)label, context_size,
                              (const char *)context, size, (char *)out);
}

int qg_random(unsigned char *out, size_t size) {
    return gnutls_rnd(GNUTLS_RND_KEY, out, size);
}

int qg_extract(const unsigned char *salt, size_t salt_size, const unsigned char *key,
               size_t key_size, unsigned char *out) {
    if (salt_size > UINT_MAX || key_size > UINT_MAX)
        return GNUTLS_E_INVALID_REQUEST;
    gnutls_datum_t s = {(unsigned char *)salt, (unsigned)salt_size};
    gnutls_datum_t k = {(unsigned char *)key, (unsigned)key_size};
    return gnutls_hkdf_extract(GNUTLS_MAC_SHA256, &k, &s, out);
}

int qg_expand(const unsigned char *key, const unsigned char *info, size_t info_size,
              unsigned char *out, size_t size) {
    if (info_size > UINT_MAX)
        return GNUTLS_E_INVALID_REQUEST;
    gnutls_datum_t k = {(unsigned char *)key, 32};
    gnutls_datum_t i = {(unsigned char *)info, (unsigned)info_size};
    return gnutls_hkdf_expand(GNUTLS_MAC_SHA256, &k, &i, out, size);
}

int qg_aead(int decrypt, const unsigned char *key, const unsigned char *nonce,
            const unsigned char *aad, size_t aad_size, const unsigned char *input,
            size_t input_size, unsigned char *out, size_t *out_size) {
    gnutls_datum_t k = {(unsigned char *)key, 16};
    gnutls_aead_cipher_hd_t cipher;
    int result = gnutls_aead_cipher_init(&cipher, GNUTLS_CIPHER_AES_128_GCM, &k);
    if (result < 0)
        return result;
    if (decrypt)
        result = gnutls_aead_cipher_decrypt(cipher, nonce, 12, aad, aad_size, 16, input, input_size,
                                            out, out_size);
    else
        result = gnutls_aead_cipher_encrypt(cipher, nonce, 12, aad, aad_size, 16, input, input_size,
                                            out, out_size);
    gnutls_aead_cipher_deinit(cipher);
    return result;
}

int qg_mask(const unsigned char *key, const unsigned char *sample, unsigned char *out) {
    unsigned char zero_iv[16] = {0};
    gnutls_datum_t k = {(unsigned char *)key, 16}, iv = {zero_iv, 16};
    gnutls_cipher_hd_t cipher;
    int result = gnutls_cipher_init(&cipher, GNUTLS_CIPHER_AES_128_CBC, &k, &iv);
    if (result < 0)
        return result;
    /* One CBC block with a zero IV is the AES block operation required by RFC
     * 9001. */
    result = gnutls_cipher_encrypt2(cipher, sample, 16, out, 16);
    gnutls_cipher_deinit(cipher);
    return result;
}
