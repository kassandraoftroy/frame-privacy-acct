// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

interface IFrameAccountFactory {
    function approveStub() external view returns (address);
}

/// @notice Owner-gated batch executor. Anyone may call [`executeBatch`]
/// if they supply the owner's ECDSA over [`executeDigest`]. The owner may
/// call without a signature. A frame transaction whose sender is this
/// account may also call without a signature: [`approveSender`] already
/// checked the owner on the transaction signature.
/// The shielded pool is not a privileged caller.
contract FrameAccount {
    address public immutable owner;
    /// @notice Factory that deployed this account. Its `approveStub` runs
    /// `SIGPARAM` and `APPROVE` via delegatecall.
    address public immutable factory;
    uint256 public nonce;

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    error NotAuthorized();
    error BadSignature();
    error CallFailed(uint256 index);
    error ApprovalFailed();

    constructor(address owner_) {
        owner = owner_;
        factory = msg.sender;
    }

    receive() external payable {}

    function executeDigest(Call[] calldata calls) public view returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(block.chainid, address(this), nonce, calls));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    /// @notice VERIFY-frame entry. Delegatecalls the factory stub, which
    /// requires signature 0 to be an empty-msg secp256k1 signature by `owner`
    /// and then `APPROVE`s execution and payment. The frame target and
    /// `tx.sender` must be this account, so the account pays gas.
    function approveSender() external {
        address stub = IFrameAccountFactory(factory).approveStub();
        (bool ok,) = stub.delegatecall(abi.encode(owner));
        if (!ok) revert ApprovalFailed();
    }

    function executeBatch(Call[] calldata calls, bytes calldata signature) external {
        // `address(this)` is the caller when a SENDER frame runs with
        // `tx.sender` equal to this account. The owner signature is already
        // on the frame transaction.
        if (msg.sender != owner && msg.sender != address(this)) {
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
