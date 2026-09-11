// Copyright (c) 2018-2026, The DeroGold Developers
//
// Please see the included LICENSE file for more information.

#pragma once

#include <cstdint>

namespace TransactionSize
{
    /* The fewest bytes a transaction with this many inputs and outputs can
       serialise to at this mixin. A floor, not an estimate: every varint is
       counted at its one-byte minimum and nothing else - header, extra,
       payment ID - is counted at all. So a transaction this says is too big
       is too big however it comes out, and one it passes may still be; the
       real check after building it stays.

       Per key input: its type tag, the amount, the count of ring offsets and
       one offset per ring member (varints, a byte at least each), the 32-byte
       key image, and one 64-byte signature per ring member.

       Per output: the amount (a byte at least), its type tag and the 32-byte
       key. */
    inline uint64_t minimumSize(const uint64_t mixin, const uint64_t inputs, const uint64_t outputs)
    {
        const uint64_t ringSize = mixin + 1;

        const uint64_t perInput = 1 + 1 + 1 + ringSize + 32 + 64 * ringSize;

        const uint64_t perOutput = 1 + 1 + 32;

        return inputs * perInput + outputs * perOutput;
    }
} // namespace TransactionSize
