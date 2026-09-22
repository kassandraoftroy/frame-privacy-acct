// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {Multicall3} from "multicall/Multicall3.sol";

/// @dev Compile-only unit so Foundry builds canonical Multicall3 (exact
/// pragma 0.8.12) as its own artifact. Tests and the deploy script `create`
/// from that bytecode instead of importing Multicall3 into 0.8.24+ files.
contract Multicall3Artifact {
    function deploy() external returns (Multicall3) {
        return new Multicall3();
    }
}
