// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {SimpleAccountFactory} from "account-abstraction/accounts/SimpleAccountFactory.sol";
import {FrameAccountFactory} from "../src/FrameAccountFactory.sol";

/// @notice Deploys the Hegotá account infra for an MSP generic DEFAULT tail.
/// Proof recipient is the smart account; tail target is Multicall3.
contract DeployScript is Script {
    function _deployMulticall3() internal returns (address addr) {
        bytes memory bytecode = vm.getCode("Multicall3.sol:Multicall3");
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), "multicall3");
    }

    function run() public {
        vm.startBroadcast();
        address multicall = _deployMulticall3();
        EntryPoint entryPoint = new EntryPoint();
        SimpleAccountFactory simpleFactory = new SimpleAccountFactory(entryPoint);
        FrameAccountFactory frameFactory = new FrameAccountFactory();
        vm.stopBroadcast();

        console.log("Multicall3", multicall);
        console.log("EntryPoint", address(entryPoint));
        console.log("SimpleAccountFactory", address(simpleFactory));
        console.log("SimpleAccount implementation", address(simpleFactory.accountImplementation()));
        console.log("FrameAccountFactory", address(frameFactory));
    }
}
