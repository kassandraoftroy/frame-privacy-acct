// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {SimpleAccount} from "account-abstraction/accounts/SimpleAccount.sol";
import {SimpleAccountFactory} from "account-abstraction/accounts/SimpleAccountFactory.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {MockPool, Target} from "./MockPool.sol";

contract SimpleAccountTailTest is Test {
    MockPool pool;
    IMulticall3 multicall;
    EntryPoint entryPoint;
    SimpleAccountFactory factory;
    uint256 ownerPk = 1;
    address owner;
    address relayer = address(0xB0B);

    function setUp() public {
        owner = vm.addr(ownerPk);
        pool = new MockPool();
        multicall = _deployMulticall3();
        entryPoint = new EntryPoint();
        factory = new SimpleAccountFactory(entryPoint);
        vm.deal(relayer, 0);
        vm.fee(1 gwei);
    }

    function _deployMulticall3() internal returns (IMulticall3 mc) {
        bytes memory bytecode = vm.getCode("Multicall3.sol:Multicall3");
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), "multicall3");
        mc = IMulticall3(addr);
    }

    function _pack(uint128 hi, uint128 lo) internal pure returns (bytes32) {
        return bytes32((uint256(hi) << 128) | uint256(lo));
    }

    function _userOp(address account, bytes memory callData, bytes memory initCode)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = PackedUserOperation({
            sender: account,
            nonce: entryPoint.getNonce(account, 0),
            initCode: initCode,
            callData: callData,
            accountGasLimits: _pack(500_000, 200_000),
            preVerificationGas: 50_000,
            gasFees: _pack(1 gwei, 1 gwei),
            paymasterAndData: bytes(""),
            signature: bytes("")
        });
        bytes32 hash = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, hash);
        op.signature = abi.encodePacked(r, s, v);
    }

    function testMulticallClaimsAndHandleOpsDeploys() public {
        uint256 salt = 7;
        address account = factory.getAddress(owner, salt);
        assertEq(account.code.length, 0);

        Target t = new Target();
        bytes memory initCode =
            abi.encodePacked(address(factory), abi.encodeCall(SimpleAccountFactory.createAccount, (owner, salt)));
        bytes memory callData = abi.encodeWithSelector(
            BaseAccount.execute.selector, address(t), uint256(0), abi.encodeCall(Target.ping, ())
        );
        PackedUserOperation memory op = _userOp(account, callData, initCode);

        pool.credit{value: 1 ether}(account, 1 ether);
        uint256 relayerBefore = relayer.balance;

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;

        IMulticall3.Call3[] memory batch = new IMulticall3.Call3[](2);
        batch[0] = IMulticall3.Call3({
            target: address(pool), allowFailure: false, callData: abi.encodeCall(MockPool.claimWithdrawal, (account))
        });
        batch[1] = IMulticall3.Call3({
            target: address(entryPoint),
            allowFailure: false,
            callData: abi.encodeCall(IEntryPoint.handleOps, (ops, payable(account)))
        });
        multicall.aggregate3(batch);

        assertGt(account.code.length, 0);
        assertEq(SimpleAccount(payable(account)).owner(), owner);
        assertEq(t.hits(), 1);
        assertEq(pool.withdrawalCredit(account), 0);
        assertEq(relayer.balance, relayerBefore);
        assertGt(account.balance, 0);
        // 4337 prepaid gas came from the claimed ETH; leftover refund went to the account.
        assertLt(account.balance, 1 ether);
    }

    function testHandleOpsWithoutInitCodeBeforeDeployFails() public {
        uint256 salt = 9;
        address account = factory.getAddress(owner, salt);
        Target t = new Target();
        bytes memory callData = abi.encodeWithSelector(
            BaseAccount.execute.selector, address(t), uint256(0), abi.encodeCall(Target.ping, ())
        );
        PackedUserOperation memory op = _userOp(account, callData, bytes(""));
        pool.credit{value: 1 ether}(account, 1 ether);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        IMulticall3.Call3[] memory batch = new IMulticall3.Call3[](2);
        batch[0] = IMulticall3.Call3({
            target: address(pool), allowFailure: false, callData: abi.encodeCall(MockPool.claimWithdrawal, (account))
        });
        batch[1] = IMulticall3.Call3({
            target: address(entryPoint),
            allowFailure: false,
            callData: abi.encodeCall(IEntryPoint.handleOps, (ops, payable(account)))
        });
        vm.expectRevert();
        multicall.aggregate3(batch);
    }

    function testFactoryCreateAccountIsSenderCreatorGated() public {
        vm.expectRevert("only callable from SenderCreator");
        factory.createAccount(owner, 1);
    }
}
