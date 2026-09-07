// Copyright (c) 2018-2021, The DeroGold Developers
// Copyright (c) 2018-2019, The TurtleCoin Developers
//
// Please see the included LICENSE file for more information.

////////////////////////////////////////////////
#include <walletbackend/SynchronizationStatus.h>
////////////////////////////////////////////////

#include <walletbackend/Constants.h>

/////////////////////
/* CLASS FUNCTIONS */
/////////////////////

uint64_t SynchronizationStatus::getHeight() const
{
    std::scoped_lock lock(m_mutex);

    return m_lastKnownBlockHeight;
}

void SynchronizationStatus::storeBlockHash(const Crypto::Hash hash, const uint64_t height)
{
    std::scoped_lock lock(m_mutex);

    m_lastKnownBlockHeight = height;

    /* Already added this hash */
    if (!m_lastKnownBlockHashes.empty() && m_lastKnownBlockHashes.back() == hash)
    {
        return;
    }

    /* If we're at a checkpoint height, add the hash to the infrequent
       checkpoints (at the beginning of the queue) */
    if (m_lastSavedCheckpointAt + Constants::BLOCK_HASH_CHECKPOINTS_INTERVAL < height)
    {
        m_lastSavedCheckpointAt = height;
        m_blockHashCheckpoints.push_front(hash);
    }

    m_lastKnownBlockHashes.push_front(hash);

    /* If we're exceeding capacity, remove the last (oldest) hash */
    if (m_lastKnownBlockHashes.size() > Constants::LAST_KNOWN_BLOCK_HASHES_SIZE)
    {
        m_lastKnownBlockHashes.pop_back();
    }
}

std::deque<Crypto::Hash> SynchronizationStatus::getBlockCheckpoints() const
{
    std::scoped_lock lock(m_mutex);

    return m_blockHashCheckpoints;
}

std::deque<Crypto::Hash> SynchronizationStatus::getRecentBlockHashes() const
{
    std::scoped_lock lock(m_mutex);

    return m_lastKnownBlockHashes;
}

void SynchronizationStatus::fromJSON(const JSONObject &j)
{
    std::scoped_lock lock(m_mutex);

    for (const auto &x : getArrayFromJSON(j, "blockHashCheckpoints"))
    {
        Crypto::Hash h;
        h.fromString(getStringFromJSONString(x));
        m_blockHashCheckpoints.push_back(h);
    }

    for (const auto &x : getArrayFromJSON(j, "lastKnownBlockHashes"))
    {
        Crypto::Hash h;
        h.fromString(getStringFromJSONString(x));
        m_lastKnownBlockHashes.push_back(h);
    }

    m_lastKnownBlockHeight = getUint64FromJSON(j, "lastKnownBlockHeight");

    /* Optional: wallets written before this field existed do not carry it.
       Without it the marker restarted at zero on every open, so the next block
       processed always looked like a checkpoint height and appended another
       entry to a list that is never trimmed. */
    if (hasMember(j, "lastSavedCheckpointAt"))
    {
        m_lastSavedCheckpointAt = getUint64FromJSON(j, "lastSavedCheckpointAt");
    }
    else
    {
        m_lastSavedCheckpointAt = m_lastKnownBlockHeight;
    }
}

void SynchronizationStatus::toJSON(rapidjson::Writer<rapidjson::StringBuffer> &writer) const
{
    std::scoped_lock lock(m_mutex);

    writer.StartObject();

    writer.Key("blockHashCheckpoints");
    writer.StartArray();
    for (const auto hash : m_blockHashCheckpoints)
    {
        hash.toJSON(writer);
    }
    writer.EndArray();

    writer.Key("lastKnownBlockHashes");
    writer.StartArray();
    for (const auto hash : m_lastKnownBlockHashes)
    {
        hash.toJSON(writer);
    }
    writer.EndArray();

    writer.Key("lastKnownBlockHeight");
    writer.Uint64(m_lastKnownBlockHeight);

    writer.Key("lastSavedCheckpointAt");
    writer.Uint64(m_lastSavedCheckpointAt);

    writer.EndObject();
}
