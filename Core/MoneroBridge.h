#pragma once

#include "../ThirdParty/monero_wallet2_api_c.h"
#include "../ThirdParty/Tor/tor_api.h"
#include "../Security/PolyseedAdapter.h"

#ifdef __cplusplus
extern "C" {
#endif
void XMRInitializeNetworking(void);
void XMRTorReleaseDispatchNames(void);
bool XMRImportOutputs(void *wallet, const char *payload);
bool XMRImportKeyImages(void *wallet, const char *payload);
bool XMRIsBackgroundSyncing(void *wallet);
bool XMRConfigureScanOnly(void *wallet, const char *password);
void XMRDisposePending(void *wallet, void *transaction);
void XMRDisposeUnsigned(void *transaction);
void *XMRCreateSelectedTransaction(void *wallet, const char *destination, uint64_t amount, int priority,
                                   const uint32_t *indices, size_t count, const char *keyImages);
void *XMRReadUnsigned(void *wallet, const char *payload);
bool XMRSubmitSigned(void *wallet, const char *payload);
#ifdef __cplusplus
}
#endif
