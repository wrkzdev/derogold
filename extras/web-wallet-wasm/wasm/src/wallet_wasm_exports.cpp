/*
 * wallet_wasm_exports.cpp
 *
 * The browser wallet's entry point. JavaScript hands in a JSON request, this
 * dispatches to wallet_capi and hands back a JSON response:
 *
 *   char *wallet_wasm_request(const char *json_request)
 *
 * The caller must free the returned pointer with _free().
 *
 * Request:   { "method": "<name>", "params": { ... } }
 * Response:  { "ok": true,  "result": <value> }
 *            { "ok": false, "error": <code>, "errorMessage": "<msg>" }
 *
 * The method set mirrors the C API in include/walletcapi/wallet_capi.h, which
 * is narrower than WrkzCoin's: this backend has no prepared transactions, no
 * transaction-status query, no subwallet-by-index import, and no single-step
 * sync - see the note on threads below.
 */

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "walletcapi/wallet_capi.h"
#include "wasm_fs_bridge.h"

/* nlohmann/json, from external/ */
#include "json.hpp"

using json = nlohmann::json;

/* The wallet synchroniser runs on its own threads and has no step-at-a-time
   mode to drive from a timer, so without pthreads a browser wallet would open,
   report itself ready, and never advance a single block. Better to refuse at
   build time than to ship that. */
#if !defined(__EMSCRIPTEN_PTHREADS__)
#error "The WASM wallet needs pthreads: configure with -D DEROGOLD_WASM_PTHREADS=ON (and serve the page with COOP/COEP headers)."
#endif

/* ------------------------------------------------------------------ */
/*  Helpers                                                            */
/* ------------------------------------------------------------------ */

/* Allocate a C string on the WASM heap so JS can read it and free() it. */
static char *heap_strdup(const std::string &s)
{
    char *p = static_cast<char *>(malloc(s.size() + 1));
    if (p)
    {
        memcpy(p, s.data(), s.size());
        p[s.size()] = '\0';
    }
    return p;
}

static char *ok_json(const json &result)
{
    json r;
    r["ok"] = true;
    r["result"] = result;
    return heap_strdup(r.dump());
}

static char *err_json(int code, const std::string &msg)
{
    json r;
    r["ok"] = false;
    r["error"] = code;
    r["errorMessage"] = msg;
    return heap_strdup(r.dump());
}

static char *err_json(wallet_status_t code)
{
    const char *last = wallet_last_error_message();
    const std::string msg = (last && last[0]) ? last : wallet_error_code_to_string(code);
    wallet_clear_last_error_message();
    return err_json(static_cast<int>(code), msg);
}

/* The vendored nlohmann-json is 3.2.0, which predates json::contains(). */
static bool has_key(const json &j, const char *key)
{
    return j.is_object() && j.find(key) != j.end();
}

static std::string str_param(const json &p, const char *key)
{
    if (has_key(p, key) && p[key].is_string())
    {
        return p[key].get<std::string>();
    }
    return {};
}

static uint64_t u64_param(const json &p, const char *key, uint64_t def = 0)
{
    if (has_key(p, key) && p[key].is_number())
    {
        return p[key].get<uint64_t>();
    }
    return def;
}

static uint32_t u32_param(const json &p, const char *key, uint32_t def = 0)
{
    if (has_key(p, key) && p[key].is_number())
    {
        return p[key].get<uint32_t>();
    }
    return def;
}

static uint16_t u16_param(const json &p, const char *key, uint16_t def = 0)
{
    return static_cast<uint16_t>(u32_param(p, key, def));
}

static bool bool_param(const json &p, const char *key, bool def = false)
{
    if (has_key(p, key) && p[key].is_boolean())
    {
        return p[key].get<bool>();
    }
    return def;
}

/* How many block-processing threads to ask for.
 *
 * A caller's explicit value wins. Otherwise this follows
 * navigator.hardwareConcurrency, which is what hardware_concurrency() reports
 * here, with a floor for browsers that refuse to say and a ceiling that is not
 * about diminishing returns: every thread has to come out of the pool fixed by
 * -sPTHREAD_POOL_SIZE at link time. Once that pool is empty a pthread_create
 * needs a fresh Worker built, and that work is done by the main thread's event
 * loop - which this module keeps leaving, because every call from JS is a
 * blocking ccall. A thread waiting on a thread that cannot be created does not
 * fail, it hangs.
 *
 * Count the peak, not the obvious part: the synchroniser's main loop, the
 * block downloader, Nigel's background refresh, N of these, the parallel
 * download windows the downloader then blocks on, and the short-lived event
 * handlers. Raise this and PTHREAD_POOL_SIZE together or not at all. */
