// Copyright (c) 2018-2021, The DeroGold Developers
// Copyright (c) 2012-2017, The CryptoNote developers, The Bytecoin developers
// Copyright (c) 2018-2019, The TurtleCoin Developers
//
// Please see the included LICENSE file for more information.

#pragma once

#include <cstddef>
#include <cstdint>
#include <functional>
#include <queue>
#include <stack>

/* __WORDSIZE: glibc defines it via <bits/wordsize.h>, musl provides it in
   <bits/reg.h>, bionic has neither - it defines __WORDSIZE in <sys/cdefs.h>,
   which the standard headers above have already pulled in. Asking bionic for
   <bits/reg.h> is a fatal error, and this guard used to catch only glibc. */
#if !defined(__GLIBC__) && !defined(__BIONIC__)

#include <bits/reg.h>

#endif

namespace System
{
    struct NativeContextGroup;

    struct NativeContext
    {
        void *ucontext;
        void *stackPtr;
        bool interrupted;
        bool inExecutionQueue;
        NativeContext *next;
        NativeContextGroup *group;
        NativeContext *groupPrev;
        NativeContext *groupNext;
        std::function<void()> procedure;
        std::function<void()> interruptProcedure;
    };

    struct NativeContextGroup
    {
        NativeContext *firstContext;
        NativeContext *lastContext;
        NativeContext *firstWaiter;
        NativeContext *lastWaiter;
    };

    struct OperationContext
    {
        NativeContext *context;
        bool interrupted;
        uint32_t events;
    };

    struct ContextPair
    {
        OperationContext *readContext;
        OperationContext *writeContext;
    };

    class Dispatcher
    {
      public:
        Dispatcher();

        Dispatcher(const Dispatcher &) = delete;

        ~Dispatcher();

        Dispatcher &operator=(const Dispatcher &) = delete;

        void clear();

        void dispatch();

        NativeContext *getCurrentContext() const;

        void interrupt();

        void interrupt(NativeContext *context);

        bool interrupted();

        void pushContext(NativeContext *context);

        void remoteSpawn(std::function<void()> &&procedure);

        void yield();

        // system-dependent
        int getEpoll() const;

        NativeContext &getReusableContext();

        void pushReusableContext(NativeContext &);

        int getTimer();

        void pushTimer(int timer);

#ifdef __x86_64__
#if __WORDSIZE == 64
        static const int SIZEOF_PTHREAD_MUTEX_T = 40;
#else
        static const int SIZEOF_PTHREAD_MUTEX_T = 32;
#endif
#elif __aarch64__
        /* This sizes the raw byte buffer a real pthread_mutex_t is
           constructed into, so it has to match the C library rather than the
           architecture: bionic's is 40 bytes on LP64, glibc's aarch64 one is
           48. Too small corrupts memory rather than failing to build. */
#if defined(__BIONIC__)
        static const int SIZEOF_PTHREAD_MUTEX_T = 40;
#else
        static const int SIZEOF_PTHREAD_MUTEX_T = 48;
#endif
#else

        static const int SIZEOF_PTHREAD_MUTEX_T = 24;

#endif

      private:
        void spawn(std::function<void()> &&procedure);

        int epoll;

        alignas(void *) uint8_t mutex[SIZEOF_PTHREAD_MUTEX_T];

        int remoteSpawnEvent;

        ContextPair remoteSpawnEventContext;

        std::queue<std::function<void()>> remoteSpawningProcedures;

        std::stack<int> timers;

        NativeContext mainContext;

        NativeContextGroup contextGroup;

        NativeContext *currentContext;

        NativeContext *firstResumingContext;

        NativeContext *lastResumingContext;

        NativeContext *firstReusableContext;

        size_t runningContextCount;

        void contextProcedure(void *ucontext);

        static void contextProcedureStatic(void *context);
    };

} // namespace System
