// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IMulticall3} from "forge-std/interfaces/IMulticall3.sol";
import {FrameAccount} from "../src/FrameAccount.sol";
import {FrameAccountFactory} from "../src/FrameAccountFactory.sol";
import {MockPool, Target} from "./MockPool.sol";

contract FrameAccountTailTest is Test {
    MockPool pool;
    FrameAccountFactory factory;
    IMulticall3 multicall;
    uint256 ownerPk = 1;
    address owner;

    function setUp() public {
        owner = vm.addr(ownerPk);
        pool = new MockPool();
        factory = new FrameAccountFactory();
        multicall = _deployMulticall3();
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

    function _deployMulticall3() internal returns (IMulticall3 mc) {
        bytes memory bytecode = vm.getCode("Multicall3.sol:Multicall3");
        address addr;
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), "multicall3");
        mc = IMulticall3(addr);
    }

    function _ping(address target) internal pure returns (FrameAccount.Call[] memory calls) {
        calls = new FrameAccount.Call[](1);
        calls[0] = FrameAccount.Call({target: target, value: 0, data: abi.encodeCall(Target.ping, ())});
    }

    function testCreate2MatchesFactory() public {
        bytes32 salt = bytes32(uint256(7));
        address predicted = factory.getAddress(owner, salt);
        address created = factory.createAccount(owner, salt);
        assertEq(created, predicted);
        assertGt(created.code.length, 0);
        assertEq(FrameAccount(payable(created)).owner(), owner);
        assertEq(factory.createAccount(owner, salt), created);
    }

    function testOwnerCanExecuteWithoutSignature() public {
        address account = factory.createAccount(owner, bytes32(uint256(1)));
        Target t = new Target();
        FrameAccount.Call[] memory calls = _ping(address(t));
        vm.prank(owner);
        FrameAccount(payable(account)).executeBatch(calls, "");
        assertEq(t.hits(), 1);
        assertEq(FrameAccount(payable(account)).nonce(), 1);
    }

    function testMulticallClaimsDeploysAndExecutes() public {
        bytes32 salt = bytes32(uint256(7));
        address account = factory.getAddress(owner, salt);
        assertEq(account.code.length, 0);

        Target t = new Target();
        FrameAccount.Call[] memory calls = _ping(address(t));
        bytes memory signature = _sig(account, 0, calls);
        pool.credit{value: 1 ether}(account, 1 ether);

        IMulticall3.Call3[] memory batch = new IMulticall3.Call3[](3);
        batch[0] = IMulticall3.Call3({
            target: address(pool), allowFailure: false, callData: abi.encodeCall(MockPool.claimWithdrawal, (account))
        });
        batch[1] = IMulticall3.Call3({
            target: address(factory),
            allowFailure: false,
            callData: abi.encodeCall(FrameAccountFactory.createAccount, (owner, salt))
        });
        batch[2] = IMulticall3.Call3({
            target: account,
            allowFailure: false,
            callData: abi.encodeCall(FrameAccount.executeBatch, (calls, signature))
        });
        multicall.aggregate3(batch);

        assertGt(account.code.length, 0);
        assertEq(account.balance, 1 ether);
        assertEq(t.hits(), 1);
        assertEq(FrameAccount(payable(account)).nonce(), 1);
        assertEq(pool.withdrawalCredit(account), 0);
    }

    function testSelfCallTransfersWithoutInnerSignature() public {
        address account = factory.createAccount(owner, bytes32(uint256(9)));
        vm.deal(account, 1 ether);
        address dest = address(0xBEEF);
        FrameAccount.Call[] memory calls = new FrameAccount.Call[](1);
        calls[0] = FrameAccount.Call({target: dest, value: 0.2 ether, data: ""});

        vm.prank(account);
        FrameAccount(payable(account)).executeBatch(calls, "");

        assertEq(dest.balance, 0.2 ether);
        assertEq(account.balance, 0.8 ether);
        assertEq(FrameAccount(payable(account)).nonce(), 1);
    }

    function testStrangerStillNeedsOwnerSignature() public {
        address account = factory.createAccount(owner, bytes32(uint256(11)));
        Target t = new Target();
        FrameAccount.Call[] memory calls = _ping(address(t));
        vm.prank(address(0x1234));
        vm.expectRevert(FrameAccount.BadSignature.selector);
        FrameAccount(payable(account)).executeBatch(calls, "");
        assertEq(t.hits(), 0);
    }

    function testApproveStubCarriesSigParamAndApprove() public {
        address stub = factory.approveStub();
        assertGt(stub.code.length, 0);
        bytes memory code = stub.code;
        bool sawSig = false;
        bool sawApprove = false;
        for (uint256 i = 0; i < code.length; i++) {
            if (code[i] == 0xb4) sawSig = true;
            if (code[i] == 0xaa) sawApprove = true;
        }
        assertTrue(sawSig);
        assertTrue(sawApprove);
        assertEq(FrameAccount(payable(factory.createAccount(owner, bytes32(uint256(4))))).factory(), address(factory));
    }

    function testUnsignedBatchFromMulticallReverts() public {
        bytes32 salt = bytes32(uint256(3));
        address account = factory.getAddress(owner, salt);
        Target t = new Target();
        FrameAccount.Call[] memory calls = _ping(address(t));
        pool.credit{value: 1 ether}(account, 1 ether);

        IMulticall3.Call3[] memory batch = new IMulticall3.Call3[](3);
        batch[0] = IMulticall3.Call3({
            target: address(pool), allowFailure: false, callData: abi.encodeCall(MockPool.claimWithdrawal, (account))
        });
        batch[1] = IMulticall3.Call3({
            target: address(factory),
            allowFailure: false,
            callData: abi.encodeCall(FrameAccountFactory.createAccount, (owner, salt))
        });
        batch[2] = IMulticall3.Call3({
            target: account,
            allowFailure: false,
            callData: abi.encodeCall(FrameAccount.executeBatch, (calls, bytes("")))
        });
        vm.expectRevert();
        multicall.aggregate3(batch);
    }
}
