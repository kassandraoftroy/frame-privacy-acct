// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @notice Owner-gated batch executor. Anyone may call [`executeBatch`]
/// if they supply the owner's ECDSA over [`executeDigest`]. The owner may
/// call without a signature. The shielded pool is not a privileged caller.
contract FrameAccount {
    address public immutable owner;
    uint256 public nonce;

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error NotAuthorized();
    error BadSignature();
    error CallFailed(uint256 index);

    constructor(address owner_) {
        owner = owner_;
    }

    receive() external payable {}

    function executeDigest(Call[] calldata calls) public view returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(block.chainid, address(this), nonce, calls));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    function executeBatch(Call[] calldata calls, bytes calldata signature) external {
        if (msg.sender != owner) {
            if (_recover(executeDigest(calls), signature) != owner) revert NotAuthorized();
        }
        nonce++;
        for (uint256 i = 0; i < calls.length; i++) {
            (bool ok,) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i);
        }
    }

    function _recover(bytes32 digest, bytes calldata signature) internal pure returns (address) {
        if (signature.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert BadSignature();
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert BadSignature();
        return recovered;
    }
}
