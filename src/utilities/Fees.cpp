// Copyright (c) 2012-2017, The CryptoNote developers, The Bytecoin developers
// Copyright (c) 2018, The TurtleCoin Developers
//
// Please see the included LICENSE file for more information.

/////////////////////////////
#include <utilities/Fees.h>
/////////////////////////////

#include <config/CryptoNoteConfig.h>
#include <sstream>
#include <tuple>

namespace Utilities
{
    /* Returns {minFee, defaultFee} */
    std::tuple<uint64_t, uint64_t> getFeeAllowableRange(const uint64_t height)
    {
        uint64_t minFee = CryptoNote::parameters::MINIMUM_FEE;
        uint64_t defaultFee = CryptoNote::parameters::MINIMUM_FEE;

        if (height >= CryptoNote::parameters::MINIMUM_FEE_V1_HEIGHT)
        {
            minFee = CryptoNote::parameters::MINIMUM_FEE_V1;
            defaultFee = CryptoNote::parameters::DEFAULT_FEE_V1;
        }

        return {minFee, defaultFee};
    }
} // namespace Utilities
