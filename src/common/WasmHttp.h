// Copyright (c) 2018-2021, The DeroGold Developers
//
// Please see the included LICENSE file for more information.

#pragma once

#ifdef __EMSCRIPTEN__

#include <cstdint>
#include <string>

namespace Common
{
    namespace Wasm
    {
        /* An HTTP request from inside a browser, for the two places that would
           otherwise open a socket: the daemon client in Nigel and the Tx PoW
           client. cpp-httplib cannot work here - there are no sockets under
           WebAssembly - so the request goes out over XMLHttpRequest instead.
         *
         * Synchronously, because everything calling it is written to block
         * until an answer arrives, and unpicking that into callbacks would
         * mean rewriting the synchronizer. Browsers only allow a synchronous
         * request off the main thread, so this must be called from a worker,
         * which is where the wallet's threads already live.
         *
         * Returns the response body and writes the HTTP status through
         * `status`. A status of 0 means the request never completed: a
         * refused connection, a DNS failure, a timeout, or a CORS rejection,
         * which are not distinguishable from here by design.
         *
         * timeoutSeconds of 0 leaves the browser's own limit in place.
         */
        std::string syncRequest(
            const std::string &url,
            const std::string &method,
            const std::string *body,
            int &status,
            int timeoutSeconds = 0);
    } // namespace Wasm
} // namespace Common

#endif /* __EMSCRIPTEN__ */
