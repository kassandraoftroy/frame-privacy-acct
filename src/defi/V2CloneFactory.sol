// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IPairInit {
    function initialize(address token0, address token1) external;
}

/// @notice Deploys Uniswap V2 pairs as EIP-1167 clones of a predeployed pair.
/// The official factory embeds the pair creation code and cannot fit in a Hegota transaction.
contract V2CloneFactory {
    address public feeTo;
    address public immutable implementation;
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    constructor(address impl) {
        implementation = impl;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "IDENTICAL");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "ZERO");
        require(getPair[token0][token1] == address(0), "EXISTS");

        bytes memory code = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(code, 0x20), mload(code), salt)
        }
        require(pair != address(0), "CREATE2");
        IPairInit(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
    }
}
