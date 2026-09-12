/*
 * wasm_fs_bridge.h
 *
 * The wallet's "filesystem" in a browser build.
 *
 * There is no filesystem to write to, so a wallet file is a byte array in an
 * in-memory map here, and the JavaScript side moves those bytes in and out of
 * IndexedDB through the importFileData / exportFileData / listFiles methods in
 * wallet_wasm_exports.cpp. The wallet backend itself is unchanged: its
 * std::ifstream / std::ofstream paths are compiled out under __EMSCRIPTEN__ and
 * call these instead, so the file it reads and writes is byte for byte the
 * same encrypted wallet a desktop build produces.
 *
 *   C++ (WASM)  <->  this map  <->  JS IndexedDB (persistence)
 *
 * Persistence is deliberately the JS side's job: IndexedDB is asynchronous and
 * everything here is called from synchronous wallet code that cannot wait on a
 * promise.
 */

#pragma once

#ifdef __EMSCRIPTEN__

#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace WasmFs
{
    /* In a pthreads build the wallet's own threads reach these, so every
       accessor takes the lock. */
    inline std::mutex &mutex()
    {
        static std::mutex m;
        return m;
    }

    inline std::map<std::string, std::vector<char>> &store()
    {
        static std::map<std::string, std::vector<char>> s;
        return s;
    }

    inline bool exists(const std::string &filename)
    {
        std::lock_guard<std::mutex> lk(mutex());
        return store().count(filename) > 0;
    }

    /* The file's bytes, or an empty vector when there is no such file. A real
       wallet is never empty, so callers can treat the two as the same. */
    inline std::vector<char> read(const std::string &filename)
    {
        std::lock_guard<std::mutex> lk(mutex());
        const auto it = store().find(filename);
        if (it != store().end())
        {
            return it->second;
        }
        return {};
    }

    inline void write(const std::string &filename, const char *data, size_t len)
    {
        std::lock_guard<std::mutex> lk(mutex());
        store()[filename] = std::vector<char>(data, data + len);
    }

    inline void write(const std::string &filename, const std::vector<char> &data)
    {
        std::lock_guard<std::mutex> lk(mutex());
        store()[filename] = data;
    }

    /* True when the file existed. */
    inline bool remove(const std::string &filename)
    {
        std::lock_guard<std::mutex> lk(mutex());
        return store().erase(filename) > 0;
    }

    inline std::vector<std::string> list()
    {
        std::lock_guard<std::mutex> lk(mutex());
        std::vector<std::string> names;
        for (const auto &kv : store())
        {
            names.push_back(kv.first);
        }
        return names;
    }
} // namespace WasmFs

#endif /* __EMSCRIPTEN__ */
