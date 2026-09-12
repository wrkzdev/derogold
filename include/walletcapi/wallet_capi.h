// Copyright (c) 2018-2026, The DeroGold Developers
// Copyright (c) 2018-2026, The WrkzCoin developers
//
// Please see the included LICENSE file for more information.

/* A C interface to the DeroGold wallet backend, for front-ends that cannot
   link C++ - the Flutter wallets under extras/ reach it through dart:ffi.
 *
 * Conventions, which hold for every function here:
 *
 *   - The return is a wallet_status_t, which is an ErrorCode from
 *     src/errors/Errors.h. SUCCESS is 0. wallet_error_code_to_string() turns
 *     one into a sentence, and wallet_last_error_message() carries the detail
 *     the backend gave for the most recent failure on this thread.
 *   - Every `char **out_*` is a heap buffer the caller owns and must release
 *     with wallet_string_free(). It is NUL terminated, and *out_len is its
 *     length without the terminator.
 *   - A wallet_handle_t is not thread safe against itself: one call at a time
 *     per wallet. Different wallets are independent.
 *   - Nothing here blocks on the network for long except where its comment
 *     says so; those belong off the UI thread.
 */

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define WALLET_CAPI_EXPORT __declspec(dllexport)
#else
#define WALLET_CAPI_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wallet_handle wallet_handle_t;
typedef int32_t wallet_status_t;

enum
{
    WALLET_CAPI_API_VERSION = 1
};

enum
{
    WALLET_EVENT_NONE = 0,
    WALLET_EVENT_SYNCED = 1,
    WALLET_EVENT_TRANSACTION = 2
};

WALLET_CAPI_EXPORT uint32_t wallet_capi_api_version(void);
WALLET_CAPI_EXPORT const char *wallet_capi_version_string(void);

WALLET_CAPI_EXPORT wallet_status_t wallet_open(
    const char *filename,
    const char *password,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet);

WALLET_CAPI_EXPORT wallet_status_t wallet_create(
    const char *filename,
    const char *password,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet);

WALLET_CAPI_EXPORT wallet_status_t wallet_restore_from_seed(
    const char *mnemonic_seed,
    const char *filename,
    const char *password,
    uint64_t scan_height,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet);

WALLET_CAPI_EXPORT wallet_status_t wallet_restore_from_keys(
    const char *private_spend_key_hex,
    const char *private_view_key_hex,
    const char *filename,
    const char *password,
    uint64_t scan_height,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet);

WALLET_CAPI_EXPORT wallet_status_t wallet_restore_view(
    const char *private_view_key_hex,
    const char *address,
    const char *filename,
    const char *password,
    uint64_t scan_height,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl,
    uint32_t sync_threads,
    wallet_handle_t **out_wallet);

WALLET_CAPI_EXPORT wallet_status_t wallet_delete_file(const char *filename);

WALLET_CAPI_EXPORT void wallet_close(wallet_handle_t *wallet);

WALLET_CAPI_EXPORT wallet_status_t wallet_save(wallet_handle_t *wallet);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_sync_status(
    wallet_handle_t *wallet,
    uint64_t *out_wallet_height,
    uint64_t *out_local_daemon_height,
    uint64_t *out_network_height);

/* Heights, peers, hashrate, and what the wallet knows about why syncing may
   not be progressing: syncError, and the fork counters, which move when a
   reorganisation withdraws transactions already reported as confirmed. */
