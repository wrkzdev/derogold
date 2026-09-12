// Copyright (c) 2018-2026, The DeroGold Developers
// Copyright (c) 2018-2026, The WrkzCoin developers
//
// Please see the included LICENSE file for more information.

#pragma once

#include <CryptoNote.h>
#include <config/CryptoNoteConfig.h>
#include <crypto/hash.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <functional>
#include <vector>

/* Shared progress counters for the transaction proof-of-work search.
   generateTransactionPoW() updates them; a wallet front-end reads them to
   show that something is happening during the seconds the search takes. */
namespace PowProgress
{
    /// True while generateTransactionPoW is running.
    inline std::atomic<bool> active{false};

    /// Millisecond timestamp (steady clock) when the current PoW started.
    inline std::atomic<uint64_t> startMs{0};

    /// Cumulative nonces tried across all threads (updated periodically).
    inline std::atomic<uint64_t> nonces{0};

    /// RAII helper - sets active=true on construction, false on destruction.
    struct Guard
    {
        Guard()
        {
            nonces.store(0, std::memory_order_relaxed);
            startMs.store(
                static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                          std::chrono::steady_clock::now().time_since_epoch())
                                          .count()),
                std::memory_order_relaxed);
            active.store(true, std::memory_order_release);
        }

        ~Guard()
        {
            active.store(false, std::memory_order_release);
        }

        Guard(const Guard &) = delete;
        Guard &operator=(const Guard &) = delete;
    };
} // namespace PowProgress

namespace CryptoNote
{
    /* The nonce is the trailing 8 bytes of tx extra, preceded by
       TX_EXTRA_TRANSACTION_POW_NONCE_IDENTIFIER. Extra is the last field of the
       transaction prefix and is serialized as raw bytes after its length, so
       the nonce is also the trailing 8 bytes of the serialized prefix - which
       is what the wallet, the PoW server and the daemon all hash. */
    constexpr size_t TX_POW_NONCE_SIZE = 8;

    /* Difficulty the daemon demands of a transaction included at `height`.
       Unlike WrkzCoin's it does not depend on the transaction's shape, and
       fusion transactions pay the same as any other. Mirrors
       ValidateTransaction::validateTransactionPoW(); keep the two in step. */
    inline uint64_t transactionPoWDifficulty(const uint64_t height)
    {
        return height < parameters::TRANSACTION_POW_HEIGHT ? 0 : parameters::TRANSACTION_POW_DIFFICULTY;
    }

    /* The hash the daemon checks the difficulty against, over the serialized
       prefix. Also from ValidateTransaction::validateTransactionPoW(). */
    inline void transactionPoWHash(const std::vector<uint8_t> &prefix, Crypto::Hash &hash)
    {
        Crypto::cn_turtle_lite_slow_hash_v2(prefix.data(), prefix.size(), hash);
    }

    /* An external solver for the transaction proof of work. It receives the
       serialized transaction prefix with the nonce field appended and zeroed,
       and the difficulty the nonce must satisfy. It returns true and fills
       `nonce` with the 8 bytes to place at the end of the prefix, or false
       (or throws) to decline, in which case the search runs locally. The
       result is always re-verified here before it is trusted. */
    using RemotePoWSolver = std::function<
        bool(const std::vector<uint8_t> &prefix, uint64_t difficulty, std::array<uint8_t, TX_POW_NONCE_SIZE> &nonce)>;

    /* Appends the tx PoW nonce field to `extra` and finds a nonce satisfying
       the transaction PoW difficulty, asking `remote` first when one is given
       and searching on all hardware threads otherwise. Returns the completed
       extra. Used by the wallet backend when building transactions and by
       TransactionImpl::generateTxProofOfWork. */
    std::vector<uint8_t> generateTransactionPoW(
        CryptoNote::Transaction tx,
        std::vector<uint8_t> extra,
        const RemotePoWSolver &remote = {});
} // namespace CryptoNote
