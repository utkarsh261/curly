#include "CurlyQuickJS.h"

#include "quickjs.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#define CQJS_MEMORY_LIMIT (32u * 1024u * 1024u)
#define CQJS_STACK_LIMIT (512u * 1024u)
#define CQJS_SOURCE_LIMIT (64u * 1024u)
#define CQJS_VALUE_LIMIT (64u * 1024u)
#define CQJS_JSON_BODY_LIMIT (8u * 1024u * 1024u)
#define CQJS_LOG_LIMIT 50u
#define CQJS_LOG_TEXT_LIMIT (2u * 1024u)
#define CQJS_DEADLINE_NS 1000000000ull
#define CQJS_INSPECT_DEPTH 3
#define CQJS_INSPECT_PROPERTIES 20u

typedef struct {
    char *name;
    size_t name_length;
    char *value;
    size_t value_length;
} CQJSHeader;

typedef struct {
    CQJSScope scope;
    bool belongs_to_current_request;
    char *name;
    size_t name_length;
    char *value;
    size_t value_length;
} CQJSVariable;

struct CQJSInput {
    int status_code;
    int64_t duration_ms;
    size_t size_bytes;
    CQJSHeader *headers;
    size_t header_count;
    CQJSVariable *variables;
    size_t variable_count;
    const uint8_t *body;
    size_t body_length;
};

struct CQJSCancellationToken {
    atomic_bool cancelled;
};

typedef struct {
    CQJSScope scope;
    char *name;
    uint8_t *value;
    size_t value_length;
} CQJSWrite;

typedef struct {
    CQJSLogLevel level;
    uint8_t *text;
    size_t text_length;
} CQJSLog;

struct CQJSResult {
    CQJSResultStatus status;
    char *message;
    int line;
    int column;
    int64_t duration_ms;
    CQJSWrite *writes;
    size_t write_count;
    CQJSLog *logs;
    size_t log_count;
    bool logs_truncated;
};

typedef struct {
    char bytes[CQJS_LOG_TEXT_LIMIT + 1];
    size_t length;
} CQJSBuffer;

typedef struct {
    const CQJSInput *input;
    CQJSCancellationToken *token;
    uint64_t deadline_ns;
    JSValue staged_global;
    JSValue staged_request;
    JSValue text_cache;
    JSValue json_cache;
    CQJSLog logs[CQJS_LOG_LIMIT];
    size_t log_count;
    bool logs_truncated;
} CQJSRunState;

static atomic_int cqjs_live_runtime_count = 0;

static uint64_t cqjs_now_ns(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000000000ull + (uint64_t)value.tv_nsec;
}

static char *cqjs_copy_bytes(const void *bytes, size_t length) {
    char *copy = malloc(length + 1);
    if (!copy) return NULL;
    if (length > 0) memcpy(copy, bytes, length);
    copy[length] = '\0';
    return copy;
}

static bool cqjs_is_cancelled(const CQJSRunState *state) {
    return state->token && atomic_load_explicit(&state->token->cancelled, memory_order_relaxed);
}

static bool cqjs_is_timed_out(const CQJSRunState *state) {
    return cqjs_now_ns() >= state->deadline_ns;
}

static int cqjs_interrupt_handler(JSRuntime *runtime, void *opaque) {
    (void)runtime;
    CQJSRunState *state = opaque;
    return cqjs_is_cancelled(state) || cqjs_is_timed_out(state);
}

static bool cqjs_valid_utf8(const CQJSRunState *state, const uint8_t *bytes, size_t length) {
    size_t index = 0;
    size_t next_interrupt_check = 0;
    while (index < length) {
        if (index >= next_interrupt_check) {
            if (cqjs_is_cancelled(state) || cqjs_is_timed_out(state)) return false;
            next_interrupt_check = index + 4096u;
        }
        uint8_t first = bytes[index++];
        if (first <= 0x7f) continue;

        uint32_t scalar;
        size_t remaining;
        if (first >= 0xc2 && first <= 0xdf) {
            scalar = first & 0x1f;
            remaining = 1;
        } else if (first >= 0xe0 && first <= 0xef) {
            scalar = first & 0x0f;
            remaining = 2;
        } else if (first >= 0xf0 && first <= 0xf4) {
            scalar = first & 0x07;
            remaining = 3;
        } else {
            return false;
        }

        if (index + remaining > length) return false;
        for (size_t offset = 0; offset < remaining; offset++) {
            uint8_t next = bytes[index++];
            if ((next & 0xc0) != 0x80) return false;
            scalar = (scalar << 6) | (next & 0x3f);
        }

        if ((remaining == 1 && scalar < 0x80) ||
            (remaining == 2 && scalar < 0x800) ||
            (remaining == 3 && scalar < 0x10000) ||
            scalar > 0x10ffff ||
            (scalar >= 0xd800 && scalar <= 0xdfff)) {
            return false;
        }
    }
    return true;
}

CQJSInput *CQJSInputCreate(void) {
    return calloc(1, sizeof(CQJSInput));
}

void CQJSInputDestroy(CQJSInput *input) {
    if (!input) return;
    for (size_t index = 0; index < input->header_count; index++) {
        free(input->headers[index].name);
        free(input->headers[index].value);
    }
    for (size_t index = 0; index < input->variable_count; index++) {
        free(input->variables[index].name);
        free(input->variables[index].value);
    }
    free(input->headers);
    free(input->variables);
    free(input);
}

void CQJSInputSetResponse(CQJSInput *input, int status_code, int64_t duration_ms, size_t size_bytes) {
    if (!input) return;
    input->status_code = status_code;
    input->duration_ms = duration_ms;
    input->size_bytes = size_bytes;
}

