// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20Mini {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IWETHMini {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IFactoryMini {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

interface IPairMini {
    function mint(address to) external returns (uint256 liquidity);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice Adds ETH and an ERC20 to an existing V2 pair. The official router does not fit a Hegota transaction.
contract MiniRouter {
    address public immutable factory;
    address public immutable WETH;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH = weth_;
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256,
        uint256,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        require(deadline >= block.timestamp, "EXPIRED");
        address pair = IFactoryMini(factory).getPair(token, WETH);
        require(pair != address(0), "NO_PAIR");
        IWETHMini(WETH).deposit{value: msg.value}();
        require(IWETHMini(WETH).transfer(pair, msg.value), "WETH");
        require(IERC20Mini(token).transferFrom(msg.sender, pair, amountTokenDesired), "TOKEN");
        liquidity = IPairMini(pair).mint(to);
        return (amountTokenDesired, msg.value, liquidity);
    }

    /// @notice Wrap `msg.value` ETH and swap it for `token`. `amountOutMin` of 0 accepts any output.
    /// `to` of the zero address sends the tokens to the caller.
    function swapExactETHForTokens(uint256 amountOutMin, address token, address to, uint256 deadline)
        external
        payable
        returns (uint256 amountOut)
    {
        require(deadline >= block.timestamp, "EXPIRED");
        require(msg.value > 0, "VALUE");
        address pair = IFactoryMini(factory).getPair(token, WETH);
        require(pair != address(0), "NO_PAIR");
        (uint112 reserve0, uint112 reserve1,) = IPairMini(pair).getReserves();
        bool wethIs0 = IPairMini(pair).token0() == WETH;
        uint256 reserveIn = wethIs0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveOut = wethIs0 ? uint256(reserve1) : uint256(reserve0);
        amountOut = getAmountOut(msg.value, reserveIn, reserveOut);
        require(amountOut >= amountOutMin, "SLIPPAGE");
        address recipient = to == address(0) ? msg.sender : to;
        IWETHMini(WETH).deposit{value: msg.value}();
        require(IWETHMini(WETH).transfer(pair, msg.value), "WETH");
        if (wethIs0) {
            IPairMini(pair).swap(0, amountOut, recipient, "");
        } else {
            IPairMini(pair).swap(amountOut, 0, recipient, "");
        }
    }

    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) public pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
    }
}
