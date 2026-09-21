// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {FrameAccount} from "./FrameAccount.sol";
import {FrameAccountFactory} from "./FrameAccountFactory.sol";

interface IPool {
    function claimWithdrawal(bytes32 id) external;
    function withdrawals(bytes32 id) external view returns (address recipient, uint256 amount);
}

/// @notice Shared MSP v2 proof recipient. Frame 4 is
/// `DEFAULT(this, settleWithdrawal(nf1, extra))`. Extra is an owner-signed
/// FrameAccount intent; this contract never runs user calls as itself.
///
/// `bound[nf1]` is the dest account. It is written only if this call **returns**.
/// A reverting `settleWithdrawal` rolls that SSTORE back: the pool credit stays
/// claimable and a later caller may attach a different extra. The original
/// FrameTx still binds extra via the spend authorizer; leftover retries do not.
///
/// Naked `claimWithdrawal` hits [`UnauthorizedReceive`] and the pool restores
/// the id. After a successful pull, ETH sits on the bound account; a reverting
/// batch or claim is swallowed so a returned call keeps `bound[nf1]`.
contract WithdrawalSingleton {
    bytes32 private constant CLAIMING_SLOT = keccak256("WithdrawalSingleton.claimingId");

    IPool public immutable pool;
    FrameAccountFactory public immutable factory;
    mapping(bytes32 => address) public bound; // nf1 => FrameAccount

    error UnauthorizedReceive();
    error ZeroOwner();
    error BadSignature();
    error NotAuthorized();
    error NotBoundAccount();
    error AccountMismatch();

    struct Intent {
        address owner;
        bytes32 salt;
        address account;
        FrameAccount.Call[] calls;
        bytes signature;
    }

    constructor(address pool_, FrameAccountFactory factory_) {
        pool = IPool(pool_);
        factory = factory_;
    }

    receive() external payable {
        if (_claimingId() == bytes32(0)) revert UnauthorizedReceive();
    }

    /// @notice Pull `id` onto the bound FrameAccount and try the signed batch.
    /// `extra` = abi.encode(owner, salt, FrameAccount.Call[] calls, bytes signature).
    function settleWithdrawal(bytes32 id, bytes calldata extra) external {
        Intent memory intent = _authenticate(extra);
        _bind(id, intent.account);

        address created = factory.createAccount(intent.owner, intent.salt);
        if (created != intent.account) revert AccountMismatch();

        (address recipient, uint256 amount) = pool.withdrawals(id);
        if (amount != 0 && recipient == address(this)) {
            _setClaimingId(id);
            try pool.claimWithdrawal(id) {
                _setClaimingId(bytes32(0));
                (bool ok,) = payable(intent.account).call{value: amount}("");
                ok;
            } catch {
                _setClaimingId(bytes32(0));
            }
        }

        (bool ignored,) =
            intent.account.call(abi.encodeCall(FrameAccount.executeBatch, (intent.calls, intent.signature)));
        ignored;
    }

    function _authenticate(bytes calldata extra) internal view returns (Intent memory intent) {
        (intent.owner, intent.salt, intent.calls, intent.signature) =
            abi.decode(extra, (address, bytes32, FrameAccount.Call[], bytes));
        if (intent.owner == address(0)) revert ZeroOwner();
        intent.account = factory.getAddress(intent.owner, intent.salt);
        uint256 nonce = intent.account.code.length == 0 ? 0 : FrameAccount(payable(intent.account)).nonce();
        if (_recover(_digest(intent.account, nonce, intent.calls), intent.signature) != intent.owner) {
            revert NotAuthorized();
        }
        if (intent.account.code.length != 0 && FrameAccount(payable(intent.account)).owner() != intent.owner) {
            revert NotAuthorized();
        }
    }

    function _bind(bytes32 id, address account) internal {
        address existing = bound[id];
        if (existing == address(0)) {
            bound[id] = account;
            return;
        }
        if (existing != account) revert NotBoundAccount();
    }

    function _digest(address account, uint256 nonce, FrameAccount.Call[] memory calls) internal view returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(block.chainid, account, nonce, calls));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    function _recover(bytes32 digest, bytes memory signature) internal pure returns (address) {
        if (signature.length != 65) revert BadSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (v < 27) v += 27;
        if (v != 27 && v != 28) revert BadSignature();
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0)) revert BadSignature();
        return recovered;
    }

    function _claimingId() private view returns (bytes32 id) {
        bytes32 slot = CLAIMING_SLOT;
        assembly {
            id := tload(slot)
        }
    }

    function _setClaimingId(bytes32 id) private {
        bytes32 slot = CLAIMING_SLOT;
        assembly {
            tstore(slot, id)
        }
    }
}
