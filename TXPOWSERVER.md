# Transaction PoW Server

Every DeroGold transaction mined at height 2,370,000 or above carries a small
proof of work: the wallet appends a nonce to the transaction extra and searches
until the `cn_turtle_lite_slow_hash_v2` hash of the unsigned transaction prefix
meets difficulty 17,000. Unlike WrkzCoin's, the difficulty does not depend on
the transaction's shape — a fusion transaction with ninety outputs and a
one-input payment are held to the same number — and there is no fee that buys
a way past it. A node rejects a transaction that arrives without one.

On a desktop that search takes a few seconds. On a phone it takes longer, and
in a single-threaded browser wallet it is impractical.
`DeroGold-txpow-server` moves the search to a machine that is good at it.

## What the server does and does not see

The proof of work is computed over the transaction prefix *before* the ring
signatures are made, so the server receives exactly the bytes the daemon will
see at broadcast a few seconds later: key images, ring member indexes, output
amounts and one-time keys, and the extra field. It never sees a key, a seed or
a signature, it cannot alter the transaction because the wallet only accepts
8 nonce bytes back and re-verifies them with one hash, and it cannot spend
anything. The worst a bad server can do is waste the wallet's time, after
which the wallet computes the proof itself.

Run the server where the wallet's remote node already runs and nothing new is
learned by anyone. A third-party server is one more party that learns the
sender's IP address and transaction shortly before broadcast.

## Running it

```
DeroGold-txpow-server --bind-ip 0.0.0.0 --bind-port 17870 --threads 8
```

| Flag | Default | Meaning |
|---|---|---|
| `--bind-ip` | `127.0.0.1` | Interface to listen on. Use `0.0.0.0` or `::` for remote wallets. |
| `--bind-port` | `17870` | TCP port. |
| `--bind-ipv6-address` | off | Second listener on this IPv6 address, same port. |
| `--trusted-proxy` | none | Address of a reverse proxy in front of the server; see below. Repeat or comma-separate for several. |
| `--threads` | all hardware threads | Hashing threads. All of them work on one job at a time. |
| `--rate-limit` | `60` | Requests per minute from one client address. `0` disables. |
| `--max-jobs-per-minute` | `120` | Jobs accepted per minute across all clients. `0` disables. |
| `--max-queue` | `64` | Jobs allowed to wait for the workers before new ones get `503`. |
| `--max-difficulty` | `1000000` | Refuse anything harder than this. Only matters if the network raises its difficulty. |
| `--max-wait-ms` | `30000` | Longest a request may be held open waiting for its result. |
| `--job-timeout` | `600` | Seconds after which an uncollected queued job is dropped. |
| `--result-ttl` | `300` | Seconds a finished result stays available for polling. |
| `--api-key` | none | Require this value in the `X-API-KEY` header. |
| `--enable-cors` | none | `Access-Control-Allow-Origin` value. A browser wallet needs this. |
| `--log-level` | `info` | `trace`, `debug`, `info`, `warning`, `fatal` or `disabled`. |
| `--log-file` | none | Also append log lines to this file. |

There is no service wrapper. On Linux a systemd unit or pm2 does the job; on
Windows use Task Scheduler or NSSM.

### Behind a reverse proxy (nginx, HTTPS)

The server speaks plain HTTP. For HTTPS, put it behind the reverse proxy that
already terminates TLS for the node. Two things matter:

- **Tell the server who the proxy is.** Every request then arrives from the
  proxy's address, so without `--trusted-proxy` the per-address rate limit
  would treat all wallets as one client. With it, requests from that address
  are attributed to the client named in `X-Real-IP` (preferred) or the last
  entry of `X-Forwarded-For`. Requests from any other address keep their real
  address, so the headers cannot be forged by a direct client.
- **Let the proxy hold a request open** for at least the long-poll length.
  The wallet client asks for 20 seconds; the server caps it at `--max-wait-ms`.

```
DeroGold-txpow-server --bind-ip 127.0.0.1 --bind-port 17870 --trusted-proxy 127.0.0.1
```

```nginx
server {
    listen 443 ssl;
    server_name node.example.com;
    # ssl_certificate / ssl_certificate_key as for the node

    # Served from a sub-path. The trailing slash on proxy_pass strips the
    # prefix, so the server keeps seeing /pow, /stats and /health.
    location /txpow/ {
        proxy_pass         http://127.0.0.1:17870/;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 90s;
        proxy_buffering    off;
    }
}
```

