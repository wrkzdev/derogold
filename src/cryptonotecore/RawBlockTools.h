// Copyright (c) 2018-2021, The DeroGold Developers
// Copyright (c) 2018-2019, The TurtleCoin Developers
//
// Please see the included LICENSE file for more information.

#pragma once

#include <CryptoNote.h>
#include <WalletTypes.h>
#include <cstdint>
#include <vector>

namespace CryptoNote
{
    /* Turning a transaction as it comes off the wire into the reduced form a
     * wallet works with: the public key, the payment ID, and the key inputs
     * and outputs, with everything a wallet cannot use left behind.
     *
     * These were static members of Core, which made every caller include
     * Core.h - and through it the whole daemon: the blockchain cache, the
     * transaction pool, and the fibre dispatcher that has no implementation
     * outside a real operating system. Neither function ever touched Core's
     * state, so a wallet that only wants to read a transaction now includes
     * this instead, and a WebAssembly build is possible at all.
     */
    WalletTypes::RawCoinbaseTransaction getRawCoinbaseTransaction(const CryptoNote::Transaction &t);

    WalletTypes::RawTransaction getRawTransaction(const std::vector<uint8_t> &rawTX);
} // namespace CryptoNote
