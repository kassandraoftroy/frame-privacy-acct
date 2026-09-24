// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {FrameAccount} from "./FrameAccount.sol";

/// @notice CREATE2 factory for [`FrameAccount`]. Permissionless; no-ops if the
/// account is already deployed.
contract FrameAccountFactory {
    error CreateFailed();
    error StubFailed();

    /// @notice Shared runtime: `SIGPARAM` owner check, then `APPROVE(0x03)`.
    address public immutable approveStub;

    constructor() {
        approveStub = _deployApproveStub();
    }

    function getAddress(address owner, bytes32 salt) public view returns (address) {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(_initCode(owner))));
        return address(uint160(uint256(h)));
    }

    function createAccount(address owner, bytes32 salt) external returns (address account) {
        account = getAddress(owner, salt);
        if (account.code.length != 0) return account;
        bytes memory code = _initCode(owner);
        assembly {
            account := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (account == address(0)) revert CreateFailed();
    }

    function _initCode(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(type(FrameAccount).creationCode, abi.encode(owner));
    }

    /// Runtime checks signature 0 via `SIGPARAM` (`0xb4`) then `APPROVE` (`0xaa`)
    /// with scope `APPROVE_EXECUTION_AND_PAYMENT`. Calldata is `abi.encode(owner)`.
    function _deployApproveStub() internal returns (address stub) {
        bytes memory runtime =
            hex"60006000b4600035141561002b5760016000b46001141561002b5760026000b4151561002b5760035f5faa5f5ffd";
        bytes memory initcode = abi.encodePacked(
            hex"60",
            bytes1(uint8(runtime.length)),
            hex"600a5f3960",
            bytes1(uint8(runtime.length)),
            hex"5ff3",
            runtime
        );
        assembly {
            stub := create(0, add(initcode, 0x20), mload(initcode))
        }
        if (stub == address(0) || stub.code.length == 0) revert StubFailed();
    }
}