A wallet then points at `node.example.com/txpow` on port `443` with SSL on.
The host field also accepts a full URL such as
`https://node.example.com/txpow`, in which case the scheme decides SSL.
Serving from the root (`location / { proxy_pass http://127.0.0.1:17870; }`)
works the same with a plain host name.

CORS for a browser wallet can come either from `--enable-cors` on the server or
from `add_header` directives in nginx; do not do both, or the browser sees
the header twice and rejects it.

## Protocol

All bodies are JSON. Every job reply has a `status` of `done`, `pending`,
`cancelled` or `error`.

`POST /pow`

```json
{ "prefix": "<hex of the serialized transaction prefix>", "wait_ms": 20000, "height": 2900000 }
```

The prefix must already end with the PoW tag byte `0x04` followed by 8 nonce
bytes (the wallet zero-fills them). `wait_ms` is optional and capped at
`--max-wait-ms`; the request is held open that long waiting for a result.
`height` is optional and only decides whether any proof of work is required at
all — below 2,370,000 the server refuses the job as unnecessary.

Reply while the job is queued or running (HTTP 200):

```json
{ "status": "pending", "job_id": "…32 hex…", "state": "running", "difficulty": 17000, "hashes": 12800, "elapsed_ms": 3100 }
```

Reply once it is solved (HTTP 200):

```json
{ "status": "done", "job_id": "…", "nonce": "3a9f1c0000000000", "difficulty": 17000, "hashes": 17424, "elapsed_ms": 4020 }
```

`nonce` is the 8 bytes to copy over the trailing 8 bytes of the prefix, in
that byte order. The wallet verifies the hash against the difficulty before it
signs.

Refusals: `400` with `{"status":"error","error":"…"}` for a prefix that does
not parse, is not canonically serialized, has no inputs or outputs, spends
less than it creates, carries an unreasonable ring size, lacks the nonce tag,
or is above `--max-difficulty`; `401` when the API key is missing or wrong;
`429` when a client or the server as a whole is over its per-minute limit;
`503` when the queue is full.

`GET /pow/<job_id>?wait_ms=20000` returns the same job reply, `404` for an
unknown or expired job.

`DELETE /pow/<job_id>` cancels a queued or running job.

`GET /stats` returns counters since start-up: jobs received, accepted,
completed, failed, cancelled, expired and rejected by reason; total hashes,
busy time and average hash rate; average and worst solve time; queue depth
and the shape of the job currently running (never its id, which would let a
reader cancel it); HTTP request counts; the two limits a client can act on
(`max_difficulty`, `max_wait_ms`); and the version. It deliberately does not
describe the deployment: bind addresses, trusted proxies, rate limits, the
CORS origin and whether an API key is required stay in the start-up banner
and the operator's command line.

`GET /health` is outside the API key and rate limit and returns queue depth
and capacity, for load balancers.

## Wallet side

`degwallet`, `wallet-api` and `DeroGold-service` always compute the proof of
work on their own CPU, and no command line flag changes that.

The desktop wallet under `extras/desktop-wallet` has a **Transaction PoW
Server** section in Settings: a switch, host, port, SSL, a *Test* button and
*Apply*. The switch is **off by default**, so it too computes locally until
someone turns it on; the fields come prefilled with the project's public
server, `dego-txpow-rpc.0z.network` on port 80 without SSL, so enabling it is
one switch. *Test* calls `/health` over the same client path a transaction
would use and reports latency, thread count and queue occupancy without saving
anything.

The client half lives in `src/nigel/TxPowClient.h`.
`TxPowClient::configure(host, port, ssl)` turns it on for the process — an
empty host turns it off again — and `probe()` is what *Test* calls. For
embedders, the C API exposes `wallet_set_tx_pow_server(host, port, ssl)` and
`wallet_test_tx_pow_server(...)`.

When a server is configured, the wallet asks it first and waits up to two
minutes for an answer; if the server is unreachable, refuses the job, times
out or returns a nonce that does not verify, the wallet computes the proof on
its own CPU as before. A build without OpenSSL logs a warning and computes
locally when SSL is requested.