static uint32_t resolve_sync_threads(const json &p)
{
    const uint32_t requested = u32_param(p, "syncThreads", 0);

    if (requested != 0)
    {
        return requested;
    }

    constexpr uint32_t SYNC_THREADS_MAX = 6;

    const uint32_t hw = static_cast<uint32_t>(std::thread::hardware_concurrency());

    return std::max(1u, std::min(hw, SYNC_THREADS_MAX));
}

/* A wallet_capi call that hands back a plain string. */
static char *string_result(wallet_status_t st, char *out, size_t /*len*/)
{
    if (st != 0)
    {
        return err_json(st);
    }
    const std::string s(out ? out : "");
    wallet_string_free(out);
    return ok_json(s);
}

/* A wallet_capi call that hands back JSON, returned parsed rather than as a
   string so the JS side does not have to decode twice. */
static char *json_result(wallet_status_t st, char *out, size_t /*len*/)
{
    if (st != 0)
    {
        return err_json(st);
    }
    const json parsed = json::parse(out ? out : "null", nullptr, false);
    wallet_string_free(out);
    return ok_json(parsed);
}

/* ------------------------------------------------------------------ */
/*  One wallet per module instance                                     */
/* ------------------------------------------------------------------ */

static wallet_handle_t *g_wallet = nullptr;

/* wallet_capi owns the log callback: it installs its own bridge the first time
   any handle-based call runs, so anything this file registered would be
   replaced the moment a wallet opened. Logging therefore goes through the C
   API's own setLogLevel / takeLogsJson / clearLogs, exactly as the desktop
   wallet uses them. The JS side sends the numeric level. */
static const char *log_level_name(uint32_t level)
{
    switch (level)
    {
        case 0: return "disabled";
        case 1: return "fatal";
        case 2: return "warning";
        case 3: return "info";
        case 4: return "debug";
        default: return "trace";
    }
}

/* ------------------------------------------------------------------ */
/*  Dispatch                                                           */
/* ------------------------------------------------------------------ */

