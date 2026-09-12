// Copyright (c) 2018-2026, The DeroGold Developers
// Copyright (c) 2018-2026, The WrkzCoin developers
//
// Please see the included LICENSE file for more information.

#include <walletcapi/wallet_capi.h>

#include <common/FileSystemShim.h>
#include <common/StringTools.h>
#include <config/Config.h>
#include <config/WalletConfig.h>
#include <cryptonotecore/TransactionPoW.h>
#include <errors/Errors.h>
#include <logger/Logger.h>
#include <nigel/Nigel.h>
#include <nigel/TxPowClient.h>
#include <utilities/Addresses.h>
#include <utilities/Mixins.h>
#include <walletbackend/JsonSerialization.h>
#include <walletbackend/WalletBackend.h>
#include <zedwallet++/SweepMath.h>

#include "json.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>

struct wallet_event_state
{
    std::mutex mutex;
    std::condition_variable cv;
    std::deque<std::pair<uint32_t, std::string>> events;
    std::atomic<bool> closed {false};
};

struct wallet_handle
{
    std::shared_ptr<WalletBackend> wallet;
    std::shared_ptr<wallet_event_state> event_state;
};

namespace
{
    const std::string kVersion = "derogold-wallet-capi/0.1";

    thread_local std::string g_last_error_message;

    std::mutex g_log_mutex;
    std::deque<nlohmann::json> g_logs;
    std::once_flag g_log_bridge_once;

    /* Enough to explain a failure, bounded so a chatty log level cannot grow
       without limit when nothing collects them. */
    constexpr size_t kMaxLogs = 2000;

    /* One event queue per wallet is bounded the same way: a rescan finding
       thousands of transactions must not grow this without limit if the host
       application stops polling. */
    constexpr size_t kMaxEvents = 1024;

    /* Give up rather than loop forever splitting a transaction that is never
       going to fit in a block. Same figure as the CLI sweep. */
    constexpr uint64_t kMaxDivider = 1024;

    /* A sweep estimate simulates transactions rather than sending them; this
       only bounds a pathological case, not any real balance. */
    constexpr uint64_t kMaxEstimatedTransactions = 10000;

    void set_last_error_message(const std::string &message)
    {
        g_last_error_message = message;
    }

    void clear_last_error_message()
    {
        g_last_error_message.clear();
    }

    std::string lower_copy(std::string value)
    {
        std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
            return static_cast<char>(std::tolower(c));
        });
        return value;
    }

    /* The backend logs through a callback rather than to a stream, so a GUI
       has somewhere to read them from. Logging starts disabled; a caller turns
       it on with wallet_set_log_level. */
    void ensure_log_bridge()
    {
        std::call_once(g_log_bridge_once, [] {
            Logger::logger.setLogLevel(Logger::DISABLED);
            Logger::logger.setLogCallback(
                [](const std::string prettyMessage,
                   const std::string message,
                   const Logger::LogLevel level,
                   const std::vector<Logger::LogCategory> categories) {
                    nlohmann::json entry;
                    entry["pretty"] = prettyMessage;
                    entry["message"] = message;
                    entry["level"] = lower_copy(Logger::logLevelToString(level));

                    nlohmann::json cats = nlohmann::json::array();
                    for (const auto &c : categories)
                    {
                        cats.push_back(lower_copy(Logger::logCategoryToString(c)));
                    }
                    entry["categories"] = cats;
                    entry["ts"] = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                                            std::chrono::system_clock::now().time_since_epoch())
                                                            .count());

                    std::lock_guard<std::mutex> lock(g_log_mutex);
                    g_logs.push_back(std::move(entry));
                    while (g_logs.size() > kMaxLogs)
                    {
                        g_logs.pop_front();
                    }
                });
        });
    }

    /* The vendored nlohmann-json is 3.2.0, which predates json::contains(). */
    bool json_has(const nlohmann::json &obj, const char *key)
    {
        return obj.is_object() && obj.find(key) != obj.end();
    }

    wallet_status_t alloc_out_string(const std::string &value, char **out_ptr, size_t *out_len)
    {
        if (out_ptr == nullptr || out_len == nullptr)
        {
            return static_cast<wallet_status_t>(UNKNOWN_ERROR);
        }

        const auto size = value.size();
        auto *buffer = new char[size + 1];
        std::memcpy(buffer, value.data(), size);
        buffer[size] = '\0';
        *out_ptr = buffer;
        *out_len = size;

        return static_cast<wallet_status_t>(SUCCESS);
    }

    wallet_status_t get_wallet(wallet_handle_t *handle, std::shared_ptr<WalletBackend> &out_wallet)
    {
        ensure_log_bridge();

        if (handle == nullptr || !handle->wallet)
        {
            return static_cast<wallet_status_t>(UNKNOWN_ERROR);
        }

        out_wallet = handle->wallet;

        return static_cast<wallet_status_t>(SUCCESS);
    }

    wallet_status_t
        set_out_wallet(const Error &error, const std::shared_ptr<WalletBackend> &wallet, wallet_handle_t **out_wallet)
    {
        if (out_wallet == nullptr)
        {
            return static_cast<wallet_status_t>(UNKNOWN_ERROR);
        }

        if (error)
        {
            *out_wallet = nullptr;
            set_last_error_message(error.getErrorMessage());
            return static_cast<wallet_status_t>(error.getErrorCode());
        }

        auto *handle = new wallet_handle_t();
        handle->wallet = wallet;
        handle->event_state = std::make_shared<wallet_event_state>();

        const auto state = handle->event_state;

        /* These fire on the sync thread and must not block it, so they only
           queue - see EventHandler.h. The queue is drained by
           wallet_poll_event. The backend allows one subscriber per event, so
           nothing else in this process may subscribe to the same wallet. */
        wallet->m_eventHandler->onSynced.subscribe([state](const uint64_t height) {
            if (!state || state->closed.load())
            {
                return;
            }

            const nlohmann::json j {{"height", height}};

            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->events.emplace_back(WALLET_EVENT_SYNCED, j.dump());
                while (state->events.size() > kMaxEvents)
                {
                    state->events.pop_front();
                }
            }

            state->cv.notify_one();
        });

        wallet->m_eventHandler->onTransaction.subscribe([state](const WalletTypes::Transaction tx) {
            if (!state || state->closed.load())
            {
                return;
            }

            const nlohmann::json j = tx;

            {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->events.emplace_back(WALLET_EVENT_TRANSACTION, j.dump());
                while (state->events.size() > kMaxEvents)
                {
                    state->events.pop_front();
                }
            }

            state->cv.notify_one();
        });

        *out_wallet = handle;

        return static_cast<wallet_status_t>(SUCCESS);
    }

    /* The format the Flutter wallets read: transfers as an array with a
       direction, and the net amount alongside. */
    nlohmann::json serialize_transaction(const WalletTypes::Transaction &tx, const bool confirmed)
    {
        nlohmann::json transfers = nlohmann::json::array();

        for (const auto &[publicKey, amount] : tx.transfers)
        {
            (void)publicKey;
            transfers.push_back({
                {"amount", amount},
                {"type", amount >= 0 ? 1 : 0},
            });
        }

        return nlohmann::json {
            {"hash", Common::podToHex(tx.hash.data)},
            {"timestamp", tx.timestamp},
            {"blockHeight", tx.blockHeight},
            {"paymentID", tx.paymentID},
            {"unlockTime", tx.unlockTime},
            {"fee", tx.fee},
            {"isCoinbaseTransaction", tx.isCoinbaseTransaction},
            {"isFusionTransaction", tx.isFusionTransaction()},
            {"totalAmount", tx.totalAmount()},
            {"isConfirmed", confirmed},
            {"transfers", transfers},
        };
    }
} // namespace

