// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FrameAccount} from "../src/FrameAccount.sol";
import {FrameAccountFactory} from "../src/FrameAccountFactory.sol";
import {WithdrawalSingleton} from "../src/WithdrawalSingleton.sol";

contract Target {
    uint256 public hits;

    function ping() external payable {
        hits++;
    }
}

contract MockPool {
    struct Withdrawal {
        address recipient;
        uint256 amount;
    }

    mapping(bytes32 => Withdrawal) public withdrawals;

    error NoCredit();
    error PayoutFailed();

    bool public revertClaim;

    function setRevertClaim(bool v) external {
        revertClaim = v;
    }

    function credit(bytes32 id, address recipient, uint256 amount) external payable {
        require(msg.value == amount, "value");
        withdrawals[id] = Withdrawal(recipient, amount);
    }

    function claimWithdrawal(bytes32 id) external {
        if (revertClaim) revert PayoutFailed();
        Withdrawal memory w = withdrawals[id];
        if (w.amount == 0) revert NoCredit();
        delete withdrawals[id];
        (bool ok,) = payable(w.recipient).call{value: w.amount}("");
        if (!ok) revert PayoutFailed();
    }
}

contract WithdrawalSingletonTest is Test {
    MockPool pool;
    FrameAccountFactory factory;
    WithdrawalSingleton singleton;
    uint256 ownerPk = 1;
    address owner;

    function setUp() public {
        owner = vm.addr(ownerPk);
        pool = new MockPool();
        factory = new FrameAccountFactory(address(pool));
        singleton = new WithdrawalSingleton(address(pool), factory);
    }

    function _digest(address account, uint256 nonce, FrameAccount.Call[] memory calls) internal view returns (bytes32) {
        bytes32 inner = keccak256(abi.encode(block.chainid, account, nonce, calls));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
    }

    function _sig(address account, uint256 nonce, FrameAccount.Call[] memory calls)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, _digest(account, nonce, calls));
        return abi.encodePacked(r, s, v);
    }

    function _extra(bytes32 salt, FrameAccount.Call[] memory calls, bytes memory signature)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(owner, salt, calls, signature);
    }

    function _extraFor(uint256 pk, bytes32 salt, FrameAccount.Call[] memory calls, uint256 nonce)
        internal
        view
        returns (bytes memory)
    {
        address who = vm.addr(pk);
        address account = factory.getAddress(who, salt);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _digest(account, nonce, calls));
        return abi.encode(who, salt, calls, abi.encodePacked(r, s, v));
    }

    function _ping(address target) internal pure returns (FrameAccount.Call[] memory calls) {
        calls = new FrameAccount.Call[](1);
        calls[0] = FrameAccount.Call({target: target, value: 0, data: abi.encodeCall(Target.ping, ())});
    }

    function testSettleDeploysClaimsForwardsAndExecutes() public {
        bytes32 id = bytes32(uint256(1));
        bytes32 salt = bytes32(uint256(7));
        address account = factory.getAddress(owner, salt);
        assertEq(account.code.length, 0);

        Target t = new Target();
        FrameAccount.Call[] memory calls = _ping(address(t));
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);

        singleton.settleWithdrawal(id, _extra(salt, calls, _sig(account, 0, calls)));

        assertGt(account.code.length, 0);
        assertEq(account.balance, 1 ether);
        assertEq(t.hits(), 1);
        assertEq(FrameAccount(payable(account)).nonce(), 1);
        assertEq(singleton.bound(id), account);
        (, uint256 left) = pool.withdrawals(id);
        assertEq(left, 0);
    }

    function testNakedClaimHitsReceiveGateAndKeepsCredit() public {
        bytes32 id = bytes32(uint256(2));
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);
        vm.expectRevert(MockPool.PayoutFailed.selector);
        pool.claimWithdrawal(id);
        (address recipient, uint256 amount) = pool.withdrawals(id);
        assertEq(recipient, address(singleton));
        assertEq(amount, 1 ether);
        assertEq(address(singleton).balance, 0);
    }

    function testBoundRejectsDifferentAccount() public {
        bytes32 id = bytes32(uint256(3));
        bytes32 saltA = bytes32(uint256(7));
        address accountA = factory.getAddress(owner, saltA);
        FrameAccount.Call[] memory none = new FrameAccount.Call[](0);
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);
        singleton.settleWithdrawal(id, _extra(saltA, none, _sig(accountA, 0, none)));
        assertEq(singleton.bound(id), accountA);

        uint256 otherPk = 2;
        address other = vm.addr(otherPk);
        bytes32 saltB = bytes32(uint256(8));
        address accountB = factory.getAddress(other, saltB);
        bytes32 inner = keccak256(abi.encode(block.chainid, accountB, uint256(0), none));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherPk, digest);
        bytes memory extraB = abi.encode(other, saltB, none, abi.encodePacked(r, s, v));
        vm.expectRevert(WithdrawalSingleton.NotBoundAccount.selector);
        singleton.settleWithdrawal(id, extraB);
    }

    function testRetrySameAccountNewBatch() public {
        bytes32 id = bytes32(uint256(4));
        bytes32 salt = bytes32(uint256(7));
        address account = factory.getAddress(owner, salt);
        FrameAccount.Call[] memory none = new FrameAccount.Call[](0);
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);
        singleton.settleWithdrawal(id, _extra(salt, none, _sig(account, 0, none)));
        assertEq(FrameAccount(payable(account)).nonce(), 1);

        Target t = new Target();
        FrameAccount.Call[] memory calls = _ping(address(t));
        singleton.settleWithdrawal(id, _extra(salt, calls, _sig(account, 1, calls)));
        assertEq(t.hits(), 1);
        assertEq(account.balance, 1 ether);
        assertEq(FrameAccount(payable(account)).nonce(), 2);
    }

    function testBatchRevertLeavesEthAndNonce() public {
        bytes32 id = bytes32(uint256(5));
        bytes32 salt = bytes32(uint256(10));
        address account = factory.getAddress(owner, salt);
        Target t = new Target();
        FrameAccount.Call[] memory calls = new FrameAccount.Call[](2);
        calls[0] = FrameAccount.Call({target: address(t), value: 0, data: abi.encodeCall(Target.ping, ())});
        calls[1] = FrameAccount.Call({target: address(this), value: 0, data: abi.encodeWithSignature("nope()")});
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);

        singleton.settleWithdrawal(id, _extra(salt, calls, _sig(account, 0, calls)));

        assertGt(account.code.length, 0);
        assertEq(account.balance, 1 ether);
        assertEq(t.hits(), 0);
        assertEq(FrameAccount(payable(account)).nonce(), 0);
        assertEq(singleton.bound(id), account);
        (, uint256 left) = pool.withdrawals(id);
        assertEq(left, 0);
    }

    function testExistingAccountSkipsCreate() public {
        bytes32 id = bytes32(uint256(6));
        bytes32 salt = bytes32(uint256(11));
        address account = factory.createAccount(owner, salt);
        assertGt(account.code.length, 0);

        Target t = new Target();
        FrameAccount.Call[] memory calls = _ping(address(t));
        pool.credit{value: 0.5 ether}(id, address(singleton), 0.5 ether);
        singleton.settleWithdrawal(id, _extra(salt, calls, _sig(account, 0, calls)));

        assertEq(account.balance, 0.5 ether);
        assertEq(t.hits(), 1);
        assertEq(factory.createAccount(owner, salt), account);
    }

    function testBadSignatureDoesNotMoveCredit() public {
        bytes32 id = bytes32(uint256(7));
        bytes32 salt = bytes32(uint256(12));
        address account = factory.getAddress(owner, salt);
        FrameAccount.Call[] memory none = new FrameAccount.Call[](0);
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);
        vm.expectRevert(WithdrawalSingleton.BadSignature.selector);
        singleton.settleWithdrawal(id, _extra(salt, none, ""));
        (, uint256 left) = pool.withdrawals(id);
        assertEq(left, 1 ether);
        assertEq(account.code.length, 0);
        assertEq(singleton.bound(id), address(0));
    }

    function testWrongSignerDoesNotMoveCredit() public {
        bytes32 id = bytes32(uint256(8));
        bytes32 salt = bytes32(uint256(13));
        address account = factory.getAddress(owner, salt);
        FrameAccount.Call[] memory none = new FrameAccount.Call[](0);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(2, _digest(account, 0, none));
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);
        vm.expectRevert(WithdrawalSingleton.NotAuthorized.selector);
        singleton.settleWithdrawal(id, _extra(salt, none, abi.encodePacked(r, s, v)));
        (, uint256 left) = pool.withdrawals(id);
        assertEq(left, 1 ether);
        assertEq(singleton.bound(id), address(0));
    }

    function testTwoIdsSameOwnerDoNotMixCredit() public {
        bytes32 idA = bytes32(uint256(9));
        bytes32 idB = bytes32(uint256(10));
        bytes32 salt = bytes32(uint256(14));
        address account = factory.getAddress(owner, salt);
        FrameAccount.Call[] memory none = new FrameAccount.Call[](0);
        pool.credit{value: 1 ether}(idA, address(singleton), 1 ether);
        pool.credit{value: 2 ether}(idB, address(singleton), 2 ether);

        singleton.settleWithdrawal(idA, _extra(salt, none, _sig(account, 0, none)));
        assertEq(account.balance, 1 ether);
        (, uint256 leftA) = pool.withdrawals(idA);
        (, uint256 leftB) = pool.withdrawals(idB);
        assertEq(leftA, 0);
        assertEq(leftB, 2 ether);
        assertEq(singleton.bound(idA), account);
        assertEq(singleton.bound(idB), address(0));

        singleton.settleWithdrawal(idB, _extra(salt, none, _sig(account, 1, none)));
        assertEq(account.balance, 3 ether);
        (, leftB) = pool.withdrawals(idB);
        assertEq(leftB, 0);
        assertEq(singleton.bound(idB), account);
    }

    function testClaimFailureKeepsBindAndCredit() public {
        bytes32 id = bytes32(uint256(11));
        bytes32 salt = bytes32(uint256(15));
        address account = factory.getAddress(owner, salt);
        FrameAccount.Call[] memory none = new FrameAccount.Call[](0);
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);
        pool.setRevertClaim(true);

        singleton.settleWithdrawal(id, _extra(salt, none, _sig(account, 0, none)));

        assertEq(singleton.bound(id), account);
        (, uint256 left) = pool.withdrawals(id);
        assertEq(left, 1 ether);
        assertEq(account.balance, 0);

        pool.setRevertClaim(false);
        bytes memory otherExtra = _extraFor(2, bytes32(uint256(99)), none, 0);
        vm.expectRevert(WithdrawalSingleton.NotBoundAccount.selector);
        singleton.settleWithdrawal(id, otherExtra);

        singleton.settleWithdrawal(id, _extra(salt, none, _sig(account, 1, none)));
        assertEq(account.balance, 1 ether);
        (, left) = pool.withdrawals(id);
        assertEq(left, 0);
    }

    function testRevertedAuthLeavesCreditForAnyValidExtra() public {
        bytes32 id = bytes32(uint256(12));
        bytes32 salt = bytes32(uint256(16));
        FrameAccount.Call[] memory none = new FrameAccount.Call[](0);
        pool.credit{value: 1 ether}(id, address(singleton), 1 ether);
        vm.expectRevert(WithdrawalSingleton.BadSignature.selector);
        singleton.settleWithdrawal(id, _extra(salt, none, ""));
        assertEq(singleton.bound(id), address(0));

        bytes32 saltB = bytes32(uint256(17));
        address accountB = factory.getAddress(vm.addr(2), saltB);
        singleton.settleWithdrawal(id, _extraFor(2, saltB, none, 0));
        assertEq(singleton.bound(id), accountB);
        assertEq(accountB.balance, 1 ether);
    }

    function testDirectEthToSingletonReverts() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(WithdrawalSingleton.UnauthorizedReceive.selector);
        payable(address(singleton)).transfer(1 wei);
    }
}