bool CQJSInputAddHeader(
    CQJSInput *input,
    const char *name,
    size_t name_length,
    const char *value,
    size_t value_length
) {
    if (!input || !name || !value) return false;
    CQJSHeader header = {
        .name = cqjs_copy_bytes(name, name_length),
        .name_length = name_length,
        .value = cqjs_copy_bytes(value, value_length),
        .value_length = value_length,
    };
    if (!header.name || !header.value) {
        free(header.name);
        free(header.value);
        return false;
    }
    CQJSHeader *expanded = realloc(input->headers, sizeof(CQJSHeader) * (input->header_count + 1));
    if (!expanded) {
        free(header.name);
        free(header.value);
        return false;
    }
    input->headers = expanded;
    input->headers[input->header_count++] = header;
    return true;
}

bool CQJSInputAddVariable(
    CQJSInput *input,
    CQJSScope scope,
    bool belongs_to_current_request,
    const char *name,
    size_t name_length,
    const char *value,
    size_t value_length
) {
    if (!input || !name || !value) return false;
    CQJSVariable variable = {
        .scope = scope,
        .belongs_to_current_request = belongs_to_current_request,
        .name = cqjs_copy_bytes(name, name_length),
        .name_length = name_length,
        .value = cqjs_copy_bytes(value, value_length),
        .value_length = value_length,
    };
    if (!variable.name || !variable.value) {
        free(variable.name);
        free(variable.value);
        return false;
    }
    CQJSVariable *expanded = realloc(input->variables, sizeof(CQJSVariable) * (input->variable_count + 1));
    if (!expanded) {
        free(variable.name);
        free(variable.value);
        return false;
    }
    input->variables = expanded;
    input->variables[input->variable_count++] = variable;
    return true;
}

void CQJSInputSetBorrowedBody(CQJSInput *input, const uint8_t *bytes, size_t length) {
    if (!input) return;
    input->body = bytes;
    input->body_length = length;
}

CQJSCancellationToken *CQJSCancellationTokenCreate(void) {
    CQJSCancellationToken *token = malloc(sizeof(CQJSCancellationToken));
    if (token) atomic_init(&token->cancelled, false);
    return token;
}

void CQJSCancellationTokenCancel(CQJSCancellationToken *token) {
    if (token) atomic_store_explicit(&token->cancelled, true, memory_order_relaxed);
}

void CQJSCancellationTokenDestroy(CQJSCancellationToken *token) {
    free(token);
}

static CQJSResult *cqjs_result_create(CQJSResultStatus status) {
    CQJSResult *result = calloc(1, sizeof(CQJSResult));
    if (result) result->status = status;
    return result;
}

static void cqjs_result_set_message(CQJSResult *result, const char *message) {
    if (!result) return;
    free(result->message);
    result->message = message ? cqjs_copy_bytes(message, strlen(message)) : NULL;
}

static void cqjs_result_clear_writes(CQJSResult *result) {
    if (!result) return;
    for (size_t index = 0; index < result->write_count; index++) {
        free(result->writes[index].name);
        free(result->writes[index].value);
    }
    free(result->writes);
    result->writes = NULL;
    result->write_count = 0;
}

void CQJSResultDestroy(CQJSResult *result) {
    if (!result) return;
    free(result->message);
    for (size_t index = 0; index < result->write_count; index++) {
        free(result->writes[index].name);
        free(result->writes[index].value);
    }
    for (size_t index = 0; index < result->log_count; index++) {
        free(result->logs[index].text);
    }
    free(result->writes);
    free(result->logs);
    free(result);
}

CQJSResultStatus CQJSResultGetStatus(const CQJSResult *result) { return result ? result->status : CQJS_RESULT_FAILED; }
const char *CQJSResultGetMessage(const CQJSResult *result) { return result ? result->message : NULL; }
int CQJSResultGetLine(const CQJSResult *result) { return result ? result->line : 0; }
int CQJSResultGetColumn(const CQJSResult *result) { return result ? result->column : 0; }
int64_t CQJSResultGetDurationMilliseconds(const CQJSResult *result) { return result ? result->duration_ms : 0; }
size_t CQJSResultGetWriteCount(const CQJSResult *result) { return result ? result->write_count : 0; }
CQJSScope CQJSResultGetWriteScope(const CQJSResult *result, size_t index) { return result && index < result->write_count ? result->writes[index].scope : CQJS_SCOPE_GLOBAL; }
const char *CQJSResultGetWriteName(const CQJSResult *result, size_t index) { return result && index < result->write_count ? result->writes[index].name : NULL; }
const uint8_t *CQJSResultGetWriteValue(const CQJSResult *result, size_t index) { return result && index < result->write_count ? result->writes[index].value : NULL; }
size_t CQJSResultGetWriteValueLength(const CQJSResult *result, size_t index) { return result && index < result->write_count ? result->writes[index].value_length : 0; }
size_t CQJSResultGetLogCount(const CQJSResult *result) { return result ? result->log_count : 0; }
CQJSLogLevel CQJSResultGetLogLevel(const CQJSResult *result, size_t index) { return result && index < result->log_count ? result->logs[index].level : CQJS_LOG_INFO; }
const uint8_t *CQJSResultGetLogText(const CQJSResult *result, size_t index) { return result && index < result->log_count ? result->logs[index].text : NULL; }
size_t CQJSResultGetLogTextLength(const CQJSResult *result, size_t index) { return result && index < result->log_count ? result->logs[index].text_length : 0; }
bool CQJSResultLogsWereTruncated(const CQJSResult *result) { return result && result->logs_truncated; }
int CQJSLiveRuntimeCount(void) { return atomic_load_explicit(&cqjs_live_runtime_count, memory_order_relaxed); }

static void cqjs_buffer_append(CQJSBuffer *buffer, const char *bytes, size_t length) {
    if (buffer->length >= CQJS_LOG_TEXT_LIMIT || length == 0) return;
    size_t available = CQJS_LOG_TEXT_LIMIT - buffer->length;
    size_t copied = length < available ? length : available;
    memcpy(buffer->bytes + buffer->length, bytes, copied);
    buffer->length += copied;
    buffer->bytes[buffer->length] = '\0';
}

static void cqjs_buffer_append_cstring(CQJSBuffer *buffer, const char *value) {
    cqjs_buffer_append(buffer, value, strlen(value));
}