static char *dispatch(const std::string &method, const json &p)
{
    /* -------- version / info -------- */

    if (method == "apiVersion")
    {
        return ok_json(static_cast<int>(wallet_capi_api_version()));
    }

    if (method == "versionString")
    {
        const char *v = wallet_capi_version_string();
        return ok_json(v ? v : "");
    }

    if (method == "isPthreadsEnabled")
    {
        /* Always true: the module refuses to build otherwise. Kept so the JS
           side can assert it rather than assume it. */
        return ok_json(true);
    }

    /* -------- logging -------- */

    if (method == "setLogLevel")
    {
        const uint32_t levelInt = std::min(u32_param(p, "level", 3 /* info */), 5u);
        const wallet_status_t st = wallet_set_log_level(log_level_name(levelInt));
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "takeLogsJson")
    {
        char *out = nullptr;
        size_t len = 0;
        return json_result(wallet_take_logs_json(&out, &len), out, len);
    }

    if (method == "clearLogs")
    {
        const wallet_status_t st = wallet_clear_logs();
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(true);
    }

    /* -------- lifecycle -------- */

    if (method == "create")
    {
        if (g_wallet)
        {
            return err_json(-1, "wallet already open");
        }
        const auto filename = str_param(p, "filename");
        const auto password = str_param(p, "password");
        const auto host = str_param(p, "daemonHost");
        const auto port = u16_param(p, "daemonPort");
        const auto ssl = bool_param(p, "daemonSsl");
        const wallet_status_t st = wallet_create(
            filename.c_str(), password.c_str(), host.c_str(), port, ssl,
            resolve_sync_threads(p), &g_wallet);
        if (st != 0)
        {
            g_wallet = nullptr;
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "open")
    {
        if (g_wallet)
        {
            return err_json(-1, "wallet already open");
        }
        const auto filename = str_param(p, "filename");
        const auto password = str_param(p, "password");
        const auto host = str_param(p, "daemonHost");
        const auto port = u16_param(p, "daemonPort");
        const auto ssl = bool_param(p, "daemonSsl");
        const wallet_status_t st = wallet_open(
            filename.c_str(), password.c_str(), host.c_str(), port, ssl,
            resolve_sync_threads(p), &g_wallet);
        if (st != 0)
        {
            g_wallet = nullptr;
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "restoreFromSeed")
    {
        if (g_wallet)
        {
            return err_json(-1, "wallet already open");
        }
        const auto seed = str_param(p, "mnemonicSeed");
        const auto filename = str_param(p, "filename");
        const auto password = str_param(p, "password");
        const auto host = str_param(p, "daemonHost");
        const auto port = u16_param(p, "daemonPort");
        const auto ssl = bool_param(p, "daemonSsl");
        const wallet_status_t st = wallet_restore_from_seed(
            seed.c_str(), filename.c_str(), password.c_str(), u64_param(p, "scanHeight"),
            host.c_str(), port, ssl, resolve_sync_threads(p), &g_wallet);
        if (st != 0)
        {
            g_wallet = nullptr;
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "restoreFromKeys")
    {
        if (g_wallet)
        {
            return err_json(-1, "wallet already open");
        }
        const auto spendKey = str_param(p, "privateSpendKey");
        const auto viewKey = str_param(p, "privateViewKey");
        const auto filename = str_param(p, "filename");
        const auto password = str_param(p, "password");
        const auto host = str_param(p, "daemonHost");
        const auto port = u16_param(p, "daemonPort");
        const auto ssl = bool_param(p, "daemonSsl");
        const wallet_status_t st = wallet_restore_from_keys(
            spendKey.c_str(), viewKey.c_str(), filename.c_str(), password.c_str(),
            u64_param(p, "scanHeight"), host.c_str(), port, ssl,
            resolve_sync_threads(p), &g_wallet);
        if (st != 0)
        {
            g_wallet = nullptr;
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "restoreViewWallet")
    {
        if (g_wallet)
        {
            return err_json(-1, "wallet already open");
        }
        const auto viewKey = str_param(p, "privateViewKey");
        const auto address = str_param(p, "address");
        const auto filename = str_param(p, "filename");
        const auto password = str_param(p, "password");
        const auto host = str_param(p, "daemonHost");
        const auto port = u16_param(p, "daemonPort");
        const auto ssl = bool_param(p, "daemonSsl");
        const wallet_status_t st = wallet_restore_view(
            viewKey.c_str(), address.c_str(), filename.c_str(), password.c_str(),
            u64_param(p, "scanHeight"), host.c_str(), port, ssl,
            resolve_sync_threads(p), &g_wallet);
        if (st != 0)
        {
            g_wallet = nullptr;
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "close")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        /* This runs the wallet's final save, which lands in WasmFs - the JS
           side still has to call exportFileData afterwards to persist it. */
        wallet_close(g_wallet);
        g_wallet = nullptr;
        return ok_json(true);
    }

    if (method == "save")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const wallet_status_t st = wallet_save(g_wallet);
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "deleteFile")
    {
        const auto filename = str_param(p, "filename");
        const wallet_status_t st = wallet_delete_file(filename.c_str());
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(true);
    }

    /* -------- sync and node -------- */

    if (method == "getSyncStatus")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        uint64_t wh = 0, ldh = 0, nh = 0;
        const wallet_status_t st = wallet_get_sync_status(g_wallet, &wh, &ldh, &nh);
        if (st != 0)
        {
            return err_json(st);
        }
        json r;
        r["walletHeight"] = wh;
        r["localDaemonHeight"] = ldh;
        r["networkHeight"] = nh;
        return ok_json(r);
    }

    if (method == "getStatusJson")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return json_result(wallet_get_status_json(g_wallet, &out, &len), out, len);
    }

    if (method == "isDaemonOnline")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        bool online = false;
        const wallet_status_t st = wallet_daemon_online(g_wallet, &online);
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(online);
    }

    if (method == "getNodeInfoJson")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return json_result(wallet_get_node_info_json(g_wallet, &out, &len), out, len);
    }

    if (method == "swapNode")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto host = str_param(p, "daemonHost");
        const wallet_status_t st = wallet_swap_node(
            g_wallet, host.c_str(), u16_param(p, "daemonPort"), bool_param(p, "daemonSsl"));
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "reset")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const wallet_status_t st =
            wallet_reset(g_wallet, u64_param(p, "scanHeight"), u64_param(p, "timestamp"));
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(true);
    }

    /* -------- balance -------- */

    if (method == "getTotalBalance")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        uint64_t unlocked = 0, locked = 0;
        const wallet_status_t st = wallet_get_total_balance(g_wallet, &unlocked, &locked);
        if (st != 0)
        {
            return err_json(st);
        }
        json r;
        r["unlocked"] = unlocked;
        r["locked"] = locked;
        return ok_json(r);
    }

    if (method == "getSpendableBalance")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        uint64_t spendable = 0;
        const wallet_status_t st = wallet_get_spendable_balance(g_wallet, &spendable);
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(spendable);
    }

    if (method == "getBalanceForAddress")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto address = str_param(p, "address");
        uint64_t unlocked = 0, locked = 0;
        const wallet_status_t st =
            wallet_get_balance_for_address(g_wallet, address.c_str(), &unlocked, &locked);
        if (st != 0)
        {
            return err_json(st);
        }
        json r;
        r["unlocked"] = unlocked;
        r["locked"] = locked;
        return ok_json(r);
    }

    if (method == "getBalancesJson")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return json_result(wallet_get_balances_json(g_wallet, &out, &len), out, len);
    }

    /* -------- addresses -------- */

    if (method == "getPrimaryAddress")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return string_result(wallet_get_primary_address(g_wallet, &out, &len), out, len);
    }

    if (method == "getAddressesJson")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return json_result(wallet_get_addresses_json(g_wallet, &out, &len), out, len);
    }

    /* -------- transactions -------- */

    if (method == "getTransactionsJson")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        const wallet_status_t st = wallet_get_transactions_json(
            g_wallet, u64_param(p, "startHeight"), u64_param(p, "endHeight"),
            bool_param(p, "includeUnconfirmed", true), &out, &len);
        return json_result(st, out, len);
    }

    if (method == "getTxPrivateKey")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto txHash = str_param(p, "txHash");
        char *out = nullptr;
        size_t len = 0;
        return string_result(
            wallet_get_tx_private_key(g_wallet, txHash.c_str(), &out, &len), out, len);
    }

    /* -------- send and sweep -------- */

    /* Both of these compute the transaction proof of work, which in a browser
       is seconds of CPU in this worker. getPowStatus reports progress while
       they run. */
    if (method == "sendBasic")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto dest = str_param(p, "destination");
        const auto paymentId = str_param(p, "paymentId");
        char *out = nullptr;
        size_t len = 0;
        const wallet_status_t st = wallet_send_basic(
            g_wallet, dest.c_str(), u64_param(p, "amount"),
            paymentId.empty() ? nullptr : paymentId.c_str(), &out, &len);
        return string_result(st, out, len);
    }

    if (method == "sendAdvancedJson")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto reqJson = str_param(p, "requestJson");
        char *out = nullptr;
        size_t len = 0;
        return json_result(
            wallet_send_advanced_json(g_wallet, reqJson.c_str(), &out, &len), out, len);
    }

    if (method == "sweepToAddress")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto dest = str_param(p, "destination");
        const auto paymentId = str_param(p, "paymentId");
        char *out = nullptr;
        size_t len = 0;
        const wallet_status_t st = wallet_sweep_to_address(
            g_wallet, dest.c_str(), paymentId.empty() ? nullptr : paymentId.c_str(),
            u64_param(p, "amountToSweep"), &out, &len);
        return json_result(st, out, len);
    }

    if (method == "estimateSweep")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        uint64_t txCount = 0, totalFee = 0;
        const wallet_status_t st =
            wallet_estimate_sweep(g_wallet, u64_param(p, "amountToSweep"), &txCount, &totalFee);
        if (st != 0)
        {
            return err_json(st);
        }
        json r;
        r["txCount"] = txCount;
        r["totalFee"] = totalFee;
        return ok_json(r);
    }

    /* -------- keys and seeds -------- */

    if (method == "getPrivateViewKey")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return string_result(wallet_get_private_view_key(g_wallet, &out, &len), out, len);
    }

    if (method == "getSpendKeysJson")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto address = str_param(p, "address");
        char *out = nullptr;
        size_t len = 0;
        return json_result(
            wallet_get_spend_keys_json(g_wallet, address.c_str(), &out, &len), out, len);
    }

    if (method == "getMnemonicSeed")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return string_result(wallet_get_mnemonic_seed(g_wallet, &out, &len), out, len);
    }

    if (method == "getMnemonicSeedForAddress")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto address = str_param(p, "address");
        char *out = nullptr;
        size_t len = 0;
        return string_result(
            wallet_get_mnemonic_seed_for_address(g_wallet, address.c_str(), &out, &len), out, len);
    }

    if (method == "isViewWallet")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        bool isView = false;
        const wallet_status_t st = wallet_is_view_wallet(g_wallet, &isView);
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(isView);
    }

    /* -------- password and export -------- */

    if (method == "changePassword")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto newPw = str_param(p, "newPassword");
        const wallet_status_t st = wallet_change_password(g_wallet, newPw.c_str());
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(true);
    }

    if (method == "exportJson")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return json_result(wallet_export_json(g_wallet, &out, &len), out, len);
    }

    /* -------- subwallets -------- */

    if (method == "addSubwallet")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        char *out = nullptr;
        size_t len = 0;
        return json_result(wallet_add_subwallet_json(g_wallet, &out, &len), out, len);
    }

    if (method == "importSubwalletFromKey")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto key = str_param(p, "privateSpendKey");
        char *out = nullptr;
        size_t len = 0;
        const wallet_status_t st = wallet_import_subwallet_from_key(
            g_wallet, key.c_str(), u64_param(p, "scanHeight"), &out, &len);
        return string_result(st, out, len);
    }

    if (method == "deleteSubwallet")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        const auto address = str_param(p, "address");
        const wallet_status_t st = wallet_delete_subwallet(g_wallet, address.c_str());
        if (st != 0)
        {
            return err_json(st);
        }
        return ok_json(true);
    }

    /* -------- integrated address (no wallet needed) -------- */

    if (method == "createIntegratedAddress")
    {
        const auto address = str_param(p, "address");
        const auto paymentId = str_param(p, "paymentId");
        char *out = nullptr;
        size_t len = 0;
        return string_result(
            wallet_create_integrated_address(address.c_str(), paymentId.c_str(), &out, &len),
            out, len);
    }

    /* -------- events -------- */

    if (method == "pollEvent")
    {
        if (!g_wallet)
        {
            return err_json(-1, "no wallet open");
        }
        uint32_t evType = WALLET_EVENT_NONE;
        char *out = nullptr;
        size_t len = 0;
        const wallet_status_t st =
            wallet_poll_event(g_wallet, u32_param(p, "timeoutMs", 100), &evType, &out, &len);
        if (st != 0)
        {
            return err_json(st);
        }
        json r;
        r["eventType"] = evType;
        if (out)
        {
            r["eventData"] = json::parse(out, nullptr, false);
            wallet_string_free(out);
        }
        else
        {
            r["eventData"] = nullptr;
        }
        return ok_json(r);
    }

    /* -------- transaction PoW -------- */

    if (method == "getPowStatus")
    {
        bool active = false;
        uint64_t elapsed = 0, nonces = 0;
        wallet_get_pow_status(&active, &elapsed, &nonces);
        json r;
        r["active"] = active;
        r["elapsedMs"] = elapsed;
        r["nonces"] = nonces;
        return ok_json(r);
    }

    if (method == "setScanCoinbase")
    {
        wallet_set_scan_coinbase(bool_param(p, "scan"));
        return ok_json(true);
    }

    /* Hand the transaction proof of work to a DeroGold-txpow-server instead of
       computing it in this worker, which is by far the slowest place to do it.
       An empty host turns it off again. */
    if (method == "setTxPowServer")
    {
        const auto host = str_param(p, "host");
        wallet_set_tx_pow_server(host.c_str(), u16_param(p, "port"), bool_param(p, "ssl"));
        return ok_json(true);
    }

    if (method == "testTxPowServer")
    {
        const auto host = str_param(p, "host");
        char *out = nullptr;
        size_t len = 0;
        const wallet_status_t st = wallet_test_tx_pow_server(
            host.c_str(), u16_param(p, "port"), bool_param(p, "ssl"), &out, &len);
        return json_result(st, out, len);
    }

    if (method == "testNode")
    {
        const auto host = str_param(p, "host");
        char *out = nullptr;
        size_t len = 0;
        const wallet_status_t st = wallet_test_node(
            host.c_str(), u16_param(p, "port"), bool_param(p, "ssl"), &out, &len);
        return json_result(st, out, len);
    }

    /* -------- browser storage bridge -------- */

    /* JS pushes a wallet file in before "open", and pulls it out after "save".
       Base64 because the transport is JSON. */
    if (method == "importFileData")
    {
        const auto filename = str_param(p, "filename");
        const auto b64 = str_param(p, "dataBase64");
        if (filename.empty() || b64.empty())
        {
            return err_json(-3, "importFileData requires filename and dataBase64");
        }

        const auto b64val = [](char c) -> int {
            if (c >= 'A' && c <= 'Z') return c - 'A';
            if (c >= 'a' && c <= 'z') return c - 'a' + 26;
            if (c >= '0' && c <= '9') return c - '0' + 52;
            if (c == '+') return 62;
            if (c == '/') return 63;
            return -1;
        };

        std::vector<char> decoded;
        decoded.reserve(b64.size() * 3 / 4);

        int val = 0;
        int bits = -8;

        for (const char c : b64)
        {
            const int v = b64val(c);
            if (v < 0)
            {
                continue; /* padding or whitespace */
            }
            val = (val << 6) | v;
            bits += 6;
            if (bits >= 0)
            {
                decoded.push_back(static_cast<char>((val >> bits) & 0xFF));
                bits -= 8;
            }
        }

        WasmFs::write(filename, decoded);
        return ok_json(true);
    }

    if (method == "exportFileData")
    {
        const auto filename = str_param(p, "filename");
        if (filename.empty())
        {
            return err_json(-3, "exportFileData requires filename");
        }

        const auto data = WasmFs::read(filename);
        if (data.empty())
        {
            return err_json(-1, "file not found in store: " + filename);
        }

        static const char b64table[] =
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

        std::string encoded;
        encoded.reserve(((data.size() + 2) / 3) * 4);

        for (size_t i = 0; i < data.size(); i += 3)
        {
            unsigned int n = (static_cast<unsigned char>(data[i]) << 16);
            if (i + 1 < data.size()) n |= (static_cast<unsigned char>(data[i + 1]) << 8);
            if (i + 2 < data.size()) n |= static_cast<unsigned char>(data[i + 2]);

            encoded += b64table[(n >> 18) & 0x3F];
            encoded += b64table[(n >> 12) & 0x3F];
            encoded += (i + 1 < data.size()) ? b64table[(n >> 6) & 0x3F] : '=';
            encoded += (i + 2 < data.size()) ? b64table[n & 0x3F] : '=';
        }

        json r;
        r["dataBase64"] = encoded;
        return ok_json(r);
    }

    if (method == "listFiles")
    {
        json arr = json::array();
        for (const auto &n : WasmFs::list())
        {
            arr.push_back(n);
        }
        return ok_json(arr);
    }

    return err_json(-2, "unknown method: " + method);
}

