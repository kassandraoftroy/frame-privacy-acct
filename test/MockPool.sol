// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Address-keyed withdrawal credit, matching current MSP
/// `claimWithdrawal(address)`.
contract MockPool {
    mapping(address => uint256) public withdrawalCredit;

    error NoCredit();
    error PayoutFailed();

    function credit(address who, uint256 amount) external payable {
        require(msg.value == amount, "value");
        withdrawalCredit[who] += amount;
    }

    function claimWithdrawal(address who) external {
        uint256 amount = withdrawalCredit[who];
        if (amount == 0) revert NoCredit();
        withdrawalCredit[who] = 0;
        (bool ok,) = payable(who).call{value: amount}("");
        if (!ok) revert PayoutFailed();
    }
}

contract Target {
    uint256 public hits;

    function ping() external payable {
        hits++;
    }
}
