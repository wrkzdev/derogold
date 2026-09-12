// Copyright (c) 2018-2021, The DeroGold Developers
// Copyright (c) 2018-2019, The TurtleCoin Developers
//
// Please see the included LICENSE file for more information.

#include "RawBlockTools.h"

#include <common/CryptoNoteTools.h>
#include <cryptonotecore/CryptoNoteBasic.h>
#include <utilities/ParseExtra.h>
#include <utilities/Utilities.h>

namespace CryptoNote
{
    WalletTypes::RawCoinbaseTransaction getRawCoinbaseTransaction(const CryptoNote::Transaction &t)
    {
        WalletTypes::RawCoinbaseTransaction transaction;

        transaction.hash = getBinaryArrayHash(toBinaryArray(t));

        transaction.transactionPublicKey = Utilities::getTransactionPublicKeyFromExtra(t.extra);

        transaction.unlockTime = t.unlockTime;

        /* Fill in the simplified key outputs */
        for (const auto &output : t.outputs)
        {
            WalletTypes::KeyOutput keyOutput;

            keyOutput.amount = output.amount;
            keyOutput.key = std::get<CryptoNote::KeyOutput>(output.target).key;

            transaction.keyOutputs.push_back(keyOutput);
        }

        return transaction;
    }

    WalletTypes::RawTransaction getRawTransaction(const std::vector<uint8_t> &rawTX)
    {
        Transaction t;

        /* Convert the binary array to a transaction */
        fromBinaryArray(t, rawTX);

        WalletTypes::RawTransaction transaction;

        /* Get the transaction hash from the binary array */
        transaction.hash = getBinaryArrayHash(rawTX);

        Utilities::ParsedExtra parsedExtra = Utilities::parseExtra(t.extra);

        /* Transaction public key, used for decrypting transactions along with
       private view key */
        transaction.transactionPublicKey = parsedExtra.transactionPublicKey;

        /* Get the payment ID if it exists (Empty string if it doesn't) */
        transaction.paymentID = parsedExtra.paymentID;

        transaction.unlockTime = t.unlockTime;

        /* Simplify the outputs */
        for (const auto &output : t.outputs)
        {
            WalletTypes::KeyOutput keyOutput;

            keyOutput.amount = output.amount;
            keyOutput.key = std::get<CryptoNote::KeyOutput>(output.target).key;

            transaction.keyOutputs.push_back(keyOutput);
        }

        /* Simplify the inputs */
        for (const auto &input : t.inputs)
        {
            transaction.keyInputs.push_back(std::get<CryptoNote::KeyInput>(input));
        }

        return transaction;
    }
} // namespace CryptoNote