uint32_t wallet_capi_api_version(void)
{
    ensure_log_bridge();
    return WALLET_CAPI_API_VERSION;
}

const char *wallet_capi_version_string(void)
{
    return kVersion.c_str();
}

wallet_status_t wallet_open(
    const char *filename,
    const char *password,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet)
{
    clear_last_error_message();

    if (out_wallet == nullptr || filename == nullptr || password == nullptr || daemon_host == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    try
    {
        const auto [error, wallet] = WalletBackend::openWallet(
            std::string(filename), std::string(password), std::string(daemon_host), daemon_port, daemon_ssl,
            sync_threads);

        return set_out_wallet(error, wallet, out_wallet);
    }
    catch (const std::exception &e)
    {
        set_last_error_message(std::string("wallet_open_exception: ") + e.what());
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
    catch (...)
    {
        set_last_error_message("wallet_open_exception: unknown");
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
}

wallet_status_t wallet_create(
    const char *filename,
    const char *password,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet)
{
    clear_last_error_message();

    if (out_wallet == nullptr || filename == nullptr || password == nullptr || daemon_host == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    try
    {
        const auto [error, wallet] = WalletBackend::createWallet(
            std::string(filename), std::string(password), std::string(daemon_host), daemon_port, daemon_ssl,
            sync_threads);

        return set_out_wallet(error, wallet, out_wallet);
    }
    catch (const std::exception &e)
    {
        set_last_error_message(std::string("wallet_create_exception: ") + e.what());
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
    catch (...)
    {
        set_last_error_message("wallet_create_exception: unknown");
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
}

wallet_status_t wallet_restore_from_seed(
    const char *mnemonic_seed,
    const char *filename,
    const char *password,
    uint64_t scan_height,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet)
{
    clear_last_error_message();

    if (out_wallet == nullptr || mnemonic_seed == nullptr || filename == nullptr || password == nullptr
        || daemon_host == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    try
    {
        const auto [error, wallet] = WalletBackend::importWalletFromSeed(
            std::string(mnemonic_seed), std::string(filename), std::string(password), scan_height,
            std::string(daemon_host), daemon_port, daemon_ssl, sync_threads);

        return set_out_wallet(error, wallet, out_wallet);
    }
    catch (const std::exception &e)
    {
        set_last_error_message(std::string("wallet_restore_from_seed_exception: ") + e.what());
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
    catch (...)
    {
        set_last_error_message("wallet_restore_from_seed_exception: unknown");
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
}

wallet_status_t wallet_restore_from_keys(
    const char *private_spend_key_hex,
    const char *private_view_key_hex,
    const char *filename,
    const char *password,
    uint64_t scan_height,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet)
{
    clear_last_error_message();

    if (out_wallet == nullptr || private_spend_key_hex == nullptr || private_view_key_hex == nullptr
        || filename == nullptr || password == nullptr || daemon_host == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    Crypto::SecretKey privateSpendKey;
    Crypto::SecretKey privateViewKey;

    if (!Common::podFromHex(std::string(private_spend_key_hex), privateSpendKey)
        || !Common::podFromHex(std::string(private_view_key_hex), privateViewKey))
    {
        return static_cast<wallet_status_t>(INVALID_KEY_FORMAT);
    }

    try
    {
        const auto [error, wallet] = WalletBackend::importWalletFromKeys(
            privateSpendKey, privateViewKey, std::string(filename), std::string(password), scan_height,
            std::string(daemon_host), daemon_port, daemon_ssl, sync_threads);

        return set_out_wallet(error, wallet, out_wallet);
    }
    catch (const std::exception &e)
    {
        set_last_error_message(std::string("wallet_restore_from_keys_exception: ") + e.what());
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
    catch (...)
    {
        set_last_error_message("wallet_restore_from_keys_exception: unknown");
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
}

wallet_status_t wallet_restore_view(
    const char *private_view_key_hex,
    const char *address,
    const char *filename,
    const char *password,
    uint64_t scan_height,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet)
{
    clear_last_error_message();

    if (out_wallet == nullptr || private_view_key_hex == nullptr || address == nullptr || filename == nullptr
        || password == nullptr || daemon_host == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    Crypto::SecretKey privateViewKey;

    if (!Common::podFromHex(std::string(private_view_key_hex), privateViewKey))
    {
        return static_cast<wallet_status_t>(INVALID_KEY_FORMAT);
    }

    try
    {
        const auto [error, wallet] = WalletBackend::importViewWallet(
            privateViewKey, std::string(address), std::string(filename), std::string(password), scan_height,
            std::string(daemon_host), daemon_port, daemon_ssl, sync_threads);

        return set_out_wallet(error, wallet, out_wallet);
    }
    catch (const std::exception &e)
    {
        set_last_error_message(std::string("wallet_restore_view_exception: ") + e.what());
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
    catch (...)
    {
        set_last_error_message("wallet_restore_view_exception: unknown");
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
}

wallet_status_t wallet_delete_file(const char *filename)
{
    if (filename == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::error_code ec;

    const bool removed = fs::remove(std::string(filename), ec);

    if (removed)
    {
        return static_cast<wallet_status_t>(SUCCESS);
    }

    if (ec)
    {
        return static_cast<wallet_status_t>(INVALID_WALLET_FILENAME);
    }

    return static_cast<wallet_status_t>(FILENAME_NON_EXISTENT);
}

void wallet_close(wallet_handle_t *wallet)
{
    if (wallet != nullptr)
    {
        if (wallet->event_state)
        {
            wallet->event_state->closed.store(true);
            wallet->event_state->cv.notify_all();
        }

        /* Unsubscribe before the handle goes, so a sync thread still running
           cannot fire into a queue that is about to be freed. */
        if (wallet->wallet && wallet->wallet->m_eventHandler)
        {
            wallet->wallet->m_eventHandler->onSynced.unsubscribe();
            wallet->wallet->m_eventHandler->onTransaction.unsubscribe();
        }
    }

    delete wallet;
}

wallet_status_t wallet_save(wallet_handle_t *wallet)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto error = instance->save();

    return static_cast<wallet_status_t>(error.getErrorCode());
}

wallet_status_t wallet_get_sync_status(
    wallet_handle_t *wallet,
    uint64_t *out_wallet_height,
    uint64_t *out_local_daemon_height,
    uint64_t *out_network_height)
{
    if (out_wallet_height == nullptr || out_local_daemon_height == nullptr || out_network_height == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [walletHeight, localHeight, networkHeight] = instance->getSyncStatus();

    *out_wallet_height = walletHeight;
    *out_local_daemon_height = localHeight;
    *out_network_height = networkHeight;

    return static_cast<wallet_status_t>(SUCCESS);
}

wallet_status_t wallet_get_status_json(wallet_handle_t *wallet, char **out_json, size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto s = instance->getStatus();

    const bool isDaemonSynced = s.networkBlockCount > 0 && s.localDaemonBlockCount >= s.networkBlockCount;
    const bool isWalletSynced = s.networkBlockCount > 0 && s.walletBlockCount >= s.networkBlockCount;

    /* The ring sizes the network expects at this height. Without them a caller
       can read back what a transaction was built with but has nothing to
       compare it against. */
    const auto [minMixin, maxMixin, defaultMixin] = Utilities::getMixinAllowableRange(s.networkBlockCount);

    const nlohmann::json j {
        {"walletBlockCount", s.walletBlockCount},
        {"localDaemonBlockCount", s.localDaemonBlockCount},
        {"networkBlockCount", s.networkBlockCount},
        {"peerCount", s.peerCount},
        {"hashrate", s.lastKnownHashrate},
        {"isDaemonSynced", isDaemonSynced},
        {"isWalletSynced", isWalletSynced},
        {"isOutOfSync", !isDaemonSynced && !isWalletSynced},
        {"isViewWallet", instance->isViewWallet()},
        {"subWalletCount", instance->getWalletCount()},
        {"minMixin", minMixin},
        {"maxMixin", maxMixin},
        {"defaultMixin", defaultMixin},
        /* Empty unless the daemon has said why it will not serve this wallet
           blocks - a thing retrying does not fix, so it has to reach the
           person watching rather than sit in a log. */
        {"syncError", s.syncError},
        /* Zero when the daemon holds the whole chain. Otherwise the lowest
           height it can serve a block body from, so a rescan below it finds
           nothing. */
        {"pruneFloor", instance->getPruneFloor()},
        /* Chain reorganisations resolved this run. Only ever increases, so a
           caller polling it can tell one happened between two polls - which
           matters because a reorg silently withdraws transactions it had
           already reported as confirmed. */
        {"forkCount", s.forkCount},
        {"lastForkHeight", s.lastForkHeight},
        {"lastForkDepth", s.lastForkDepth},
        /* True when this wallet synced without coinbase scanning and is now
           set to scan them: the blocks holding only a coinbase were never sent
           to it, so only a reset can recover them. */
        {"coinbaseScanNeedsReset", instance->coinbaseScanMissedBlocks()},
    };

    return alloc_out_string(j.dump(), out_json, out_len);
}

wallet_status_t wallet_daemon_online(wallet_handle_t *wallet, bool *out_online)
{
    if (out_online == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    *out_online = instance->daemonOnline();

    return static_cast<wallet_status_t>(SUCCESS);
}

wallet_status_t wallet_get_node_info_json(wallet_handle_t *wallet, char **out_json, size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [daemonHost, daemonPort, daemonSSL] = instance->getNodeAddress();
    const auto [nodeFee, nodeAddress] = instance->getNodeFee();

    const nlohmann::json j {
        {"daemonHost", daemonHost},
        {"daemonPort", daemonPort},
        {"daemonSSL", daemonSSL},
        {"daemonOnline", instance->daemonOnline()},
        {"nodeFee", nodeFee},
        {"nodeAddress", nodeAddress},
    };

    return alloc_out_string(j.dump(), out_json, out_len);
}

wallet_status_t
    wallet_swap_node(wallet_handle_t *wallet, const char *daemon_host, uint16_t daemon_port, bool daemon_ssl)
{
    if (daemon_host == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    instance->swapNode(std::string(daemon_host), daemon_port, daemon_ssl);

    return static_cast<wallet_status_t>(SUCCESS);
}

wallet_status_t wallet_reset(wallet_handle_t *wallet, uint64_t scan_height, uint64_t timestamp)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    instance->reset(scan_height, timestamp);

    return static_cast<wallet_status_t>(SUCCESS);
}

wallet_status_t wallet_get_transactions_json(
    wallet_handle_t *wallet,
    uint64_t start_height,
    uint64_t end_height_exclusive,
    bool include_unconfirmed,
    char **out_json,
    size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const std::vector<WalletTypes::Transaction> txs = end_height_exclusive > start_height
                                                          ? instance->getTransactionsRange(
                                                                start_height, end_height_exclusive)
                                                          : instance->getTransactions();

    nlohmann::json txArray = nlohmann::json::array();

    for (const auto &tx : txs)
    {
        txArray.push_back(serialize_transaction(tx, true));
    }

    nlohmann::json j {{"transactions", txArray}};

    if (include_unconfirmed)
    {
        nlohmann::json unconfirmed = nlohmann::json::array();

        for (const auto &tx : instance->getUnconfirmedTransactions())
        {
            unconfirmed.push_back(serialize_transaction(tx, false));
        }

        j["unconfirmedTransactions"] = unconfirmed;
    }

    return alloc_out_string(j.dump(), out_json, out_len);
}

wallet_status_t wallet_get_primary_address(wallet_handle_t *wallet, char **out_address, size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    return alloc_out_string(instance->getPrimaryAddress(), out_address, out_len);
}

wallet_status_t wallet_get_addresses_json(wallet_handle_t *wallet, char **out_json, size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const nlohmann::json j {{"addresses", instance->getAddresses()}};

    return alloc_out_string(j.dump(), out_json, out_len);
}

wallet_status_t wallet_get_total_balance(wallet_handle_t *wallet, uint64_t *out_unlocked, uint64_t *out_locked)
{
    if (out_unlocked == nullptr || out_locked == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [unlocked, locked] = instance->getTotalBalance();

    *out_unlocked = unlocked;
    *out_locked = locked;

    return static_cast<wallet_status_t>(SUCCESS);
}

wallet_status_t wallet_get_balance_for_address(
    wallet_handle_t *wallet,
    const char *address,
    uint64_t *out_unlocked,
    uint64_t *out_locked)
{
    if (address == nullptr || out_unlocked == nullptr || out_locked == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [error, unlocked, locked] = instance->getBalance(std::string(address));

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    *out_unlocked = unlocked;
    *out_locked = locked;

    return static_cast<wallet_status_t>(SUCCESS);
}

wallet_status_t wallet_get_balances_json(wallet_handle_t *wallet, char **out_json, size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    nlohmann::json arr = nlohmann::json::array();

    for (const auto &[address, unlocked, locked] : instance->getBalances())
    {
        arr.push_back({{"address", address}, {"unlocked", unlocked}, {"locked", locked}});
    }

    const nlohmann::json j {{"balances", arr}};

    return alloc_out_string(j.dump(), out_json, out_len);
}

wallet_status_t wallet_get_spendable_balance(wallet_handle_t *wallet, uint64_t *out_spendable)
{
    if (out_spendable == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    *out_spendable = instance->getSpendableBalance();

    return static_cast<wallet_status_t>(SUCCESS);
}

wallet_status_t wallet_send_basic(
    wallet_handle_t *wallet,
    const char *destination,
    uint64_t amount,
    const char *payment_id,
    char **out_tx_hash,
    size_t *out_len)
{
    if (destination == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const std::string payment = payment_id == nullptr ? "" : payment_id;

    const auto [error, txHash] = instance->sendTransactionBasic(std::string(destination), amount, payment);

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    return alloc_out_string(Common::podToHex(txHash.data), out_tx_hash, out_len);
}

wallet_status_t wallet_send_advanced_json(
    wallet_handle_t *wallet,
    const char *request_json,
    char **out_result_json,
    size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    nlohmann::json body = nlohmann::json::object();

    if (request_json != nullptr && request_json[0] != '\0')
    {
        try
        {
            body = nlohmann::json::parse(request_json);
        }
        catch (const std::exception &e)
        {
            set_last_error_message(std::string("request is not valid JSON: ") + e.what());
            return static_cast<wallet_status_t>(UNKNOWN_ERROR);
        }
    }

    if (!json_has(body, "destinations") || !body["destinations"].is_array())
    {
        return static_cast<wallet_status_t>(NO_DESTINATIONS_GIVEN);
    }

    std::vector<std::pair<std::string, uint64_t>> destinations;

    for (const auto &destination : body["destinations"])
    {
        if (!json_has(destination, "address") || !json_has(destination, "amount"))
        {
            set_last_error_message("every destination needs an address and an amount");
            return static_cast<wallet_status_t>(UNKNOWN_ERROR);
        }

        destinations.emplace_back(
            destination["address"].get<std::string>(), destination["amount"].get<uint64_t>());
    }

    uint64_t mixin;

    if (json_has(body, "mixin") && body["mixin"].is_number_unsigned())
    {
        mixin = body["mixin"].get<uint64_t>();
    }
    else
    {
        std::tie(std::ignore, std::ignore, mixin) =
            Utilities::getMixinAllowableRange(instance->getStatus().networkBlockCount);
    }

    uint64_t fee = WalletConfig::defaultFee;

    if (json_has(body, "fee") && body["fee"].is_number_unsigned())
    {
        fee = body["fee"].get<uint64_t>();
    }

    std::vector<std::string> sourceAddresses;

    if (json_has(body, "sourceAddresses") && body["sourceAddresses"].is_array())
    {
        sourceAddresses = body["sourceAddresses"].get<std::vector<std::string>>();
    }

    std::string paymentID;

    if (json_has(body, "paymentID") && body["paymentID"].is_string())
    {
        paymentID = body["paymentID"].get<std::string>();
    }

    std::string changeAddress;

    if (json_has(body, "changeAddress") && body["changeAddress"].is_string())
    {
        changeAddress = body["changeAddress"].get<std::string>();
    }

    uint64_t unlockTime = 0;

    if (json_has(body, "unlockTime") && body["unlockTime"].is_number_unsigned())
    {
        unlockTime = body["unlockTime"].get<uint64_t>();
    }

    std::vector<uint8_t> extraData;

    if (json_has(body, "extra") && body["extra"].is_string())
    {
        if (!Common::fromHex(body["extra"].get<std::string>(), extraData))
        {
            return static_cast<wallet_status_t>(INVALID_EXTRA_DATA);
        }
    }

    const auto [error, hash] = instance->sendTransactionAdvanced(
        destinations, mixin, fee, paymentID, sourceAddresses, changeAddress, unlockTime, extraData);

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    uint64_t defaultMixin = 0;

    std::tie(std::ignore, std::ignore, defaultMixin) =
        Utilities::getMixinAllowableRange(instance->getStatus().networkBlockCount);

    const nlohmann::json result {
        {"transactionHash", Common::podToHex(hash.data)},
        {"fee", fee},
        {"mixin", mixin},
        {"defaultMixin", defaultMixin},
    };

    return alloc_out_string(result.dump(), out_result_json, out_len);
}

wallet_status_t wallet_get_tx_private_key(
    wallet_handle_t *wallet,
    const char *tx_hash_hex,
    char **out_tx_private_key_hex,
    size_t *out_len)
{
    if (tx_hash_hex == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    Crypto::Hash hash;

    try
    {
        hash.fromString(std::string(tx_hash_hex));
    }
    catch (...)
    {
        return static_cast<wallet_status_t>(HASH_INVALID);
    }

    const auto [error, key] = instance->getTxPrivateKey(hash);

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    return alloc_out_string(Common::podToHex(key.data), out_tx_private_key_hex, out_len);
}

wallet_status_t wallet_get_private_view_key(
    wallet_handle_t *wallet,
    char **out_private_view_key_hex,
    size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto key = instance->getPrivateViewKey();

    return alloc_out_string(Common::podToHex(key.data), out_private_view_key_hex, out_len);
}

wallet_status_t wallet_get_spend_keys_json(
    wallet_handle_t *wallet,
    const char *address,
    char **out_result_json,
    size_t *out_len)
{
    if (address == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [error, publicSpendKey, privateSpendKey] = instance->getSpendKeys(std::string(address));

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    const nlohmann::json j {
        {"publicSpendKey", Common::podToHex(publicSpendKey.data)},
        {"privateSpendKey", Common::podToHex(privateSpendKey.data)},
    };

    return alloc_out_string(j.dump(), out_result_json, out_len);
}

wallet_status_t wallet_get_mnemonic_seed(wallet_handle_t *wallet, char **out_mnemonic_seed, size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [error, seed] = instance->getMnemonicSeed();

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    return alloc_out_string(seed, out_mnemonic_seed, out_len);
}

wallet_status_t wallet_get_mnemonic_seed_for_address(
    wallet_handle_t *wallet,
    const char *address,
    char **out_mnemonic_seed,
    size_t *out_len)
{
    if (address == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [error, seed] = instance->getMnemonicSeedForAddress(std::string(address));

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    return alloc_out_string(seed, out_mnemonic_seed, out_len);
}

wallet_status_t wallet_is_view_wallet(wallet_handle_t *wallet, bool *out_is_view_wallet)
{
    if (out_is_view_wallet == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    *out_is_view_wallet = instance->isViewWallet();

    return static_cast<wallet_status_t>(SUCCESS);
}

wallet_status_t wallet_change_password(wallet_handle_t *wallet, const char *new_password)
{
    if (new_password == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto error = instance->changePassword(std::string(new_password));

    return static_cast<wallet_status_t>(error.getErrorCode());
}

wallet_status_t wallet_export_json(wallet_handle_t *wallet, char **out_json, size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    return alloc_out_string(instance->toJSON(), out_json, out_len);
}

wallet_status_t wallet_add_subwallet_json(wallet_handle_t *wallet, char **out_result_json, size_t *out_len)
{
    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [error, address, privateSpendKey] = instance->addSubWallet();

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    const nlohmann::json j {
        {"address", address},
        {"privateSpendKey", Common::podToHex(privateSpendKey.data)},
    };

    return alloc_out_string(j.dump(), out_result_json, out_len);
}

wallet_status_t wallet_import_subwallet_from_key(
    wallet_handle_t *wallet,
    const char *private_spend_key_hex,
    uint64_t scan_height,
    char **out_address,
    size_t *out_len)
{
    if (private_spend_key_hex == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    Crypto::SecretKey spendKey;

    if (!Common::podFromHex(std::string(private_spend_key_hex), spendKey))
    {
        return static_cast<wallet_status_t>(INVALID_KEY_FORMAT);
    }

    const auto [error, address] = instance->importSubWallet(spendKey, scan_height);

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    return alloc_out_string(address, out_address, out_len);
}

wallet_status_t wallet_delete_subwallet(wallet_handle_t *wallet, const char *address)
{
    if (address == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto error = instance->deleteSubWallet(std::string(address));

    return static_cast<wallet_status_t>(error.getErrorCode());
}

wallet_status_t wallet_create_integrated_address(
    const char *address,
    const char *payment_id,
    char **out_integrated_address,
    size_t *out_len)
{
    if (address == nullptr || payment_id == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    const auto [error, integrated] =
        Utilities::createIntegratedAddress(std::string(address), std::string(payment_id));

    if (error)
    {
        set_last_error_message(error.getErrorMessage());
        return static_cast<wallet_status_t>(error.getErrorCode());
    }

    return alloc_out_string(integrated, out_integrated_address, out_len);
}

wallet_status_t wallet_sweep_to_address(
    wallet_handle_t *wallet,
    const char *destination,
    const char *payment_id,
    uint64_t amount_to_sweep,
    char **out_result_json,
    size_t *out_len)
{
    if (destination == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const std::string payment = payment_id == nullptr ? "" : payment_id;
    const std::string address(destination);

    const auto [nodeFee, nodeAddress] = instance->getNodeFee();

    /* Paid once per transaction, by the wallet, on top of what arrives. */
    const uint64_t costPerTx = WalletConfig::defaultFee + nodeFee;

    uint64_t remaining = amount_to_sweep == 0 ? instance->getSpendableBalance() : amount_to_sweep;

    uint64_t sent = 0;

    /* Sends that went through. Not results.size(), which also counts the
       failure the run may have ended on. */
    uint64_t transactions = 0;

    /* How many pieces the remainder is split into. Doubled whenever a
       transaction turns out to have too many inputs to fit in a block, and
       halved again after one succeeds - the inputs left are much like the ones
       just spent, so dropping straight back to one piece would rediscover the
       same split one failed attempt at a time. */
    uint64_t divider = 1;

    nlohmann::json results = nlohmann::json::array();

    try
    {
        while (remaining > 0)
        {
            const uint64_t spendable = instance->getSpendableBalance();

            /* feeFromAmount: the fees come out of the amount, so the wallet
               never has to keep a balance back to pay for the sweep. */
            const auto chunk =
                Sweep::calculateChunk(remaining, spendable, costPerTx, WalletConfig::minimumSend, divider, true);

            if (!chunk.possible)
            {
                /* What was just spent comes back as locked change. The CLI
                   waits minutes for it; a caller of this cannot be held that
                   long, so stop and report - sweeping again once the change
                   has unlocked picks up where this left off. */
                break;
            }

            const auto [error, hash] = instance->sendTransactionBasic(address, chunk.amount, payment);

            if (error == TOO_MANY_INPUTS_TO_FIT_IN_BLOCK)
            {
                divider *= 2;

                if (divider > kMaxDivider)
                {
                    results.push_back(
                        {{"error", static_cast<int>(error.getErrorCode())},
                         {"errorMessage", "could not split the transaction small enough to fit in a block"}});
                    break;
                }

                continue;
            }

            if (error)
            {
                results.push_back(
                    {{"error", static_cast<int>(error.getErrorCode())}, {"errorMessage", error.getErrorMessage()}});
                break;
            }

            results.push_back({{"txHash", Common::podToHex(hash.data)}, {"amount", chunk.amount}});

            transactions++;

            sent += chunk.amount;

            /* The fees leave the wallet as well as the amount, so a sweep
               works through its total quicker than the destination receives
               it. calculateChunk caps walletCost at `remaining`, so this
               cannot go below zero. */
            remaining -= chunk.walletCost;

            divider = std::max<uint64_t>(1, divider / 2);
        }
    }
    catch (const std::exception &e)
    {
        set_last_error_message(std::string("wallet_sweep_to_address_exception: ") + e.what());
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
    catch (...)
    {
        set_last_error_message("wallet_sweep_to_address_exception: unknown");
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    const nlohmann::json j {
        {"sent", sent},
        {"remaining", remaining},
        {"transactions", transactions},
        {"results", results},
    };

    return alloc_out_string(j.dump(), out_result_json, out_len);
}

wallet_status_t wallet_estimate_sweep(
    wallet_handle_t *wallet,
    uint64_t amount_to_sweep,
    uint64_t *out_tx_count,
    uint64_t *out_total_fee)
{
    if (out_tx_count == nullptr || out_total_fee == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    const auto [nodeFee, nodeAddress] = instance->getNodeFee();

    const uint64_t costPerTx = WalletConfig::defaultFee + nodeFee;

    const uint64_t spendable = instance->getSpendableBalance();

    uint64_t remaining = amount_to_sweep == 0 ? spendable : amount_to_sweep;

    /* The same arithmetic the sweep itself runs, without sending anything.
       Each simulated transaction takes its cost out of what is left to spend,
       which is what the real balance does as the sweep proceeds. */
    uint64_t simulatedSpendable = spendable;

    uint64_t txCount = 0;

    while (remaining > 0 && txCount < kMaxEstimatedTransactions)
    {
        const auto chunk =
            Sweep::calculateChunk(remaining, simulatedSpendable, costPerTx, WalletConfig::minimumSend, 1, true);

        if (!chunk.possible)
        {
            break;
        }

        txCount++;
        remaining -= chunk.walletCost;
        simulatedSpendable -= chunk.walletCost;
    }

    *out_tx_count = txCount;
    *out_total_fee = txCount * costPerTx;

    return static_cast<wallet_status_t>(SUCCESS);
}

void wallet_string_free(char *p)
{
    delete[] p;
}

wallet_status_t wallet_poll_event(
    wallet_handle_t *wallet,
    uint32_t timeout_ms,
    uint32_t *out_event_type,
    char **out_event_json,
    size_t *out_len)
{
    if (out_event_type == nullptr || out_event_json == nullptr || out_len == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    *out_event_type = WALLET_EVENT_NONE;
    *out_event_json = nullptr;
    *out_len = 0;

    std::shared_ptr<WalletBackend> instance;

    const auto status = get_wallet(wallet, instance);

    if (status != static_cast<wallet_status_t>(SUCCESS))
    {
        return status;
    }

    if (!wallet->event_state)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    auto &state = *wallet->event_state;

    std::unique_lock<std::mutex> lock(state.mutex);

    if (state.events.empty())
    {
        if (timeout_ms == 0)
        {
            return static_cast<wallet_status_t>(SUCCESS);
        }

        state.cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&state] {
            return state.closed.load() || !state.events.empty();
        });
    }

    if (state.events.empty())
    {
        return static_cast<wallet_status_t>(SUCCESS);
    }

    const auto event = state.events.front();
    state.events.pop_front();
    lock.unlock();

    *out_event_type = event.first;

    return alloc_out_string(event.second, out_event_json, out_len);
}

void wallet_get_pow_status(bool *out_active, uint64_t *out_elapsed_ms, uint64_t *out_nonces)
{
    const bool running = PowProgress::active.load(std::memory_order_acquire);

    if (out_active != nullptr)
    {
        *out_active = running;
    }

    if (out_elapsed_ms != nullptr)
    {
        if (running)
        {
            const auto now = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                                       std::chrono::steady_clock::now().time_since_epoch())
                                                       .count());

            const auto start = PowProgress::startMs.load(std::memory_order_relaxed);

            *out_elapsed_ms = now > start ? now - start : 0;
        }
        else
        {
            *out_elapsed_ms = 0;
        }
    }

    if (out_nonces != nullptr)
    {
        *out_nonces = PowProgress::nonces.load(std::memory_order_relaxed);
    }
}

const char *wallet_error_code_to_string(wallet_status_t code)
{
    static thread_local std::string last;

    try
    {
        last = Error(static_cast<ErrorCode>(code)).getErrorMessage();
    }
    catch (...)
    {
        last = "Unknown wallet error code: " + std::to_string(code);
    }

    return last.c_str();
}

const char *wallet_last_error_message(void)
{
    return g_last_error_message.c_str();
}

void wallet_clear_last_error_message(void)
{
    clear_last_error_message();
}

wallet_status_t wallet_set_log_level(const char *level)
{
    ensure_log_bridge();

    if (level == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    try
    {
        Logger::logger.setLogLevel(Logger::stringToLogLevel(std::string(level)));
        return static_cast<wallet_status_t>(SUCCESS);
    }
    catch (...)
    {
        /* stringToLogLevel throws on anything that is not a level name. */
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }
}

wallet_status_t wallet_take_logs_json(char **out_json, size_t *out_len)
{
    ensure_log_bridge();

    if (out_json == nullptr || out_len == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    nlohmann::json payload;
    payload["entries"] = nlohmann::json::array();

    {
        std::lock_guard<std::mutex> lock(g_log_mutex);

        while (!g_logs.empty())
        {
            payload["entries"].push_back(g_logs.front());
            g_logs.pop_front();
        }
    }

    return alloc_out_string(payload.dump(), out_json, out_len);
}

wallet_status_t wallet_clear_logs(void)
{
    ensure_log_bridge();

    std::lock_guard<std::mutex> lock(g_log_mutex);
    g_logs.clear();

    return static_cast<wallet_status_t>(SUCCESS);
}

void wallet_set_scan_coinbase(bool scan)
{
    Config::config.wallet.skipCoinbaseTransactions = !scan;
}

void wallet_set_tx_pow_server(const char *host, uint16_t port, bool ssl)
{
    TxPowClient::configure(host == nullptr ? std::string() : std::string(host), port, ssl);
}

wallet_status_t wallet_test_tx_pow_server(
    const char *host,
    uint16_t port,
    bool ssl,
    char **out_json,
    size_t *out_len)
{
    if (out_json == nullptr || out_len == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    std::string result;

    try
    {
        result = TxPowClient::probe(host == nullptr ? std::string() : std::string(host), port, ssl);
    }
    catch (const std::exception &e)
    {
        result = nlohmann::json {{"ok", false}, {"url", ""}, {"error", e.what()}}.dump();
    }

    return alloc_out_string(result, out_json, out_len);
}

wallet_status_t wallet_test_node(const char *host, uint16_t port, bool ssl, char **out_json, size_t *out_len)
{
    if (out_json == nullptr || out_len == nullptr)
    {
        return static_cast<wallet_status_t>(UNKNOWN_ERROR);
    }

    const std::string daemonHost = host == nullptr ? std::string() : std::string(host);

    nlohmann::json r;
    r["url"] = std::string(ssl ? "https://" : "http://") + daemonHost + ":" + std::to_string(port);

    if (daemonHost.empty() || port == 0)
    {
        r["ok"] = false;
        r["error"] = "host and port are required";
        return alloc_out_string(r.dump(), out_json, out_len);
    }

    const auto started = std::chrono::steady_clock::now();

    try
    {
        /* Short timeout: this is a person waiting on a button, not a sync.
           init() fetches /info and the fee info before it returns, so the
           heights below are already the ones this daemon just reported. */
        Nigel probe(daemonHost, port, ssl, std::chrono::seconds(10));

        probe.init();

        const bool reached = probe.isOnline();

        r["latency_ms"] = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started)
                .count());

        if (!reached)
        {
            r["ok"] = false;
            r["error"] = "no response from /info";
            return alloc_out_string(r.dump(), out_json, out_len);
        }

        const uint64_t local = probe.localDaemonBlockCount();
        const uint64_t network = probe.networkBlockCount();

        r["ok"] = true;
        r["height"] = local;
        r["networkHeight"] = network;
        r["peerCount"] = probe.peerCount();
        r["synced"] = network > 0 && local + 1 >= network;
    }
    catch (const std::exception &e)
    {
        r["ok"] = false;
        r["error"] = e.what();
    }
    catch (...)
    {
        r["ok"] = false;
        r["error"] = "unknown error";
    }

    return alloc_out_string(r.dump(), out_json, out_len);
}
