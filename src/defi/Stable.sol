// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Devnet 18-decimal token. `mint` is permissionless on purpose.
contract Stable is ERC20 {
    constructor() ERC20("Stable", "STABLE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