WALLET_CAPI_EXPORT wallet_status_t wallet_get_status_json(
    wallet_handle_t *wallet,
    char **out_json,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_daemon_online(wallet_handle_t *wallet, bool *out_online);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_node_info_json(
    wallet_handle_t *wallet,
    char **out_json,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_swap_node(
    wallet_handle_t *wallet,
    const char *daemon_host,
    uint16_t daemon_port,
    bool daemon_ssl);

/* Rescans the wallet from scan_height. A rescan from far below the current
   height walks most of the chain and can take hours - worth confirming with
   the user first, as the CLI wallet does below WalletConfig::slowRescanHeight. */
WALLET_CAPI_EXPORT wallet_status_t wallet_reset(
    wallet_handle_t *wallet,
    uint64_t scan_height,
    uint64_t timestamp);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_transactions_json(
    wallet_handle_t *wallet,
    uint64_t start_height,
    uint64_t end_height_exclusive,
    bool include_unconfirmed,
    char **out_json,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_primary_address(
    wallet_handle_t *wallet,
    char **out_address,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_addresses_json(
    wallet_handle_t *wallet,
    char **out_json,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_total_balance(
    wallet_handle_t *wallet,
    uint64_t *out_unlocked,
    uint64_t *out_locked);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_balance_for_address(
    wallet_handle_t *wallet,
    const char *address,
    uint64_t *out_unlocked,
    uint64_t *out_locked);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_balances_json(
    wallet_handle_t *wallet,
    char **out_json,
    size_t *out_len);

/* The balance a transaction can actually be built from right now: the
   unlocked balance minus inputs too small or too incomplete to spend. This is
   the figure a "send everything" button has to work from, not the unlocked
   balance. */
WALLET_CAPI_EXPORT wallet_status_t wallet_get_spendable_balance(
    wallet_handle_t *wallet,
    uint64_t *out_spendable);

/* Sends `amount` to one destination. Every transaction carries a proof of
   work, so this takes seconds of CPU unless a Tx PoW server is configured
   (see wallet_set_tx_pow_server); call it off the UI thread. */
WALLET_CAPI_EXPORT wallet_status_t wallet_send_basic(
    wallet_handle_t *wallet,
    const char *destination,
    uint64_t amount,
    const char *payment_id,
    char **out_tx_hash,
    size_t *out_len);

/* request_json: {"destinations":[{"address":...,"amount":N}], "mixin":N?,
   "fee":N?, "paymentID":"..."?, "sourceAddresses":[...]?,
   "changeAddress":"..."?, "unlockTime":N?, "extra":"<hex>"?}
   out_result_json: {"transactionHash":"...","fee":N,"mixin":N,"defaultMixin":N} */
WALLET_CAPI_EXPORT wallet_status_t wallet_send_advanced_json(
    wallet_handle_t *wallet,
    const char *request_json,
    char **out_result_json,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_tx_private_key(
    wallet_handle_t *wallet,
    const char *tx_hash_hex,
    char **out_tx_private_key_hex,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_private_view_key(
    wallet_handle_t *wallet,
    char **out_private_view_key_hex,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_spend_keys_json(
    wallet_handle_t *wallet,
    const char *address,
    char **out_result_json,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_mnemonic_seed(
    wallet_handle_t *wallet,
    char **out_mnemonic_seed,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_get_mnemonic_seed_for_address(
    wallet_handle_t *wallet,
    const char *address,
    char **out_mnemonic_seed,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_is_view_wallet(wallet_handle_t *wallet, bool *out_is_view_wallet);

WALLET_CAPI_EXPORT wallet_status_t wallet_change_password(wallet_handle_t *wallet, const char *new_password);

/* The whole wallet as a JSON string. The caller writes it wherever it wants;
   nothing here touches the filesystem. */
WALLET_CAPI_EXPORT wallet_status_t wallet_export_json(
    wallet_handle_t *wallet,
    char **out_json,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_add_subwallet_json(
    wallet_handle_t *wallet,
    char **out_result_json,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_import_subwallet_from_key(
    wallet_handle_t *wallet,
    const char *private_spend_key_hex,
    uint64_t scan_height,
    char **out_address,
    size_t *out_len);

WALLET_CAPI_EXPORT wallet_status_t wallet_delete_subwallet(wallet_handle_t *wallet, const char *address);

WALLET_CAPI_EXPORT wallet_status_t wallet_create_integrated_address(
    const char *address,
    const char *payment_id,
    char **out_integrated_address,
    size_t *out_len);

/* Sends amount_to_sweep (0 = everything spendable) to destination, splitting
   it over as many transactions as it takes, with the fees coming out of the
   amount rather than on top - so the wallet never has to keep a balance back
   to pay for the sweep. Each transaction carries its own proof of work, so a
   sweep of several transactions takes a while; call it off the UI thread.
 *
 * Unlike the CLI's sweep this never waits for the change of a transaction it
 * just sent to unlock: it stops and reports what it managed to send, leaving
 * the caller to sweep again once the change is back. out_result_json:
 * {"sent":N,"remaining":N,"transactions":N,
 *  "results":[{"txHash":"..."} | {"error":N,"errorMessage":"..."}, ...]} */
WALLET_CAPI_EXPORT wallet_status_t wallet_sweep_to_address(
    wallet_handle_t *wallet,
    const char *destination,
    const char *payment_id,
    uint64_t amount_to_sweep,
    char **out_result_json,
    size_t *out_len);

/* What a sweep would cost, without sending anything: how many transactions it
   would take and the total fee. */
WALLET_CAPI_EXPORT wallet_status_t wallet_estimate_sweep(
    wallet_handle_t *wallet,
    uint64_t amount_to_sweep,
    uint64_t *out_tx_count,
    uint64_t *out_total_fee);

WALLET_CAPI_EXPORT void wallet_string_free(char *p);

/* Waits up to timeout_ms for the next event on this wallet. out_event_type is
   one of the WALLET_EVENT_ constants; WALLET_EVENT_NONE with SUCCESS means
   nothing arrived in time and out_event_json is left alone. */
WALLET_CAPI_EXPORT wallet_status_t wallet_poll_event(
    wallet_handle_t *wallet,
    uint32_t timeout_ms,
    uint32_t *out_event_type,
    char **out_event_json,
    size_t *out_len);

/* Transaction proof-of-work progress. Non-blocking and lock-free, so it is
   safe to poll from the UI while a send is running on another thread.
   Process-wide: one send at a time is the assumption. */
WALLET_CAPI_EXPORT void wallet_get_pow_status(bool *out_active, uint64_t *out_elapsed_ms, uint64_t *out_nonces);

WALLET_CAPI_EXPORT const char *wallet_error_code_to_string(wallet_status_t code);
WALLET_CAPI_EXPORT const char *wallet_last_error_message(void);
WALLET_CAPI_EXPORT void wallet_clear_last_error_message(void);
WALLET_CAPI_EXPORT wallet_status_t wallet_set_log_level(const char *level);
WALLET_CAPI_EXPORT wallet_status_t wallet_take_logs_json(char **out_json, size_t *out_len);
WALLET_CAPI_EXPORT wallet_status_t wallet_clear_logs(void);

/* Whether to scan coinbase (miner reward) transactions. Off by default, as
   most wallets never receive one. Turning it on for a wallet that already
   synced without it needs a rescan to find what was skipped. */
WALLET_CAPI_EXPORT void wallet_set_scan_coinbase(bool scan);

/* Route the transaction proof of work through an external PoW server
   (DeroGold-txpow-server) before falling back to this device's CPU. Applies to
   every wallet opened in this process. An empty host or a zero port turns it
   off again. The host may carry a scheme and a path ("https://node/txpow")
   for a server behind a reverse proxy; the scheme then overrides `ssl`. The
   wallet re-verifies every nonce the server returns, so a bad or slow server
   only ever costs time. See TXPOWSERVER.md. */
WALLET_CAPI_EXPORT void wallet_set_tx_pow_server(const char *host, uint16_t port, bool ssl);

/* Checks a Tx PoW server without changing the configuration: one GET /health
   over the same client path a transaction would use, so it also catches a
   build without SSL support. Blocks for up to ~15 seconds when the host does
   not answer; call it off the UI thread. Always returns SUCCESS with a JSON
   object in out_json: {"ok":true,"url":...,"latency_ms":N,"threads":N,
   "queue":N,"capacity":N} or {"ok":false,"url":...,"error":"..."}. */
WALLET_CAPI_EXPORT wallet_status_t wallet_test_tx_pow_server(
    const char *host,
    uint16_t port,
    bool ssl,
    char **out_json,
    size_t *out_len);

/* Checks a daemon without pointing the wallet at it: one /info request over a
   throwaway connection, so nothing about the open wallet changes. Switching
   nodes is the one setting that can leave a wallet unable to sync with nothing
   on screen to explain it, and a daemon that answers but is behind is as bad
   as one that does not answer - hence the heights. Blocks for up to ~10
   seconds; call it off the UI thread. Always returns SUCCESS with a JSON
   object in out_json: {"ok":true,"url":...,"latency_ms":N,"height":N,
   "networkHeight":N,"peerCount":N,"synced":bool} or
   {"ok":false,"url":...,"error":"..."}. */
WALLET_CAPI_EXPORT wallet_status_t wallet_test_node(
    const char *host,
    uint16_t port,
    bool ssl,
    char **out_json,
    size_t *out_len);

#ifdef __cplusplus
}
#endif