/* ------------------------------------------------------------------ */
/*  Entry point                                                        */
/* ------------------------------------------------------------------ */

extern "C"
{
    /*
     * Called from JavaScript:
     *   const resultPtr = Module._wallet_wasm_request(requestPtr);
     *   const resultStr = Module.UTF8ToString(resultPtr);
     *   Module._free(resultPtr);
     *
     * The returned pointer is heap allocated and the caller must free it.
     */
    char *wallet_wasm_request(const char *request_json)
    {
        if (!request_json || !request_json[0])
        {
            return err_json(-3, "empty request");
        }

        json req;

        try
        {
            req = json::parse(request_json);
        }
        catch (const std::exception &e)
        {
            return err_json(-3, std::string("invalid JSON: ") + e.what());
        }

        if (!has_key(req, "method") || !req["method"].is_string())
        {
            return err_json(-3, "missing 'method' field");
        }

        const std::string method = req["method"].get<std::string>();
        const json params = has_key(req, "params") ? req["params"] : json::object();

        /* Nothing may escape into the JS side as a C++ exception: it would
           unwind through the ccall and take the module with it. */
        try
        {
            return dispatch(method, params);
        }
        catch (const std::exception &e)
        {
            return err_json(-4, std::string("exception: ") + e.what());
        }
        catch (...)
        {
            return err_json(-4, "unknown exception");
        }
    }
}
