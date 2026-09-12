/*
 * wallet_bridge.js
 *
 * The page's side of the wallet. Installs a single global, DeroGoldWallet,
 * and keeps the worker that does the actual work out of sight.
 *
 *   await DeroGoldWallet.init({ wasmUrl: './wallet_wasm.js' })
 *   const json = await DeroGoldWallet.call('getSyncStatus', {})
 *
 * `call` resolves with the JSON *string* the module produced, because the
 * caller is Dart and handing it one string to decode is cheaper than
 * marshalling a JavaScript object across the interop boundary field by field.
 * The envelope is either
 *
 *   {"ok":true,"result":<value>}
 *   {"ok":false,"error":<int>,"errorMessage":"<text>"}
 *
 * and a rejected promise means the request never reached the wallet at all -
 * a different thing from the wallet refusing it, and worth telling apart.
 *
 * Loading a wallet out of IndexedDB and writing it back is handled inside the
 * worker, around the open, save and close calls, so nothing here has to
 * remember to persist. listWallets, loadWallet, persistWallet and
 * deleteWallet are exposed for the setup screen, which needs to show what is
 * stored before any wallet is open.
 */

(function (global) {
  'use strict';

  const DEFAULT_WASM_URL = './wallet_wasm.js';
  const DEFAULT_WORKER_URL = './wallet_worker.js';

  let worker = null;
  let initPromise = null;
  let nextId = 1;

  const pending = new Map();
  const eventListeners = [];

  function onWorkerMessage(e) {
    const msg = e.data || {};

    if (msg.type === 'event') {
      for (const fn of eventListeners) {
        try {
          fn(msg.eventType, msg.eventData);
        } catch (err) {
          /* A listener that throws must not stop the others. */
          console.error('DeroGoldWallet: event listener failed', err);
        }
      }
      return;
    }

    const entry = pending.get(msg.id);

    if (!entry) {
      return;
    }

    pending.delete(msg.id);

    if (msg.ok) {
      entry.resolve(msg.result);
    } else {
      entry.reject(new Error(msg.error || 'wallet request failed'));
    }
  }

  /* The worker dying takes every outstanding request with it. Failing them
     explicitly beats leaving the page waiting on promises that can never
     settle. */
  function onWorkerError(err) {
    const reason = new Error(
      'the wallet worker stopped: ' + ((err && (err.message || err.type)) || 'unknown error')
    );

    for (const [, entry] of pending) {
      entry.reject(reason);
    }

    pending.clear();
  }

  function post(message) {
    if (!worker) {
      return Promise.reject(new Error('DeroGoldWallet.init() has not been called'));
    }

    const id = nextId++;
    message.id = id;

    return new Promise((resolve, reject) => {
      pending.set(id, { resolve: resolve, reject: reject });
      worker.postMessage(message);
    });
  }

  const DeroGoldWallet = {
    /* Boots the worker and the WebAssembly module. Safe to call more than
       once; later calls wait on the first. */
    init(options) {
      if (initPromise) {
        return initPromise;
      }

      const opts = options || {};
      const wasmUrl = opts.wasmUrl || DEFAULT_WASM_URL;
      const workerUrl = opts.workerUrl || DEFAULT_WORKER_URL;

      initPromise = (async () => {
        /* The module is built with threads, which need SharedArrayBuffer,
           which the browser only grants a cross-origin isolated page. Saying
           so here turns a confusing failure deep inside the module into one
           sentence naming the two headers that are missing. */
        if (typeof SharedArrayBuffer === 'undefined' || global.crossOriginIsolated === false) {
          throw new Error(
            'This wallet needs a cross-origin isolated page. Serve it with ' +
              'Cross-Origin-Opener-Policy: same-origin and ' +
              'Cross-Origin-Embedder-Policy: require-corp.'
          );
        }

        worker = new Worker(workerUrl);
        worker.onmessage = onWorkerMessage;
        worker.onerror = onWorkerError;

        const result = await post({ type: 'init', wasmUrl: wasmUrl });

        if (!result || result.pthreads !== true) {
          /* The module refuses to build without threads, so this means a
             stale wallet_wasm.js is being served. */
          console.warn('DeroGoldWallet: the module reports no thread support; syncing will not work.');
        }

        /* Nothing arrives unless something is polling for it. */
        await post({ type: 'events', on: true, intervalMs: opts.eventIntervalMs || 1000 });

        return result;
      })();

      initPromise.catch(() => {
        /* Let a failed boot be retried rather than cached forever. */
        initPromise = null;
        if (worker) {
          worker.terminate();
          worker = null;
        }
      });

      return initPromise;
    },

    /* Calls a wallet method. `params` may be an object or a JSON string.
       Resolves with the JSON envelope as a string. */
    call(method, params) {
      let parsed = params;

      if (typeof params === 'string') {
        try {
          parsed = params.length ? JSON.parse(params) : {};
        } catch (err) {
          return Promise.reject(new Error('params is not valid JSON: ' + err.message));
        }
      }

      return post({ type: 'call', method: method, params: parsed || {} }).then((envelope) =>
        JSON.stringify(envelope)
      );
    },

    /* Wallet names held in this browser. */
    listWallets() {
      return post({ type: 'storage', op: 'list' });
    },

    /* IndexedDB -> module memory. The worker already does this for `open`;
       this is for a caller that wants to stage a wallet first. */
    loadWallet(name) {
      return post({ type: 'storage', op: 'load', name: name });
    },

    /* Module memory -> IndexedDB. Also done automatically after save and
       close. */
    persistWallet(name) {
      return post({ type: 'storage', op: 'persist', name: name });
    },

    deleteWallet(name) {
      return post({ type: 'storage', op: 'delete', name: name });
    },

    /* Rough storage usage for this origin, or null where unsupported. */
    storageEstimate() {
      return post({ type: 'storage', op: 'quota' });
    },

    /* fn(eventType, eventData). Returns a function that removes it.
       eventType: 1 = synced, 2 = transaction. */
    onEvent(fn) {
      eventListeners.push(fn);

      return () => {
        const i = eventListeners.indexOf(fn);
        if (i !== -1) {
          eventListeners.splice(i, 1);
        }
      };
    },

    /* Stops event polling and tears the worker down. The caller should close
       the wallet first, so its last save is written. */
    async shutdown() {
      if (!worker) {
        return;
      }

      try {
        await post({ type: 'events', on: false });
      } catch (err) {
        /* Going away regardless. */
      }

      worker.terminate();
      worker = null;
      initPromise = null;
      pending.clear();
    },
  };

  global.DeroGoldWallet = DeroGoldWallet;
})(typeof self !== 'undefined' ? self : this);
