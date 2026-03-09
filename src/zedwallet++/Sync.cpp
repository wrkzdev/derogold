// Copyright (c) 2018-2021, The DeroGold Developers
// Copyright (c) 2018-2019, The TurtleCoin Developers
//
// Please see the included LICENSE file for more information.

/////////////////////////////
#include <zedwallet++/Sync.h>
/////////////////////////////

#include <common/SignalHandler.h>
#include <config/WalletConfig.h>
#include <iostream>
#include <thread>
#include <utilities/ColouredMsg.h>
#include <zedwallet++/CommandImplementations.h>

void syncWallet(const std::shared_ptr<WalletBackend> walletBackend)
{
    auto [walletBlockCount, localDaemonBlockCount, networkBlockCount] = walletBackend->getSyncStatus();

    /* Fully synced */
    if (walletBlockCount == networkBlockCount)
    {
        return;
    }

    if (localDaemonBlockCount + 1 <= networkBlockCount)
    {
        std::cout << "Your " << WalletConfig::daemonName << " isn't fully "
                  << "synced yet!\n"
                  << "Until you are fully synced, you won't be able to send "
                  << "transactions,\nand your balance may be missing or "
                  << "incorrect!\n\n";
    }

    if (walletBlockCount == 0)
    {
        std::stringstream stream;

        stream << "Scanning through the blockchain to find transactions "
               << "that belong to you.\n"
               << "Please wait, this will take some time.\n\n";

        std::cout << InformationMsg(stream.str());
    }
    else
    {
        std::stringstream stream;

        stream << "Scanning through the blockchain to find any new "
               << "transactions you received\nwhilst your wallet wasn't open.\n"
               << "Please wait, this may take some time.\n\n";

        std::cout << InformationMsg(stream.str());
    }

    uint64_t lastSavedBlock = walletBlockCount;

    /* Amount of times we have looped without getting any new blocks */
    uint32_t stuckCounter = 0;

    /* Whether we have already shown the prune floor warning this session */
    bool shownPruneWarning = false;

    while (walletBlockCount < localDaemonBlockCount)
    {
        auto [tmpWalletBlockCount, localDaemonBlockCount, networkBlockCount] = walletBackend->getSyncStatus();

        /* Show a one-time warning when the daemon's prune floor is detected.
           Raw block data below the prune floor is not available, so transactions
           in that range cannot be detected. Sync continues from the prune floor. */
        if (!shownPruneWarning)
        {
            const uint64_t pruneFloor = walletBackend->getPruneFloor();

            if (pruneFloor > 0)
            {
                shownPruneWarning = true;

                std::cout << WarningMsg(
                    "\nNote: This daemon has pruned raw block data below height " +
                    std::to_string(pruneFloor) + ".\n"
                    "Transactions in blocks 0 to " + std::to_string(pruneFloor - 1) +
                    " cannot be scanned on this node.\n"
                    "Syncing from block " + std::to_string(pruneFloor) + " instead.\n"
                    "Use a non-pruned node if you need full transaction history.\n")
                    << std::endl;
            }
        }

        std::cout << SuccessMsg(tmpWalletBlockCount) << " of " << InformationMsg(localDaemonBlockCount) << std::endl;

        if (walletBlockCount == tmpWalletBlockCount)
        {
            stuckCounter++;
        }
        else
        {
            stuckCounter = 0;
        }

        /* Get any transactions in between the previous height and the new
           height */
        for (const auto &tx : walletBackend->getTransactionsRange(walletBlockCount, tmpWalletBlockCount))
        {
            /* Don't print out fusion transactions */
            if (!tx.isFusionTransaction())
            {
                std::cout << InformationMsg("\nNew transaction found!\n\n");

                if (tx.totalAmount() < 0)
                {
                    printOutgoingTransfer(tx);
                }
                else
                {
                    printIncomingTransfer(tx);
                }
            }
        }

        walletBlockCount = tmpWalletBlockCount;

        /* Save every 10k blocks */
        if (walletBlockCount > lastSavedBlock + 10000)
        {
            std::cout << InformationMsg("\nSaving progress...\n\n");

            walletBackend->save();

            lastSavedBlock = walletBlockCount;
        }

        if (stuckCounter >= 20)
        {
            std::stringstream stream;

            stream << "Syncing may be stuck. Ensure your daemon or remote "
                      "node is online, and not syncing.\n(Syncing often stalls "
                      "wallet operation)\nGive the daemon a restart if possible.\n"
                   << "If this persists, visit " << WalletConfig::contactLink << " for support.";

            std::cout << WarningMsg(stream.str()) << std::endl;
        }

        std::this_thread::sleep_for(std::chrono::seconds(2));
    }
}
