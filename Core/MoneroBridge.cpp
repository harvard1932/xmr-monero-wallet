#include "MoneroBridge.h"
#include <sstream>
#include <signal.h>
#include "../ThirdParty/wallet2_api.hpp"

// Darwin can deliver SIGPIPE when a native transport writes after the peer
// closed the socket. Preserve a handler supplied by the host application.
void XMRInitializeNetworking(void) {
    static const bool initialized = [] {
        struct sigaction current{};
        if (sigaction(SIGPIPE, nullptr, &current) == 0 && current.sa_handler == SIG_DFL) {
            struct sigaction ignore{};
            ignore.sa_handler = SIG_IGN;
            sigemptyset(&ignore.sa_mask);
            sigaction(SIGPIPE, &ignore, nullptr);
        }
        return true;
    }();
    (void)initialized;
}

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

bool XMRImportOutputs(void *wallet, const char *payload) {
    try {
        return static_cast<Monero::Wallet *>(wallet)->importOutputsUR(payload);
    } catch (...) {
        return false;
    }
}

bool XMRImportKeyImages(void *wallet, const char *payload) {
    try {
        return static_cast<Monero::Wallet *>(wallet)->importKeyImagesUR(payload);
    } catch (...) {
        return false;
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
void *XMRPrepareTransaction(void *wallet, const char *destination, uint64_t amount, int priority,
                                   const uint32_t *indices, size_t count, const char *keyImages) {
    if (!wallet || !destination || !keyImages || (count && !indices)) return nullptr;
    try {
        std::set<uint32_t> subaddresses;
        if (count) subaddresses.insert(indices, indices + count);
        std::set<std::string> images;
        std::istringstream fields(keyImages);
        for (std::string value; std::getline(fields, value, ',');) {
            if (value.size() != 64) return nullptr;
            images.insert(value);
        }
        return static_cast<Monero::Wallet *>(wallet)->createTransaction(
            destination, "", amount ? Monero::optional<uint64_t>(amount) : Monero::optional<uint64_t>(), 0, static_cast<Monero::PendingTransaction::Priority>(priority),
            0, std::move(subaddresses), images);
    } catch (...) {
        return nullptr;
    }
}

// Validate the native construction data and report how many source addresses
// the transaction actually links. A sweep may contain multiple transactions.
size_t XMRPendingSourceCount(void *transaction, const uint32_t *allowed, size_t count) {
    if (!transaction || (count && !allowed)) return 0;
    try {
        auto tx = static_cast<Monero::PendingTransaction *>(transaction);
        const auto accounts = tx->subaddrAccount();
        const auto sources = tx->subaddrIndices();
        if (accounts.size() != tx->txCount() || sources.size() != accounts.size()) return 0;
        std::set<uint32_t> permitted;
        if (count) permitted.insert(allowed, allowed + count);
        std::set<uint32_t> used;
        for (size_t i = 0; i < sources.size(); ++i) {
            if (accounts[i] != 0 || sources[i].empty()) return 0;
            for (uint32_t source : sources[i]) {
                if (count && !permitted.count(source)) return 0;
                used.insert(source);
            }
        }
        return used.size();
    } catch (...) { return 0; }
}

// The pinned C wrapper ignores its requested background mode. Select wallet2's
// reuse-password mode explicitly. It stores scan progress in the original cache.
// The pinned C facade's isBackgroundSyncing function calls hasUnknownKeyImages.
bool XMRIsBackgroundSyncing(void *wallet) {
    return static_cast<Monero::Wallet *>(wallet)->isBackgroundSyncing();
}

bool XMRConfigureScanOnly(void *wallet, const char *password) {
    try {
        return static_cast<Monero::Wallet *>(wallet)->setupBackgroundSync(
            Monero::Wallet::BackgroundSync_ReusePassword, password, {});
    } catch (...) { return false; }
}