static void cqjs_buffer_append_escaped(CQJSBuffer *buffer, const char *value, size_t length) {
    cqjs_buffer_append_cstring(buffer, "\"");
    for (size_t index = 0; index < length && buffer->length < CQJS_LOG_TEXT_LIMIT; index++) {
        unsigned char byte = (unsigned char)value[index];
        switch (byte) {
        case '\\': cqjs_buffer_append_cstring(buffer, "\\\\"); break;
        case '"': cqjs_buffer_append_cstring(buffer, "\\\""); break;
        case '\n': cqjs_buffer_append_cstring(buffer, "\\n"); break;
        case '\r': cqjs_buffer_append_cstring(buffer, "\\r"); break;
        case '\t': cqjs_buffer_append_cstring(buffer, "\\t"); break;
        default:
            if (byte < 0x20) {
                char escaped[7];
                snprintf(escaped, sizeof(escaped), "\\u%04x", byte);
                cqjs_buffer_append_cstring(buffer, escaped);
            } else {
                cqjs_buffer_append(buffer, (const char *)&value[index], 1);
            }
        }
    }
    cqjs_buffer_append_cstring(buffer, "\"");
}

static bool cqjs_seen_object(JSValueConst value, void **seen, size_t seen_count) {
    void *pointer = JS_VALUE_GET_PTR(value);
    for (size_t index = 0; index < seen_count; index++) {
        if (seen[index] == pointer) return true;
    }
    return false;
}

