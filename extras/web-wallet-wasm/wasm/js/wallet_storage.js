/*
 * wallet_storage.js
 *
 * Where a browser wallet actually lives between visits.
 *
 * The WebAssembly module keeps the wallet file in memory (see
 * wasm_fs_bridge.h) because everything that touches it is synchronous wallet
 * code that cannot wait on a promise. IndexedDB is asynchronous, so moving
 * those bytes in and out is this file's job, and the worker does it around the
 * open and save calls rather than underneath them.
 *
 * The stored value is the encrypted wallet file byte for byte - the same
 * bytes a desktop build writes - so a wallet saved here can be exported and
 * opened by the CLI wallet, and one made by the CLI can be imported here.
 *
 * Loaded with importScripts() by the worker, so it installs itself on `self`
 * rather than exporting an ES module.
 */

(function (global) {
  'use strict';

  const DB_NAME = 'derogold-wallet';
  const DB_VERSION = 1;
  const STORE = 'wallets';

  let dbPromise = null;

  function openDb() {
    if (dbPromise) {
      return dbPromise;
    }

    dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);

      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(STORE)) {
          /* Keyed by wallet name; the value is a Uint8Array of file bytes. */
          db.createObjectStore(STORE);
        }
      };

      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('could not open IndexedDB'));
      request.onblocked = () => reject(new Error('IndexedDB is blocked by another tab'));
    });

    /* A failed open must not be cached, or every later call fails with it. */
    dbPromise.catch(() => {
      dbPromise = null;
    });

    return dbPromise;
  }

  function tx(mode, fn) {
    return openDb().then(
      (db) =>
        new Promise((resolve, reject) => {
          const transaction = db.transaction(STORE, mode);
          const store = transaction.objectStore(STORE);

          let result;

          try {
            result = fn(store);
          } catch (err) {
            reject(err);
            return;
          }

          transaction.oncomplete = () => resolve(result && result.__request ? result.__request.result : result);
          transaction.onerror = () => reject(transaction.error || new Error('IndexedDB transaction failed'));
          transaction.onabort = () => reject(transaction.error || new Error('IndexedDB transaction aborted'));
        })
    );
  }

  /* Wraps a request so tx() can hand back its result once the transaction
     commits, rather than racing it. */
  function request(req) {
    return { __request: req };
  }

  const WalletStorage = {
    /* Names of every wallet held in this browser. */
    list() {
      return tx('readonly', (store) => request(store.getAllKeys())).then((keys) =>
        (keys || []).map((k) => String(k))
      );
    },

    /* The wallet's bytes as a Uint8Array, or null when there is no such
       wallet. */
    load(name) {
      return tx('readonly', (store) => request(store.get(name))).then((value) => {
        if (!value) {
          return null;
        }
        if (value instanceof Uint8Array) {
          return value;
        }
        if (value instanceof ArrayBuffer) {
          return new Uint8Array(value);
        }
        /* Older records, or a structured clone that came back as a plain
           array. */
        return new Uint8Array(value);
      });
    },

    /* Stores the wallet, replacing any wallet of the same name. */
    save(name, bytes) {
      const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);

      /* Copy rather than store a view into the WASM heap: that memory is
         reused the moment this returns, and a view of it would be handed to
         IndexedDB as a window onto whatever lands there next. */
      const copy = new Uint8Array(data.length);
      copy.set(data);

      return tx('readwrite', (store) => request(store.put(copy, name))).then(() => true);
    },

    remove(name) {
      return tx('readwrite', (store) => request(store.delete(name))).then(() => true);
    },

    exists(name) {
      return tx('readonly', (store) => request(store.getKey(name))).then((key) => key !== undefined);
    },

    /* Roughly how much space the browser has given this origin, for the
       settings screen. Not every browser implements it. */
    quota() {
      if (!global.navigator || !navigator.storage || !navigator.storage.estimate) {
        return Promise.resolve(null);
      }
      return navigator.storage.estimate().then(
        (e) => ({ usage: e.usage || 0, quota: e.quota || 0 }),
        () => null
      );
    },
  };

  global.WalletStorage = WalletStorage;
})(typeof self !== 'undefined' ? self : this);
