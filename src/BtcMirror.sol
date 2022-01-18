// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.11;

import "./Endian.sol";

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
// BtcMirror lets you prove that a BTC transaction executed, on Ethereum. In
// other words, it lets other Ethereum contracts run Simple Payment
// Verification (SPV) on BTC transactions.
//
// Anyone can submit block headers to BtcMirror. The contract verifies
// proof-of-work, keeping only the longest chain it has seen. As long as 50% of
// Bitcoin hash power is honest and at least one person is running the submitter
// script, the BtcMirror contract always reports the current canonical Bitcoin
// chain.
contract BtcMirror {
    event NewTip(uint256 blockHeight, uint256 blockTime, bytes32 blockHash);
    event NewTotalDifficultySinceRetarget(
        uint256 blockHeight,
        uint256 totalDifficulty
    );

    uint256 private latestBlockHeight;

    uint256 private latestBlockTime;

    mapping(uint256 => bytes32) private blockHeightToHash;

    mapping(uint256 => uint256) private blockHeightToTotalDifficulty;

    uint256 private expectedTarget;

    constructor() {
        // start at block #719000
        bytes32 blockHash = 0x00000000000000000000e7287fbd9b2252a3a89b4528375b939da35d12708c7f;
        blockHeightToHash[719000] = blockHash;
        latestBlockHeight = 719000;
        latestBlockTime = 1642350642;
        expectedTarget = 0x0000000000000000000B8C8B0000000000000000000000000000000000000000;
    }

    // Returns the Bitcoin block hash at a specific height.
    function getBlockHash(uint256 number) public view returns (bytes32) {
        return blockHeightToHash[number];
    }

    // Returns the height of the last submitted canonical Bitcoin chain.
    function getLatestBlockHeight() public view returns (uint256) {
        return latestBlockHeight;
    }

    // Returns the timestamp of the last submitted canonical Bitcoin chain.
    function getLatestBlockTime() public view returns (uint256) {
        return latestBlockTime;
    }

    // Submits a new Bitcoin chain segment.
    function submit(uint256 blockHeight, bytes calldata blockHeaders) public {
        uint256 numHeaders = blockHeaders.length / 80;
        require(numHeaders * 80 == blockHeaders.length, "wrong header length");
        require(numHeaders > 0, "must submit at least one block");

        uint256 newHeight = blockHeight + numHeaders;
        if (blockHeight / 2016 == latestBlockHeight / 2016) {
            // new segment STARTS from SAME retarget period.
            // simply check that we have a new longest chain = heaviest chain
            require(newHeight > latestBlockHeight, "chain segment too short");
            for (uint256 i = 0; i < numHeaders; i++) {
                submitBlock(blockHeight + i, blockHeaders[80 * i:80 * (i + 1)]);
            }
        } else {
            // new segment STARTS from PREV retarget preiod.
            require(
                blockHeight / 2016 == latestBlockHeight / 2016 - 1,
                "cannot import from more than one retarget period ago"
            );
            require(
                newHeight / 2016 == latestBlockHeight / 2016,
                "chain segment too short, ends in previous retarget period"
            );
            uint256 lastRetargetH = (newHeight / 2016) * 2016;

            // this is the trickiest part of BtcMirror.
            // we have crossed a retargetting period. we want to gas efficiently
            // allow a SHORTER but HEAVIER chain to replace a LONG, LIGHTER one.
            // (otherwise, our 50% honest assumption degrades to 80% honest, as
            // a colluding 21% can simply withold their hashpower for a whole
            // 2-week retarget period, then mine a far-future spoof block at the
            // very end, setting the difficulty to the minimum 25% of previous.
            // then, as they are over 25% of the honest hashpower, they outrun
            // the honest chain on length and fool BtcMirror.)
            //
            // we avoid this by calculating total difficulty since retarget.
            uint256 oldNSince = latestBlockHeight - lastRetargetH;
            uint256 MAX = ~uint256(0);
            uint256 oldTotalSince = oldNSince * (MAX / expectedTarget);

            for (uint256 i = 0; i < numHeaders; i++) {
                submitBlock(blockHeight + i, blockHeaders[80 * i:80 * (i + 1)]);
            }

            uint256 newNSince = newHeight - lastRetargetH;
            uint256 newTotalSince = newNSince * (MAX / expectedTarget);
            require(newTotalSince > oldTotalSince, "total difficulty too low");
            emit NewTotalDifficultySinceRetarget(newHeight, newTotalSince);

            // erase any block hashes above newHeight, now invalidated.
            for (uint256 i = newHeight + 1; i <= latestBlockHeight; i++) {
                blockHeightToHash[i] = 0;
            }
        }

        latestBlockHeight = newHeight;
        uint256 timeIx = blockHeaders.length - 12;
        uint32 time = uint32(bytes4(blockHeaders[timeIx:timeIx + 4]));
        latestBlockTime = Endian.reverse32(time);

        emit NewTip(newHeight, latestBlockTime, getBlockHash(newHeight));
    }

    function submitBlock(uint256 blockHeight, bytes calldata blockHeader)
        private
    {
        assert(blockHeader.length == 80);

        bytes32 prevHash = bytes32(
            Endian.reverse256(uint256(bytes32(blockHeader[4:36])))
        );
        require(prevHash == blockHeightToHash[blockHeight - 1], "bad parent");

        uint256 blockHashNum = Endian.reverse256(
            uint256(sha256(abi.encode(sha256(blockHeader))))
        );

        // verify proof-of-work
        bytes32 bits = bytes32(blockHeader[72:76]);
        uint256 target = getTarget(bits);
        require(blockHashNum < target, "block hash above target");

        // support once-every-2016-blocks retargeting
        if (blockHeight % 2016 == 0) {
            // Bitcoin enforces a minimum difficulty of 25% of the previous
            // difficulty. Doing the full calculation here does not necessarily
            // add any security. We keep the heaviest chain, not the longest.
            require(target >> 2 < expectedTarget, "<25% difficulty retarget");
            expectedTarget = target;
        } else {
            require(target == expectedTarget, "wrong difficulty bits");
        }

        blockHeightToHash[blockHeight] = bytes32(blockHashNum);
    }

    function getTarget(bytes32 bits) public pure returns (uint256) {
        uint256 exp = uint8(bits[3]);
        uint256 mantissa = uint8(bits[2]);
        mantissa = (mantissa << 8) | uint8(bits[1]);
        mantissa = (mantissa << 8) | uint8(bits[0]);
        uint256 target = mantissa << (8 * (exp - 3));
        return target;
    }

    function hashBlock(bytes calldata blockHeader)
        public
        pure
        returns (bytes32)
    {
        require(blockHeader.length == 80);
        require(abi.encodePacked(sha256(blockHeader)).length == 32);
        bytes32 blockHash = sha256(abi.encodePacked(sha256(blockHeader)));
        return blockHash;
    }
}