static void cqjs_inspect_value(
    JSContext *context,
    JSValueConst value,
    CQJSBuffer *buffer,
    int depth,
    void **seen,
    size_t seen_count
) {
    if (JS_IsUndefined(value)) { cqjs_buffer_append_cstring(buffer, "undefined"); return; }
    if (JS_IsNull(value)) { cqjs_buffer_append_cstring(buffer, "null"); return; }
    if (JS_IsBool(value)) { cqjs_buffer_append_cstring(buffer, JS_ToBool(context, value) ? "true" : "false"); return; }
    if (JS_IsString(value)) {
        size_t length = 0;
        const char *string = JS_ToCStringLen(context, &length, value);
        if (string) {
            cqjs_buffer_append_escaped(buffer, string, length);
            JS_FreeCString(context, string);
        } else {
            cqjs_buffer_append_cstring(buffer, "[String]");
        }
        return;
    }
    if (JS_IsNumber(value) || JS_IsBigInt(value) || JS_IsSymbol(value)) {
        size_t length = 0;
        const char *string = JS_ToCStringLen(context, &length, value);
        if (string) {
            cqjs_buffer_append(buffer, string, length);
            JS_FreeCString(context, string);
        } else {
            cqjs_buffer_append_cstring(buffer, "[Value]");
        }
        return;
    }
    if (JS_IsFunction(context, value)) { cqjs_buffer_append_cstring(buffer, "[Function]"); return; }
    if (!JS_IsObject(value)) { cqjs_buffer_append_cstring(buffer, "[Value]"); return; }
    if (cqjs_seen_object(value, seen, seen_count)) { cqjs_buffer_append_cstring(buffer, "[Circular]"); return; }
    if (depth >= CQJS_INSPECT_DEPTH) { cqjs_buffer_append_cstring(buffer, JS_IsArray(value) ? "[…]" : "{…}"); return; }

    void *next_seen[CQJS_INSPECT_DEPTH + 1];
    size_t next_count = seen_count;
    for (size_t index = 0; index < seen_count; index++) next_seen[index] = seen[index];
    next_seen[next_count++] = JS_VALUE_GET_PTR(value);

    JSPropertyEnum *properties = NULL;
    uint32_t property_count = 0;
    if (JS_GetOwnPropertyNames(context, &properties, &property_count, value, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) {
        cqjs_buffer_append_cstring(buffer, "[Object]");
        return;
    }

    bool array = JS_IsArray(value);
    cqjs_buffer_append_cstring(buffer, array ? "[" : "{");
    uint32_t displayed = property_count < CQJS_INSPECT_PROPERTIES ? property_count : CQJS_INSPECT_PROPERTIES;
    for (uint32_t index = 0; index < displayed; index++) {
        if (index > 0) cqjs_buffer_append_cstring(buffer, ", ");
        size_t name_length = 0;
        const char *name = JS_AtomToCStringLen(context, &name_length, properties[index].atom);
        if (!array && name) {
            cqjs_buffer_append_escaped(buffer, name, name_length);
            cqjs_buffer_append_cstring(buffer, ": ");
        }

        JSPropertyDescriptor descriptor = {0};
        int found = JS_GetOwnProperty(context, &descriptor, value, properties[index].atom);
        if (found > 0) {
            if (descriptor.flags & JS_PROP_GETSET) {
                if (!JS_IsUndefined(descriptor.getter) && !JS_IsUndefined(descriptor.setter)) {
                    cqjs_buffer_append_cstring(buffer, "[Getter/Setter]");
                } else if (!JS_IsUndefined(descriptor.getter)) {
                    cqjs_buffer_append_cstring(buffer, "[Getter]");
                } else {
                    cqjs_buffer_append_cstring(buffer, "[Setter]");
                }
            } else {
                cqjs_inspect_value(context, descriptor.value, buffer, depth + 1, next_seen, next_count);
            }
            JS_FreeValue(context, descriptor.value);
            JS_FreeValue(context, descriptor.getter);
            JS_FreeValue(context, descriptor.setter);
        } else {
            cqjs_buffer_append_cstring(buffer, "[Unavailable]");
        }
        if (name) JS_FreeCString(context, name);
    }
    if (property_count > displayed) cqjs_buffer_append_cstring(buffer, displayed ? ", …" : "…");
    cqjs_buffer_append_cstring(buffer, array ? "]" : "}");
    JS_FreePropertyEnum(context, properties, property_count);
}

static void cqjs_add_log(CQJSRunState *state, CQJSLogLevel level, const uint8_t *text, size_t length) {
    if (state->log_count >= CQJS_LOG_LIMIT) {
        state->logs_truncated = true;
        return;
    }
    size_t copied = length < CQJS_LOG_TEXT_LIMIT ? length : CQJS_LOG_TEXT_LIMIT;
    uint8_t *stored = malloc(copied + 1);
    if (!stored) return;
    memcpy(stored, text, copied);
    stored[copied] = 0;
    state->logs[state->log_count++] = (CQJSLog){ .level = level, .text = stored, .text_length = copied };
    if (length > copied) state->logs_truncated = true;
}

static JSValue cqjs_console(JSContext *context, JSValueConst this_value, int argument_count, JSValueConst *arguments, int magic) {
    (void)this_value;
    CQJSRunState *state = JS_GetContextOpaque(context);
    if (cqjs_is_cancelled(state) || cqjs_is_timed_out(state)) return JS_ThrowInternalError(context, "interrupted");

    CQJSBuffer buffer = {0};
    for (int index = 0; index < argument_count; index++) {
        if (index > 0) cqjs_buffer_append_cstring(&buffer, " ");
        if (JS_IsString(arguments[index])) {
            size_t length = 0;
            const char *string = JS_ToCStringLen(context, &length, arguments[index]);
            if (string) {
                cqjs_buffer_append(&buffer, string, length);
                JS_FreeCString(context, string);
            } else {
                cqjs_buffer_append_cstring(&buffer, "[String]");
            }
        } else {
            void *seen[CQJS_INSPECT_DEPTH + 1] = {0};
            cqjs_inspect_value(context, arguments[index], &buffer, 0, seen, 0);
        }
    }
    cqjs_add_log(state, (CQJSLogLevel)magic, (const uint8_t *)buffer.bytes, buffer.length);
    return JS_UNDEFINED;
}

static bool cqjs_valid_variable_name(const char *name, size_t length) {
    if (length == 0) return false;
    unsigned char first = (unsigned char)name[0];
    if (!((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z') || first == '_')) return false;
    for (size_t index = 1; index < length; index++) {
        unsigned char byte = (unsigned char)name[index];
        if (!((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
              (byte >= '0' && byte <= '9') || byte == '_' || byte == '-')) return false;
    }
    return true;
}

static const CQJSVariable *cqjs_find_input_variable(const CQJSRunState *state, const char *name, size_t length) {
    for (size_t index = 0; index < state->input->variable_count; index++) {
        const CQJSVariable *variable = &state->input->variables[index];
        if (variable->name_length == length && memcmp(variable->name, name, length) == 0) return variable;
    }
    return NULL;
}

static JSValue cqjs_staged_value(JSContext *context, JSValueConst staged, JSAtom atom, bool *found) {
    int has_property = JS_HasProperty(context, staged, atom);
    if (has_property < 0) {
        *found = false;
        return JS_EXCEPTION;
    }
    *found = has_property != 0;
    return *found ? JS_GetProperty(context, staged, atom) : JS_UNDEFINED;
}

static JSValue cqjs_variable_get(JSContext *context, JSValueConst this_value, int argument_count, JSValueConst *arguments, int magic) {
    (void)this_value;
    if (argument_count < 1 || !JS_IsString(arguments[0])) return JS_ThrowTypeError(context, "Variable name must be a string.");
    CQJSRunState *state = JS_GetContextOpaque(context);
    size_t name_length = 0;
    const char *name = JS_ToCStringLen(context, &name_length, arguments[0]);
    if (!name) return JS_EXCEPTION;
    if (!cqjs_valid_variable_name(name, name_length)) {
        JS_FreeCString(context, name);
        return JS_ThrowTypeError(context, "Invalid variable name.");
    }

    JSAtom atom = JS_NewAtomLen(context, name, name_length);
    bool found = false;
    JSValue value = JS_UNDEFINED;
    if (magic == 0 || magic == CQJS_SCOPE_GLOBAL + 1) value = cqjs_staged_value(context, state->staged_global, atom, &found);
    if (!found && !JS_IsException(value) && (magic == 0 || magic == CQJS_SCOPE_REQUEST + 1)) {
        JS_FreeValue(context, value);
        value = cqjs_staged_value(context, state->staged_request, atom, &found);
    }
    JS_FreeAtom(context, atom);
    if (JS_IsException(value)) {
        JS_FreeCString(context, name);
        return value;
    }
    if (found) {
        JS_FreeCString(context, name);
        return value;
    }
    JS_FreeValue(context, value);

    const CQJSVariable *variable = cqjs_find_input_variable(state, name, name_length);
    JS_FreeCString(context, name);
    if (!variable) return JS_NULL;
    if (magic == CQJS_SCOPE_GLOBAL + 1 && variable->scope != CQJS_SCOPE_GLOBAL) return JS_NULL;
    if (magic == CQJS_SCOPE_REQUEST + 1 && (variable->scope != CQJS_SCOPE_REQUEST || !variable->belongs_to_current_request)) return JS_NULL;
    if (magic == 0 && variable->scope == CQJS_SCOPE_REQUEST && !variable->belongs_to_current_request) return JS_NULL;
    return JS_NewStringLen(context, variable->value, variable->value_length);
}

static JSValue cqjs_variable_set(JSContext *context, JSValueConst this_value, int argument_count, JSValueConst *arguments, int magic) {
    (void)this_value;
    CQJSScope scope = (CQJSScope)magic;
    if (argument_count < 2) return JS_ThrowTypeError(context, "Expected set(name, value).");
    if (!JS_IsString(arguments[0])) return JS_ThrowTypeError(context, "Variable name must be a string.");
    if (!JS_IsString(arguments[1]) && !JS_IsNumber(arguments[1]) && !JS_IsBool(arguments[1])) {
        return JS_ThrowTypeError(context, "Variable value must be a string, number, or boolean.");
    }
    CQJSRunState *state = JS_GetContextOpaque(context);

    size_t name_length = 0;
    const char *name = JS_ToCStringLen(context, &name_length, arguments[0]);
    if (!name) return JS_EXCEPTION;
    if (!cqjs_valid_variable_name(name, name_length)) {
        JS_FreeCString(context, name);
        return JS_ThrowTypeError(context, "Invalid variable name.");
    }

    const CQJSVariable *existing = cqjs_find_input_variable(state, name, name_length);
    if (existing && (existing->scope != scope || (scope == CQJS_SCOPE_REQUEST && !existing->belongs_to_current_request))) {
        JS_FreeCString(context, name);
        return JS_ThrowTypeError(context, "Variable already exists in another scope.");
    }

    JSAtom atom = JS_NewAtomLen(context, name, name_length);
    if (atom == JS_ATOM_NULL) {
        JS_FreeCString(context, name);
        return JS_EXCEPTION;
    }
    JSValueConst other_staged = scope == CQJS_SCOPE_GLOBAL ? state->staged_request : state->staged_global;
    int staged_in_other_scope = JS_HasProperty(context, other_staged, atom);
    if (staged_in_other_scope < 0) {
        JS_FreeAtom(context, atom);
        JS_FreeCString(context, name);
        return JS_EXCEPTION;
    }
    if (staged_in_other_scope) {
        JS_FreeAtom(context, atom);
        JS_FreeCString(context, name);
        return JS_ThrowTypeError(context, "Variable already exists in another scope.");
    }

    size_t value_length = 0;
    const char *value = JS_ToCStringLen(context, &value_length, arguments[1]);
    if (!value) {
        JS_FreeAtom(context, atom);
        JS_FreeCString(context, name);
        return JS_EXCEPTION;
    }
    if (value_length > CQJS_VALUE_LIMIT) {
        JS_FreeAtom(context, atom);
        JS_FreeCString(context, value);
        JS_FreeCString(context, name);
        return JS_ThrowRangeError(context, "Variable value exceeds 64 KiB.");
    }

    JSValue stored_value = JS_NewStringLen(context, value, value_length);
    if (JS_IsException(stored_value)) {
        JS_FreeAtom(context, atom);
        JS_FreeCString(context, value);
        JS_FreeCString(context, name);
        return JS_EXCEPTION;
    }
    JSValue staged = scope == CQJS_SCOPE_GLOBAL ? state->staged_global : state->staged_request;
    int set_result = JS_SetProperty(context, staged, atom, stored_value);
    JS_FreeAtom(context, atom);
    JS_FreeCString(context, value);
    JS_FreeCString(context, name);
    if (set_result < 0) return JS_EXCEPTION;
    return JS_UNDEFINED;
}

static JSValue cqjs_response_header(JSContext *context, JSValueConst this_value, int argument_count, JSValueConst *arguments) {
    (void)this_value;
    if (argument_count < 1 || !JS_IsString(arguments[0])) return JS_ThrowTypeError(context, "Header name must be a string.");
    CQJSRunState *state = JS_GetContextOpaque(context);
    size_t name_length = 0;
    const char *name = JS_ToCStringLen(context, &name_length, arguments[0]);
    if (!name) return JS_EXCEPTION;
    for (size_t index = 0; index < state->input->header_count; index++) {
        const CQJSHeader *header = &state->input->headers[index];
        if (header->name_length == name_length && strncasecmp(header->name, name, name_length) == 0) {
            JS_FreeCString(context, name);
            return JS_NewStringLen(context, header->value, header->value_length);
        }
    }
    JS_FreeCString(context, name);
    return JS_NULL;
}

static JSValue cqjs_response_text(JSContext *context, JSValueConst this_value, int argument_count, JSValueConst *arguments) {
    (void)this_value; (void)argument_count; (void)arguments;
    CQJSRunState *state = JS_GetContextOpaque(context);
    if (cqjs_is_cancelled(state) || cqjs_is_timed_out(state)) return JS_ThrowInternalError(context, "interrupted");
    if (!JS_IsUndefined(state->text_cache)) return JS_DupValue(context, state->text_cache);
    if (!cqjs_valid_utf8(state, state->input->body, state->input->body_length)) {
        if (cqjs_is_cancelled(state) || cqjs_is_timed_out(state)) return JS_ThrowInternalError(context, "interrupted");
        return JS_ThrowTypeError(context, "Response body is not valid UTF-8.");
    }
    state->text_cache = JS_NewStringLen(context, (const char *)state->input->body, state->input->body_length);
    return JS_DupValue(context, state->text_cache);
}

static JSValue cqjs_response_json(JSContext *context, JSValueConst this_value, int argument_count, JSValueConst *arguments) {
    (void)this_value; (void)argument_count; (void)arguments;
    CQJSRunState *state = JS_GetContextOpaque(context);
    if (cqjs_is_cancelled(state) || cqjs_is_timed_out(state)) return JS_ThrowInternalError(context, "interrupted");
    if (!JS_IsUndefined(state->json_cache)) return JS_DupValue(context, state->json_cache);
    if (state->input->body_length == 0) return JS_ThrowSyntaxError(context, "Response body is empty.");
    if (state->input->body_length > CQJS_JSON_BODY_LIMIT) return JS_ThrowRangeError(context, "Response JSON exceeds the 8 MiB scripting limit.");
    if (!cqjs_valid_utf8(state, state->input->body, state->input->body_length)) {
        if (cqjs_is_cancelled(state) || cqjs_is_timed_out(state)) return JS_ThrowInternalError(context, "interrupted");
        return JS_ThrowTypeError(context, "Response body is not valid UTF-8.");
    }
    /* QuickJS's JSON lexer reads a sentinel byte at buf[buf_len]. Swift Data only
       guarantees the requested byte range, so create that sentinel lazily and
       only for scripts that ask for JSON. */
    char *terminated_body = js_malloc(context, state->input->body_length + 1);
    if (!terminated_body) return JS_ThrowOutOfMemory(context);
    memcpy(terminated_body, state->input->body, state->input->body_length);
    terminated_body[state->input->body_length] = '\0';
    state->json_cache = JS_ParseJSON(context, terminated_body, state->input->body_length, "response.json");
    js_free(context, terminated_body);
    if (cqjs_is_cancelled(state) || cqjs_is_timed_out(state)) {
        if (JS_IsException(state->json_cache)) {
            JSValue ignored = JS_GetException(context);
            JS_FreeValue(context, ignored);
        } else {
            JS_FreeValue(context, state->json_cache);
        }
        state->json_cache = JS_UNDEFINED;
        return JS_ThrowInternalError(context, "interrupted");
    }
    if (JS_IsException(state->json_cache)) return JS_EXCEPTION;
    return JS_DupValue(context, state->json_cache);
}

static int cqjs_define_value(JSContext *context, JSValueConst object, const char *name, JSValue value) {
    return JS_DefinePropertyValueStr(context, object, name, value, JS_PROP_ENUMERABLE);
}

static int cqjs_define_function(JSContext *context, JSValueConst object, const char *name, JSCFunction *function, int argument_count) {
    return cqjs_define_value(context, object, name, JS_NewCFunction(context, function, name, argument_count));
}

static bool cqjs_install_api(JSContext *context, CQJSRunState *state) {
    JS_SetContextOpaque(context, state);
    JSValue global = JS_GetGlobalObject(context);
    JSValue curly = JS_NewObjectProto(context, JS_NULL);
    JSValue response = JS_NewObjectProto(context, JS_NULL);
    JSValue variables = JS_NewObjectProto(context, JS_NULL);
    JSValue global_variables = JS_NewObjectProto(context, JS_NULL);
    JSValue request_variables = JS_NewObjectProto(context, JS_NULL);
    JSValue console = JS_NewObjectProto(context, JS_NULL);
    if (JS_IsException(global) || JS_IsException(curly) || JS_IsException(response) || JS_IsException(variables) ||
        JS_IsException(global_variables) || JS_IsException(request_variables) || JS_IsException(console)) goto fail;

    if (cqjs_define_value(context, response, "status", JS_NewInt32(context, state->input->status_code)) < 0 ||
        cqjs_define_value(context, response, "ok", JS_NewBool(context, state->input->status_code >= 200 && state->input->status_code <= 299)) < 0 ||
        cqjs_define_value(context, response, "durationMs", JS_NewInt64(context, state->input->duration_ms)) < 0 ||
        cqjs_define_value(context, response, "sizeBytes", JS_NewUint64(context, state->input->size_bytes)) < 0 ||
        cqjs_define_function(context, response, "header", cqjs_response_header, 1) < 0 ||
        cqjs_define_function(context, response, "text", cqjs_response_text, 0) < 0 ||
        cqjs_define_function(context, response, "json", cqjs_response_json, 0) < 0 ||
        cqjs_define_value(context, variables, "get", JS_NewCFunctionMagic(context, cqjs_variable_get, "get", 1, JS_CFUNC_generic_magic, 0)) < 0 ||
        cqjs_define_value(context, global_variables, "get", JS_NewCFunctionMagic(context, cqjs_variable_get, "get", 1, JS_CFUNC_generic_magic, CQJS_SCOPE_GLOBAL + 1)) < 0 ||
        cqjs_define_value(context, global_variables, "set", JS_NewCFunctionMagic(context, cqjs_variable_set, "set", 2, JS_CFUNC_generic_magic, CQJS_SCOPE_GLOBAL)) < 0 ||
        cqjs_define_value(context, request_variables, "get", JS_NewCFunctionMagic(context, cqjs_variable_get, "get", 1, JS_CFUNC_generic_magic, CQJS_SCOPE_REQUEST + 1)) < 0 ||
        cqjs_define_value(context, request_variables, "set", JS_NewCFunctionMagic(context, cqjs_variable_set, "set", 2, JS_CFUNC_generic_magic, CQJS_SCOPE_REQUEST)) < 0 ||
        cqjs_define_value(context, variables, "global", JS_DupValue(context, global_variables)) < 0 ||
        cqjs_define_value(context, variables, "request", JS_DupValue(context, request_variables)) < 0 ||
        cqjs_define_value(context, curly, "response", JS_DupValue(context, response)) < 0 ||
        cqjs_define_value(context, curly, "variables", JS_DupValue(context, variables)) < 0 ||
        cqjs_define_value(context, console, "log", JS_NewCFunctionMagic(context, cqjs_console, "log", 1, JS_CFUNC_generic_magic, CQJS_LOG_INFO)) < 0 ||
        cqjs_define_value(context, console, "warn", JS_NewCFunctionMagic(context, cqjs_console, "warn", 1, JS_CFUNC_generic_magic, CQJS_LOG_WARNING)) < 0 ||
        cqjs_define_value(context, console, "error", JS_NewCFunctionMagic(context, cqjs_console, "error", 1, JS_CFUNC_generic_magic, CQJS_LOG_ERROR)) < 0 ||
        JS_DefinePropertyValueStr(context, global, "curly", JS_DupValue(context, curly), 0) < 0 ||
        JS_DefinePropertyValueStr(context, global, "console", JS_DupValue(context, console), 0) < 0) goto fail;

    JS_FreezeObject(context, response);
    JS_FreezeObject(context, global_variables);
    JS_FreezeObject(context, request_variables);
    JS_FreezeObject(context, variables);
    JS_FreezeObject(context, curly);
    JS_FreezeObject(context, console);
    JS_FreeValue(context, global);
    JS_FreeValue(context, curly);
    JS_FreeValue(context, response);
    JS_FreeValue(context, variables);
    JS_FreeValue(context, global_variables);
    JS_FreeValue(context, request_variables);
    JS_FreeValue(context, console);
    return true;

fail:
    JS_FreeValue(context, global);
    JS_FreeValue(context, curly);
    JS_FreeValue(context, response);
    JS_FreeValue(context, variables);
    JS_FreeValue(context, global_variables);
    JS_FreeValue(context, request_variables);
    JS_FreeValue(context, console);
    return false;
}

static void cqjs_parse_location(const char *stack, int *line, int *column) {
    if (!stack) return;
    const char *cursor = strstr(stack, "post-response.js:");
    if (!cursor) return;
    cursor += strlen("post-response.js:");
    int parsed_line = 0;
    int parsed_column = 0;
    if (sscanf(cursor, "%d:%d", &parsed_line, &parsed_column) >= 1) {
        *line = parsed_line;
        *column = parsed_column;
    }
}

static void cqjs_capture_exception(JSContext *context, CQJSResult *result) {
    JSValue exception = JS_GetException(context);
    JSValue message_value = JS_UNDEFINED;
    const char *message = NULL;
    if (JS_IsObject(exception)) {
        message_value = JS_GetPropertyStr(context, exception, "message");
        if (JS_IsException(message_value)) {
            JSValue ignored = JS_GetException(context);
            JS_FreeValue(context, ignored);
            message_value = JS_UNDEFINED;
        } else if (!JS_IsNull(message_value) && !JS_IsUndefined(message_value)) {
            message = JS_ToCString(context, message_value);
        }
    }
    if (!message) message = JS_ToCString(context, exception);
    cqjs_result_set_message(result, message ? message : "Script execution failed.");
    if (message) JS_FreeCString(context, message);

    JSValue stack_value = JS_IsObject(exception)
        ? JS_GetPropertyStr(context, exception, "stack")
        : JS_UNDEFINED;
    const char *stack = JS_IsString(stack_value) ? JS_ToCString(context, stack_value) : NULL;
    cqjs_parse_location(stack, &result->line, &result->column);
    if (stack) JS_FreeCString(context, stack);
    JS_FreeValue(context, stack_value);
    JS_FreeValue(context, message_value);
    JS_FreeValue(context, exception);
}

static bool cqjs_extract_staged(JSContext *context, JSValueConst object, CQJSScope scope, CQJSResult *result) {
    JSPropertyEnum *properties = NULL;
    uint32_t count = 0;
    if (JS_GetOwnPropertyNames(context, &properties, &count, object, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) return false;
    for (uint32_t index = 0; index < count; index++) {
        size_t name_length = 0;
        const char *name = JS_AtomToCStringLen(context, &name_length, properties[index].atom);
        JSValue value = JS_GetProperty(context, object, properties[index].atom);
        size_t value_length = 0;
        const char *value_bytes = JS_ToCStringLen(context, &value_length, value);
        if (!name || !value_bytes) {
            if (name) JS_FreeCString(context, name);
            if (value_bytes) JS_FreeCString(context, value_bytes);
            JS_FreeValue(context, value);
            JS_FreePropertyEnum(context, properties, count);
            return false;
        }
        CQJSWrite *expanded = realloc(result->writes, sizeof(CQJSWrite) * (result->write_count + 1));
        if (!expanded) {
            JS_FreeCString(context, name);
            JS_FreeCString(context, value_bytes);
            JS_FreeValue(context, value);
            JS_FreePropertyEnum(context, properties, count);
            return false;
        }
        result->writes = expanded;
        CQJSWrite write = {
            .scope = scope,
            .name = cqjs_copy_bytes(name, name_length),
            .value = (uint8_t *)cqjs_copy_bytes(value_bytes, value_length),
            .value_length = value_length,
        };
        JS_FreeCString(context, name);
        JS_FreeCString(context, value_bytes);
        JS_FreeValue(context, value);
        if (!write.name || !write.value) {
            free(write.name);
            free(write.value);
            JS_FreePropertyEnum(context, properties, count);
            return false;
        }
        result->writes[result->write_count++] = write;
    }
    JS_FreePropertyEnum(context, properties, count);
    return true;
}

static void cqjs_transfer_logs(CQJSRunState *state, CQJSResult *result) {
    if (state->logs_truncated && state->log_count == CQJS_LOG_LIMIT) {
        free(state->logs[CQJS_LOG_LIMIT - 1].text);
        const char *notice = "Additional console output was truncated.";
        size_t length = strlen(notice);
        state->logs[CQJS_LOG_LIMIT - 1] = (CQJSLog){
            .level = CQJS_LOG_WARNING,
            .text = (uint8_t *)cqjs_copy_bytes(notice, length),
            .text_length = length,
        };
    } else if (state->logs_truncated) {
        const char *notice = "Additional console output was truncated.";
        cqjs_add_log(state, CQJS_LOG_WARNING, (const uint8_t *)notice, strlen(notice));
    }
    if (state->log_count > 0) {
        result->logs = calloc(state->log_count, sizeof(CQJSLog));
        if (result->logs) {
            memcpy(result->logs, state->logs, state->log_count * sizeof(CQJSLog));
            result->log_count = state->log_count;
            for (size_t index = 0; index < state->log_count; index++) state->logs[index].text = NULL;
        }
    }
    result->logs_truncated = state->logs_truncated;
}

static void cqjs_free_state_values(JSContext *context, CQJSRunState *state) {
    JS_FreeValue(context, state->staged_global);
    JS_FreeValue(context, state->staged_request);
    JS_FreeValue(context, state->text_cache);
    JS_FreeValue(context, state->json_cache);
    for (size_t index = 0; index < state->log_count; index++) free(state->logs[index].text);
}

static JSContext *cqjs_create_context(JSRuntime *runtime) {
    JSContext *context = JS_NewContextRaw(runtime);
    if (!context) return NULL;
    if (JS_AddIntrinsicBaseObjects(context) ||
        JS_AddIntrinsicDate(context) ||
        JS_AddIntrinsicEval(context) ||
        JS_AddIntrinsicRegExp(context) ||
        JS_AddIntrinsicJSON(context) ||
        JS_AddIntrinsicMapSet(context)) {
        JS_FreeContext(context);
        return NULL;
    }
    return context;
}

static CQJSResult *cqjs_evaluate(
    const CQJSInput *provided_input,
    const char *source,
    size_t source_length,
    CQJSCancellationToken *token,
    bool compile_only
) {
    uint64_t started_ns = cqjs_now_ns();
    CQJSResult *result = cqjs_result_create(compile_only ? CQJS_RESULT_VALID : CQJS_RESULT_PASSED);
    if (!result) return NULL;
    if (!source || source_length > CQJS_SOURCE_LIMIT) {
        result->status = CQJS_RESULT_INVALID;
        cqjs_result_set_message(result, "Script source exceeds 64 KiB.");
        return result;
    }

    CQJSInput empty_input = {0};
    CQJSRunState state = {
        .input = provided_input ? provided_input : &empty_input,
        .token = token,
        .deadline_ns = started_ns + CQJS_DEADLINE_NS,
        .staged_global = JS_UNDEFINED,
        .staged_request = JS_UNDEFINED,
        .text_cache = JS_UNDEFINED,
        .json_cache = JS_UNDEFINED,
    };

    if (token && atomic_load_explicit(&token->cancelled, memory_order_relaxed)) {
        result->status = CQJS_RESULT_CANCELLED;
        cqjs_result_set_message(result, "Script execution was cancelled.");
        return result;
    }

    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) {
        result->status = CQJS_RESULT_FAILED;
        cqjs_result_set_message(result, "Could not create the JavaScript runtime.");
        return result;
    }
    atomic_fetch_add_explicit(&cqjs_live_runtime_count, 1, memory_order_relaxed);
    JS_SetMemoryLimit(runtime, CQJS_MEMORY_LIMIT);
    JS_SetMaxStackSize(runtime, CQJS_STACK_LIMIT);
    JS_SetCanBlock(runtime, false);
    JS_SetInterruptHandler(runtime, cqjs_interrupt_handler, &state);

    JSContext *context = cqjs_create_context(runtime);
    if (!context) {
        result->status = CQJS_RESULT_FAILED;
        cqjs_result_set_message(result, "Could not create the JavaScript context.");
        JS_FreeRuntime(runtime);
        atomic_fetch_sub_explicit(&cqjs_live_runtime_count, 1, memory_order_relaxed);
        return result;
    }

    state.staged_global = JS_NewObjectProto(context, JS_NULL);
    state.staged_request = JS_NewObjectProto(context, JS_NULL);
    if (JS_IsException(state.staged_global) || JS_IsException(state.staged_request) || !cqjs_install_api(context, &state)) {
        result->status = CQJS_RESULT_FAILED;
        cqjs_result_set_message(result, "Could not install the Curly script API.");
        goto cleanup;
    }

    JSValue compiled = JS_Eval(
        context,
        source,
        source_length,
        "post-response.js",
        JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT | JS_EVAL_FLAG_COMPILE_ONLY
    );
    if (JS_IsException(compiled)) {
        result->status = CQJS_RESULT_INVALID;
        cqjs_capture_exception(context, result);
        goto cleanup;
    }
    if (cqjs_is_cancelled(&state)) {
        JS_FreeValue(context, compiled);
        result->status = CQJS_RESULT_CANCELLED;
        cqjs_result_set_message(result, "Script execution was cancelled.");
        goto cleanup;
    }
    if (cqjs_is_timed_out(&state)) {
        JS_FreeValue(context, compiled);
        result->status = CQJS_RESULT_TIMED_OUT;
        cqjs_result_set_message(result, "Script exceeded the 1 second limit.");
        goto cleanup;
    }
    if (compile_only) {
        JS_FreeValue(context, compiled);
        goto cleanup;
    }

    JSValue execution = JS_EvalFunction(context, compiled);
    if (JS_IsException(execution)) {
        if (cqjs_is_cancelled(&state)) {
            result->status = CQJS_RESULT_CANCELLED;
            cqjs_result_set_message(result, "Script execution was cancelled.");
            JSValue ignored = JS_GetException(context);
            JS_FreeValue(context, ignored);
        } else if (cqjs_is_timed_out(&state)) {
            result->status = CQJS_RESULT_TIMED_OUT;
            cqjs_result_set_message(result, "Script exceeded the 1 second limit.");
            JSValue ignored = JS_GetException(context);
            JS_FreeValue(context, ignored);
        } else {
            result->status = CQJS_RESULT_FAILED;
            cqjs_capture_exception(context, result);
        }
        goto cleanup;
    }
    JS_FreeValue(context, execution);

    if (cqjs_is_cancelled(&state)) {
        result->status = CQJS_RESULT_CANCELLED;
        cqjs_result_set_message(result, "Script execution was cancelled.");
        goto cleanup;
    }
    if (cqjs_is_timed_out(&state)) {
        result->status = CQJS_RESULT_TIMED_OUT;
        cqjs_result_set_message(result, "Script exceeded the 1 second limit.");
        goto cleanup;
    }

    if (!cqjs_extract_staged(context, state.staged_global, CQJS_SCOPE_GLOBAL, result) ||
        !cqjs_extract_staged(context, state.staged_request, CQJS_SCOPE_REQUEST, result)) {
        result->status = CQJS_RESULT_FAILED;
        cqjs_result_set_message(result, "Could not collect staged variable writes.");
    } else if (cqjs_is_cancelled(&state)) {
        result->status = CQJS_RESULT_CANCELLED;
        cqjs_result_set_message(result, "Script execution was cancelled.");
    } else if (cqjs_is_timed_out(&state)) {
        result->status = CQJS_RESULT_TIMED_OUT;
        cqjs_result_set_message(result, "Script exceeded the 1 second limit.");
    }

cleanup:
    if (result->status != CQJS_RESULT_PASSED) cqjs_result_clear_writes(result);
    result->duration_ms = (int64_t)((cqjs_now_ns() - started_ns) / 1000000ull);
    cqjs_transfer_logs(&state, result);
    cqjs_free_state_values(context, &state);
    JS_FreeContext(context);
    JS_FreeRuntime(runtime);
    atomic_fetch_sub_explicit(&cqjs_live_runtime_count, 1, memory_order_relaxed);
    return result;
}

CQJSResult *CQJSValidate(const char *source, size_t source_length, CQJSCancellationToken *token) {
    return cqjs_evaluate(NULL, source, source_length, token, true);
}

CQJSResult *CQJSRun(const CQJSInput *input, const char *source, size_t source_length, CQJSCancellationToken *token) {
    if (!input) {
        CQJSResult *result = cqjs_result_create(CQJS_RESULT_FAILED);
        cqjs_result_set_message(result, "Script input is unavailable.");
        return result;
    }
    return cqjs_evaluate(input, source, source_length, token, false);
}
