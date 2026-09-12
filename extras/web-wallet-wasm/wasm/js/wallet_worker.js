/*
 * wallet_worker.js
 *
 * The Web Worker the wallet runs in.
 *
 * Everything here blocks: the module's calls into the wallet are synchronous,
 * and so are the XMLHttpRequests it makes to reach the daemon - which a
 * browser only permits off the main thread. Running the module here is what
 * keeps the page responsive while a wallet syncs, and what makes the
 * synchronous transport legal in the first place.
 *
 * A classic worker, not a module worker, because Emscripten's MODULARIZE
 * output is a plain script that defines a factory, and importScripts is the
 * reliable way to load it in a worker.
 *
 * Protocol, over postMessage:
 *   in   { id, type: 'init',    wasmUrl }
 *   in   { id, type: 'call',    method, params }
 *   in   { id, type: 'storage', op, name }
 *   in   { id, type: 'events',  on, intervalMs }
 *   out  { id, ok: true, result }
 *   out  { id, ok: false, error }
 *   out  { type: 'event', eventType, eventData }
 */

'use strict';

let Module = null;
let ready = false;
let eventTimer = null;

/* The wallet the module currently has open, so a save can be written back to
   the right IndexedDB record without the page having to say which. */
let currentWallet = null;

/* Lifecycle calls (open, create, restore, save, close, delete) each await
   IndexedDB, and onmessage does not wait for one message to settle before
   starting the next. Without this, a close still writing its bytes could
   interleave with the open that follows it, and the wallet would either be
   refused as "already open" or saved over the one that replaced it. Read-only
   calls do not await and are left alone. */
let lifecycle = Promise.resolve();

function exclusive(fn) {
  const result = lifecycle.then(fn, fn);
  lifecycle = result.then(
    () => {},
    () => {}
  );
  return result;
}

/* ------------------------------------------------------------------ */
/*  Talking to the module                                              */
/* ------------------------------------------------------------------ */

/* One request in, one reply out. The module hands back a heap pointer that
   this has to free. */
function rawRequest(requestObject) {
  if (!Module) {
    throw new Error('the wallet module is not loaded');
  }

  const json = JSON.stringify(requestObject);
  const size = Module.lengthBytesUTF8(json) + 1;
  const inPtr = Module._malloc(size);

  if (!inPtr) {
    throw new Error('out of memory building the request');
  }

  let outPtr = 0;

  try {
    Module.stringToUTF8(json, inPtr, size);
    outPtr = Module._wallet_wasm_request(inPtr);
  } finally {
    Module._free(inPtr);
  }

  if (!outPtr) {
    throw new Error('the wallet module returned nothing');
  }

  let text;

  try {
    text = Module.UTF8ToString(outPtr);
  } finally {
    /* The C side allocated this and documents that the caller frees it. */
    Module._free(outPtr);
  }

  return JSON.parse(text);
}

/* Calls a method and unwraps the reply, throwing what the wallet reported.
   Returns the whole {ok, result} envelope so the page can forward it. */
function callMethod(method, params) {
  return rawRequest({ method: method, params: params || {} });
}

function callOrThrow(method, params) {
  const reply = callMethod(method, params);

  if (!reply || reply.ok !== true) {
    const err = new Error((reply && reply.errorMessage) || 'wallet call failed: ' + method);
    err.code = reply && reply.error;
    throw err;
  }

  return reply.result;
}

/* ------------------------------------------------------------------ */
/*  Moving wallet bytes between IndexedDB and the module               */
/* ------------------------------------------------------------------ */

function bytesToBase64(bytes) {
  let binary = '';
  const chunk = 0x8000; /* avoid blowing the argument limit on a big wallet */

  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
  }

  return btoa(binary);
}

function base64ToBytes(b64) {
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);

  for (let i = 0; i < binary.length; i++) {
    out[i] = binary.charCodeAt(i);
  }

  return out;
}

/* IndexedDB -> module memory. Must happen before "open". */
async function importWallet(name) {
  const bytes = await self.WalletStorage.load(name);

  if (!bytes) {
    return false;
  }

  callOrThrow('importFileData', { filename: name, dataBase64: bytesToBase64(bytes) });

  return true;
}

/* Module memory -> IndexedDB. Must happen after "save" or "close". */
async function persistWallet(name) {
  const result = callOrThrow('exportFileData', { filename: name });

  if (!result || !result.dataBase64) {
    return false;
  }

  await self.WalletStorage.save(name, base64ToBytes(result.dataBase64));

  return true;
}

/* ------------------------------------------------------------------ */
/*  Events                                                             */
/* ------------------------------------------------------------------ */

