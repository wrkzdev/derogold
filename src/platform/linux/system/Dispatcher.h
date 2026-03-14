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
#include <unordered_set>

#ifndef __GLIBC__

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

        /* Register/unregister a ContextPair as active.  yield() and dispatch()
           skip epoll events whose data.ptr is not in this set, preventing
           crashes from stale events that arrive after a ContextPair has been
           destroyed or moved (the race: EPOLLONESHOT fires → kernel queues
           event → interrupt/close frees the ContextPair → epoll_wait returns
           stale pointer → UB). */
        void addContextPair(ContextPair *pair);
        void removeContextPair(ContextPair *pair);

        /* RAII guard: registers a ContextPair on construction and deregisters
           it on destruction.  Use for stack-allocated ContextPairs in
           TcpListener::accept() and TcpConnector::connect(). */
        class ContextPairGuard
        {
          public:
            ContextPairGuard(Dispatcher &d, ContextPair &cp) : m_dispatcher(d), m_pair(cp)
            {
                m_dispatcher.addContextPair(&m_pair);
            }

            ~ContextPairGuard()
            {
                m_dispatcher.removeContextPair(&m_pair);
            }

            ContextPairGuard(const ContextPairGuard &) = delete;
            ContextPairGuard &operator=(const ContextPairGuard &) = delete;

          private:
            Dispatcher &m_dispatcher;
            ContextPair &m_pair;
        };

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
        static const int SIZEOF_PTHREAD_MUTEX_T = 48;
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

        /* Set of ContextPair pointers currently registered with epoll.
           All IO operations add their ContextPair before arming epoll and
           remove it after deregistering.  yield() and dispatch() skip any
           epoll event whose data.ptr is absent from this set. */
        std::unordered_set<ContextPair *> activeContextPairs;
    };

} // namespace System
