#ifndef CURLY_QUICKJS_H
#define CURLY_QUICKJS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    CQJS_SCOPE_GLOBAL = 0,
    CQJS_SCOPE_REQUEST = 1,
} CQJSScope;

typedef enum {
    CQJS_LOG_INFO = 0,
    CQJS_LOG_WARNING = 1,
    CQJS_LOG_ERROR = 2,
} CQJSLogLevel;

typedef enum {
    CQJS_RESULT_VALID = 0,
    CQJS_RESULT_PASSED = 1,
    CQJS_RESULT_INVALID = 2,
    CQJS_RESULT_FAILED = 3,
    CQJS_RESULT_TIMED_OUT = 4,
    CQJS_RESULT_CANCELLED = 5,
} CQJSResultStatus;

typedef struct CQJSInput CQJSInput;
typedef struct CQJSCancellationToken CQJSCancellationToken;
typedef struct CQJSResult CQJSResult;

CQJSInput *CQJSInputCreate(void);
void CQJSInputDestroy(CQJSInput *input);
void CQJSInputSetResponse(
    CQJSInput *input,
    int status_code,
    int64_t duration_ms,
    size_t size_bytes
);
bool CQJSInputAddHeader(
    CQJSInput *input,
    const char *name,
    size_t name_length,
    const char *value,
    size_t value_length
);
bool CQJSInputAddVariable(
    CQJSInput *input,
    CQJSScope scope,
    bool belongs_to_current_request,
    const char *name,
    size_t name_length,
    const char *value,
    size_t value_length
);
void CQJSInputSetBorrowedBody(CQJSInput *input, const uint8_t *bytes, size_t length);

CQJSCancellationToken *CQJSCancellationTokenCreate(void);
void CQJSCancellationTokenCancel(CQJSCancellationToken *token);
void CQJSCancellationTokenDestroy(CQJSCancellationToken *token);

CQJSResult *CQJSValidate(
    const char *source,
    size_t source_length,
    CQJSCancellationToken *token
);
CQJSResult *CQJSRun(
    const CQJSInput *input,
    const char *source,
    size_t source_length,
    CQJSCancellationToken *token
);

void CQJSResultDestroy(CQJSResult *result);
CQJSResultStatus CQJSResultGetStatus(const CQJSResult *result);
const char *CQJSResultGetMessage(const CQJSResult *result);
int CQJSResultGetLine(const CQJSResult *result);
int CQJSResultGetColumn(const CQJSResult *result);
int64_t CQJSResultGetDurationMilliseconds(const CQJSResult *result);

size_t CQJSResultGetWriteCount(const CQJSResult *result);
CQJSScope CQJSResultGetWriteScope(const CQJSResult *result, size_t index);
const char *CQJSResultGetWriteName(const CQJSResult *result, size_t index);
const uint8_t *CQJSResultGetWriteValue(const CQJSResult *result, size_t index);
size_t CQJSResultGetWriteValueLength(const CQJSResult *result, size_t index);

size_t CQJSResultGetLogCount(const CQJSResult *result);
CQJSLogLevel CQJSResultGetLogLevel(const CQJSResult *result, size_t index);
const uint8_t *CQJSResultGetLogText(const CQJSResult *result, size_t index);
size_t CQJSResultGetLogTextLength(const CQJSResult *result, size_t index);
bool CQJSResultLogsWereTruncated(const CQJSResult *result);

int CQJSLiveRuntimeCount(void);

#ifdef __cplusplus
}
#endif

#endif
