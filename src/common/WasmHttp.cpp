// Copyright (c) 2018-2021, The DeroGold Developers
//
// Please see the included LICENSE file for more information.

#include <common/WasmHttp.h>

/* Everything in this file is browser only; it compiles to nothing elsewhere. */
#ifdef __EMSCRIPTEN__

#include <cstdlib>
#include <emscripten.h>

namespace
{
    /* Returns a NUL terminated response body the caller must free(), or null
       if it could not allocate one. The status goes through statusOut. */
    EM_JS(char *, derogoldSyncXhr, (const char *url, const char *method, const char *body, int timeoutMs, int *statusOut), {
        var urlStr = UTF8ToString(url);
        var methodStr = UTF8ToString(method);
        var bodyStr = body ? UTF8ToString(body) : null;

        var status = 0;
        var text = "";

        try
        {
            var xhr = new XMLHttpRequest();

            /* false = synchronous. Only legal off the main thread, which is
               where every caller runs. */
            xhr.open(methodStr, urlStr, false);

            if (timeoutMs > 0)
            {
                /* Some browsers throw on this for a synchronous request even
                   in a worker. The request is still fine without it, so a
                   refusal here must not lose it. */
                try
                {
                    xhr.timeout = timeoutMs;
                }
                catch (ignored)
                {
                }
            }

            if (bodyStr !== null)
            {
                xhr.setRequestHeader("Content-Type", "application/json");
            }

            xhr.send(bodyStr);

            status = xhr.status;
            text = xhr.responseText || "";
        }
        catch (e)
        {
            /* A throw is a network, timeout or CORS failure. Status stays 0,
               which every caller reads as "did not reach the server". */
            status = 0;
            text = "";
        }

        var len = lengthBytesUTF8(text) + 1;
        var ptr = _malloc(len);

        if (!ptr)
        {
            HEAP32[statusOut >> 2] = status;
            return 0;
        }

        stringToUTF8(text, ptr, len);

        /* Written after _malloc, and through the global HEAP32 rather than a
           reference taken earlier: growing the heap replaces these views, and
           anything captured before the allocation is detached by the time we
           get here. */
        HEAP32[statusOut >> 2] = status;

        return ptr;
    });
} // namespace

namespace Common
{
    namespace Wasm
    {
        std::string syncRequest(
            const std::string &url,
            const std::string &method,
            const std::string *body,
            int &status,
            const int timeoutSeconds)
        {
            status = 0;

            char *raw = derogoldSyncXhr(
                url.c_str(),
                method.c_str(),
                body ? body->c_str() : nullptr,
                timeoutSeconds > 0 ? timeoutSeconds * 1000 : 0,
                &status);

            std::string response;

            if (raw)
            {
                response = raw;
                free(raw);
            }

            return response;
        }
    } // namespace Wasm
} // namespace Common

#endif /* __EMSCRIPTEN__ */
