// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IBtcMirror.sol";
import "./interfaces/IBtcTxVerifier.sol";
import "./BtcProofUtils.sol";

//
//                                        #
//                                       # #
//                                      # # #
//                                     # # # #
//                                    # # # # #
//                                   # # # # # #
//                                  # # # # # # #
//                                 # # # # # # # #
//                                # # # # # # # # #
//                               # # # # # # # # # #
//                              # # # # # # # # # # #
//                                   # # # # # #
//                               +        #        +
//                                ++++         ++++
//                                  ++++++ ++++++
//                                    +++++++++
//                                      +++++
//                                        +
//
// BtcVerifier implements a merkle proof that a Bitcoin payment succeeded. It
// uses BtcMirror as a source of truth for which Bitcoin block hashes are in the
// canonical chain.
contract BtcTxVerifier is IBtcTxVerifier {
    IBtcMirror public immutable mirror;

    constructor(IBtcMirror _mirror) {
        mirror = _mirror;
    }

    function verifyPayment(
        uint256 minConfirmations,
        uint256 blockNum,
        BtcTxProof calldata inclusionProof,
        uint256 txOutIx,
        bytes32 destScriptHash,
        uint256 amountSats
    ) external view returns (bool) {
        {
            uint256 mirrorHeight = mirror.getLatestBlockHeight();

            require(
                mirrorHeight >= blockNum,
                "Bitcoin Mirror doesn't have that block yet"
            );

            require(
                mirrorHeight + 1 >= minConfirmations + blockNum,
                "Not enough Bitcoin block confirmations"
            );
        }

        bytes32 blockHash = mirror.getBlockHash(blockNum);

        require(
            BtcProofUtils.validatePayment(
                blockHash,
                inclusionProof,
                txOutIx,
                destScriptHash,
                amountSats
            ),
            "Invalid transaction proof"
        );

        return true;
    }
}
