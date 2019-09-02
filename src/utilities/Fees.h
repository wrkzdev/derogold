// Copyright (c) 2012-2017, The CryptoNote developers, The Bytecoin developers
// Copyright (c) 2018-2019, The TurtleCoin Developers
//
// Please see the included LICENSE file for more information.

#pragma once

#include <string>
#include <system_error>

namespace Utilities
{
    /* Returns {minFee, defaultFee} */
    std::tuple<uint64_t, uint64_t> getFeeAllowableRange(const uint64_t height);
} // namespace Utilities
