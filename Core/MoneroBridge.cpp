#include "MoneroBridge.h"
#include <sstream>
#include "../ThirdParty/wallet2_api.hpp"

// monero_c exposes constructors for pending and unsigned transactions but omits
// their disposal functions. Use the exact matching patched wallet2 C++ interface.
void XMRDisposePending(void *wallet, void *transaction) {
    static_cast<Monero::Wallet *>(wallet)->disposeTransaction(static_cast<Monero::PendingTransaction *>(transaction));
}

void XMRDisposeUnsigned(void *transaction) {
    delete static_cast<Monero::UnsignedTransaction *>(transaction);
}

// A malformed UR/CBOR frame may throw inside the upstream decoder. Never allow
// a C++ exception from externally supplied data to cross the Swift boundary.
void *XMRReadUnsigned(void *wallet, const char *payload) {
    try {
        return static_cast<Monero::Wallet *>(wallet)->loadUnsignedTxUR(payload);
    } catch (...) {
        return nullptr;
    }
}

bool XMRSubmitSigned(void *wallet, const char *payload) {
    try {
        return static_cast<Monero::Wallet *>(wallet)->submitTransactionUR(payload);
    } catch (...) {
        return false;
    }
}

// The upstream C façade hardcodes an empty subaddress set. Call the corresponding
// C++ method so the selected subaddresses and the preferred key images both apply.
void *XMRCreateSelectedTransaction(void *wallet, const char *destination, uint64_t amount, int priority,
                                   const uint32_t *indices, size_t count, const char *keyImages) {
    if (!indices || count == 0 || !keyImages || !*keyImages || amount == 0) return nullptr;
    try {
        std::set<uint32_t> subaddresses(indices, indices + count);
        std::set<std::string> images;
        std::istringstream fields(keyImages);
        for (std::string value; std::getline(fields, value, ',');) {
            if (value.size() != 64) return nullptr;
            images.insert(value);
        }
        return static_cast<Monero::Wallet *>(wallet)->createTransaction(
            destination, "", amount, 0, static_cast<Monero::PendingTransaction::Priority>(priority),
            0, std::move(subaddresses), images);
    } catch (...) {
        return nullptr;
    }
}
