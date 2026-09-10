// Copyright (c) 2018-2026, The DeroGold Developers
//
// Please see the included LICENSE file for more information.

#pragma once

#include <cstdint>
#include <set>
#include <utility>
#include <vector>

namespace GlobalIndexRanges
{
    /* Groups the heights of blocks holding outputs of ours into as few
       /get_global_indexes_for_range requests as it can.

       Each height still widens to the aligned window of `obscurity` blocks
       around it, exactly as a lookup for one block always has, so the daemon
       is never told more precisely than that where our transactions are.
       Windows are then merged, gaps and all, for as long as the merged request
       spans no more than `maxSpan` blocks.

       This used to be one request per block, even for two blocks sharing a
       window, and a wallet receiving often spent most of its sync waiting on
       them.

       Returns half-open [start, end) ranges in ascending order. */
    inline std::vector<std::pair<uint64_t, uint64_t>>
        group(const std::set<uint64_t> &heights, const uint64_t obscurity, const uint64_t maxSpan)
    {
        std::vector<std::pair<uint64_t, uint64_t>> ranges;

        for (const uint64_t height : heights)
        {
            const uint64_t start = height - height % obscurity;
            const uint64_t end = start + obscurity;

            /* Heights arrive ascending, so a window can only extend the last
               range, never land inside an earlier one. */
            if (!ranges.empty() && end - ranges.back().first <= maxSpan)
            {
                ranges.back().second = end;
            }
            else if (ranges.empty() || start >= ranges.back().second)
            {
                ranges.emplace_back(start, end);
            }
            else
            {
                /* Shares a window with the last range, which is already at
                   its limit. Nothing more to ask for. */
            }
        }

        return ranges;
    }
} // namespace GlobalIndexRanges