function startEvents(intervalMs) {
  stopEvents();

  eventTimer = setInterval(() => {
    if (!ready) {
      return;
    }

    try {
      /* A short timeout: this is a poll, and the wallet's own threads are
         what actually do the work. */
      const reply = callMethod('pollEvent', { timeoutMs: 0 });

      if (reply && reply.ok === true && reply.result && reply.result.eventType !== 0) {
        self.postMessage({
          type: 'event',
          eventType: reply.result.eventType,
          eventData: reply.result.eventData,
        });
      }
    } catch (err) {
      /* Polling must not be what takes the wallet down. */
    }
  }, intervalMs || 1000);
}

function stopEvents() {
  if (eventTimer) {
    clearInterval(eventTimer);
    eventTimer = null;
  }
}

/* ------------------------------------------------------------------ */
/*  Message handling                                                   */
/* ------------------------------------------------------------------ */

const OPENING_METHODS = ['open', 'create', 'restoreFromSeed', 'restoreFromKeys', 'restoreViewWallet'];

async function handle(msg) {
  if (msg.type === 'init') {
    const wasmUrl = msg.wasmUrl || './wallet_wasm.js';

    importScripts('./wallet_storage.js');
    importScripts(wasmUrl);

    if (typeof self.DeroGoldWalletModule !== 'function') {
      throw new Error('wallet module factory not found - is ' + wasmUrl + ' the MODULARIZE build?');
    }

    Module = await self.DeroGoldWalletModule({
      /* Resolve the .wasm and the pthread worker next to the glue script. */
      locateFile: (path) => new URL(path, new URL(wasmUrl, self.location.href)).href,
    });

    ready = true;

    let pthreads = false;

    try {
      pthreads = callOrThrow('isPthreadsEnabled', {}) === true;
    } catch (err) {
      /* Older module: assume the build is as configured. */
    }

    return { initialized: true, pthreads: pthreads };
  }

  if (!ready) {
    throw new Error('the wallet module is still starting');
  }

  if (msg.type === 'storage') {
    if (msg.op === 'list') {
      return self.WalletStorage.list();
    }
    if (msg.op === 'load') {
      return exclusive(() => importWallet(msg.name));
    }
    if (msg.op === 'persist') {
      return exclusive(() => persistWallet(msg.name));
    }
    if (msg.op === 'delete') {
      return exclusive(async () => {
        /* Drop the module's copy too, so a wallet deleted while open cannot
           be written back by a later save. */
        try {
          callMethod('deleteFile', { filename: msg.name });
        } catch (err) {
          /* It may not be loaded; that is not a failure to delete. */
        }
        if (currentWallet === msg.name) {
          currentWallet = null;
        }
        return self.WalletStorage.remove(msg.name);
      });
    }
    if (msg.op === 'quota') {
      return self.WalletStorage.quota();
    }
    throw new Error('unknown storage op: ' + msg.op);
  }

  if (msg.type === 'events') {
    if (msg.on) {
      startEvents(msg.intervalMs);
      return 'polling';
    }
    stopEvents();
    return 'stopped';
  }

  if (msg.type === 'call') {
    const method = msg.method;
    const params = msg.params || {};

    /* Lifecycle methods are serialised and carry the IndexedDB half with
       them, so the page never has to remember to persist. */
    if (OPENING_METHODS.indexOf(method) !== -1) {
      return exclusive(async () => {
        if (method === 'open' && params.filename) {
          await importWallet(params.filename);
        }

        const reply = callMethod(method, params);

        if (reply && reply.ok === true) {
          currentWallet = params.filename || null;

          /* A newly created or restored wallet only exists in memory until
             this runs. */
          if (currentWallet && method !== 'open') {
            await persistWallet(currentWallet);
          }
        }

        return reply;
      });
    }

    if (method === 'save' || method === 'close') {
      return exclusive(async () => {
        const name = currentWallet;
        const reply = callMethod(method, params);

        if (reply && reply.ok === true && name) {
          await persistWallet(name);

          if (method === 'close') {
            currentWallet = null;
            stopEvents();
          }
        }

        return reply;
      });
    }

    if (method === 'deleteFile') {
      return exclusive(async () => {
        const reply = callMethod(method, params);
        if (params.filename) {
          await self.WalletStorage.remove(params.filename);
          if (currentWallet === params.filename) {
            currentWallet = null;
          }
        }
        return reply;
      });
    }

    /* Everything else runs straight through: it is synchronous inside the
       module and touches no storage. */
    return callMethod(method, params);
  }

  throw new Error('unknown message type: ' + msg.type);
}

self.onmessage = async (e) => {
  const msg = e.data || {};

  try {
    const result = await handle(msg);
    self.postMessage({ id: msg.id, ok: true, result: result });
  } catch (err) {
    self.postMessage({ id: msg.id, ok: false, error: (err && err.message) || String(err) });
  }
};
