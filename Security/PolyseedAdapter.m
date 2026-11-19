#import "PolyseedAdapter.h"
#import "Polyseed/include/polyseed.h"
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonCrypto.h>
#include <string.h>

static _Thread_local bool callbackFailure;
static void erase(void *ptr, size_t size) { if (ptr && size) memset_s(ptr, size, 0, size); }
static void secureRandom(void *p, size_t n) {
    if (SecRandomCopyBytes(kSecRandomDefault, n, p) != errSecSuccess) { erase(p, n); callbackFailure = true; }
}
static void kdf(const uint8_t *input, size_t n, const uint8_t *salt, size_t saltSize,
                uint64_t rounds, uint8_t *output, size_t outputSize) {
    if (rounds > UINT32_MAX || CCKeyDerivationPBKDF(kCCPBKDF2, (const char *)input, n, salt, saltSize,
            kCCPRFHmacAlgSHA256, (uint32_t)rounds, output, outputSize) != kCCSuccess) {
        erase(output, outputSize);
        callbackFailure = true;
    }
}
static size_t normalized(const char *input, char *out, bool decomposed) {
    NSString *s = [NSString stringWithUTF8String:input];
    NSString *form = decomposed ? s.decomposedStringWithCompatibilityMapping : s.precomposedStringWithCanonicalMapping;
    if (!form || ![form getCString:out maxLength:POLYSEED_STR_SIZE encoding:NSUTF8StringEncoding]) {
        callbackFailure = true;
        out[0] = 0;
        return 0;
    }
    return strlen(out);
}
static size_t nfc(const char *in, polyseed_str out) { return normalized(in, out, false); }
static size_t nfkd(const char *in, polyseed_str out) { return normalized(in, out, true); }

int XMRPreparePolyseed(const char *mnemonic, const char *password, char *result, size_t capacity) {
    if (!mnemonic || !password || !result || capacity < POLYSEED_STR_SIZE) return 3;
    result[0] = 0;
    @autoreleasepool {
        // Validate all caller input bounds before the upstream fixed-size buffers.
        polyseed_str checked = {0};
        callbackFailure = false;
        nfkd(mnemonic, checked);
        nfkd(password, checked);
        erase(checked, sizeof checked);
        if (callbackFailure) return 3;
        static dispatch_once_t initialized;
        dispatch_once(&initialized, ^{
            polyseed_dependency deps = {.randbytes = secureRandom, .pbkdf2_sha256 = kdf,
                .memzero = erase, .u8_nfc = nfc, .u8_nfkd = nfkd};
            polyseed_inject(&deps);
        });
        polyseed_data *seed = NULL;
        const polyseed_lang *lang = NULL;
        if (polyseed_decode(mnemonic, POLYSEED_MONERO, &lang, &seed) != POLYSEED_OK) return 3;
        int status = 0;
        if (polyseed_is_encrypted(seed) && !password[0]) status = 1;
        else if (!polyseed_is_encrypted(seed) && password[0]) status = 2;
        else {
            if (polyseed_is_encrypted(seed)) polyseed_crypt(seed, password);
            if (!polyseed_encode(seed, lang, POLYSEED_MONERO, result) || callbackFailure) status = 4;
        }
        polyseed_free(seed);
        if (status) erase(result, capacity);
        return status;
    }
}
