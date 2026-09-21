// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {FrameAccountFactory} from "../src/FrameAccountFactory.sol";
import {WithdrawalSingleton} from "../src/WithdrawalSingleton.sol";

contract DeployScript is Script {
    function run() public {
        address pool = vm.envAddress("MSP_POOL");
        vm.startBroadcast();
        FrameAccountFactory factory = new FrameAccountFactory(pool);
        new WithdrawalSingleton(pool, factory);
        vm.stopBroadcast();
    }
}
