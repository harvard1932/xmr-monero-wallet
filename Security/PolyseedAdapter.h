#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// 0 = success, 1 = passphrase required, 2 = passphrase supplied for plaintext,
// 3 = invalid format/encoding, 4 = library failure.
int XMRPreparePolyseed(const char *mnemonic, const char *password, char *result, size_t capacity);
#ifdef __cplusplus
}
#endif
