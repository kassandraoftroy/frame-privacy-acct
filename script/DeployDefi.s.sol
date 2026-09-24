// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {Stable} from "../src/defi/Stable.sol";
import {WETH} from "../src/defi/WETH.sol";

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

/// @notice Deploys WETH, STABLE, Uniswap V2 factory and router, then the WETH/STABLE pair.
///
/// `DEFI_ETH_LIQUIDITY` (default 1 ether) and `DEFI_STABLE_LIQUIDITY` (default 2000 ether)
/// are added as the first reserves. Set `DEFI_ETH_LIQUIDITY=0` to create an empty pair.
contract DeployDefiScript is Script {
    function run() public {
        uint256 ethIn = vm.envOr("DEFI_ETH_LIQUIDITY", uint256(1 ether));
        uint256 stableIn = vm.envOr("DEFI_STABLE_LIQUIDITY", uint256(2000 ether));

        vm.startBroadcast();
        WETH weth = new WETH();
        Stable stable = new Stable();
        IUniswapV2Factory factory = IUniswapV2Factory(_deploy("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(msg.sender)));
        IUniswapV2Router02 router = IUniswapV2Router02(
            _deploy("UniswapV2Router02.sol:UniswapV2Router02", abi.encode(address(factory), address(weth)))
        );

        address pair;
        if (ethIn == 0) {
            pair = factory.createPair(address(weth), address(stable));
        } else {
            require(msg.sender.balance >= ethIn, "deployer ETH below DEFI_ETH_LIQUIDITY");
            stable.mint(msg.sender, stableIn);
            stable.approve(address(router), stableIn);
            router.addLiquidityETH{value: ethIn}(address(stable), stableIn, 0, 0, msg.sender, block.timestamp);
            pair = factory.getPair(address(weth), address(stable));
        }
        vm.stopBroadcast();

        console.log("WETH", address(weth));
        console.log("STABLE", address(stable));
        console.log("UniswapV2Factory", address(factory));
        console.log("UniswapV2Router02", address(router));
        console.log("WETH_STABLE_PAIR", pair);
    }

    function _deploy(string memory artifact, bytes memory args) internal returns (address addr) {
        bytes memory bytecode = abi.encodePacked(vm.getCode(artifact), args);
        assembly {
            addr := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        require(addr != address(0), artifact);
    }
}
