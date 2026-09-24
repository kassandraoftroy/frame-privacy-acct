#!/usr/bin/env bash
# Deploy WETH, STABLE, and a Uniswap V2 WETH/STABLE pool on Hegota devnet.
# Every transaction uses a fixed gas limit. Hegota state gas makes estimates revert.
#
#   export HEGOTA_RPC_URL=... HEGOTA_DEPLOYER_PK=...
#   ./script/deploy-defi.sh
#
# Optional: DEFI_ETH_LIQUIDITY (wei, default 1 ether) and DEFI_STABLE_LIQUIDITY
# (wei, default 2000 ether). DEFI_ETH_LIQUIDITY=0 creates an empty pair.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${HEGOTA_RPC_URL:?set HEGOTA_RPC_URL}"
: "${HEGOTA_DEPLOYER_PK:?set HEGOTA_DEPLOYER_PK}"

# EIP-7825 caps a transaction at 2^24. The pair implementation sits just under that.
GAS_LIMIT=16777216
GAS_PRICE=3000000000
PRIORITY=1000000000
ETH_IN="${DEFI_ETH_LIQUIDITY:-1000000000000000000}"
STABLE_IN="${DEFI_STABLE_LIQUIDITY:-2000000000000000000000}"

SENDER=$(cast wallet address --private-key "$HEGOTA_DEPLOYER_PK")

tx_flags=(
    --rpc-url "$HEGOTA_RPC_URL"
    --private-key "$HEGOTA_DEPLOYER_PK"
    --gas-limit "$GAS_LIMIT"
    --gas-price "$GAS_PRICE"
    --priority-gas-price "$PRIORITY"
)

# Direct CREATE from the deployer. forge create goes through the CREATE2 deployer,
# and storing the init code there burns the whole gas limit on Hegota.
must() {
    local out status
    out=$("$@")
    echo "$out" >&2
    status=$(echo "$out" | awk '/^status/ {print $2}')
    if [ "$status" != "1" ]; then
        echo "transaction reverted" >&2
        exit 1
    fi
}

deploy() {
    local spec="$1"
    shift
    local name bytecode data out addr
    name="${spec##*:}"
    bytecode=$(forge inspect "$name" bytecode)
    if [ -z "$bytecode" ] || [ "$bytecode" = "0x" ]; then
        echo "no bytecode for $name" >&2
        exit 1
    fi
    data="$bytecode"
    if [ "$#" -gt 0 ]; then
        local sig="$1"
        shift
        local encoded
        encoded=$(cast abi-encode "$sig" "$@")
        data="${bytecode}${encoded#0x}"
    fi
    out=$(cast send "${tx_flags[@]}" --create "$data")
    echo "$out" >&2
    local status
    status=$(echo "$out" | awk '/^status/ {print $2}')
    addr=$(echo "$out" | awk '/^contractAddress/ {print $2}')
    if [ "$status" != "1" ] || [ -z "$addr" ] || [ "$addr" = "0x" ]; then
        echo "deploy failed: $spec" >&2
        exit 1
    fi
    echo "$addr"
}

echo "deployer $SENDER"
if [ -n "${WETH:-}" ]; then
    echo "reusing WETH $WETH"
else
    WETH=$(deploy src/defi/WETH.sol:WETH)
fi
if [ -n "${STABLE:-}" ]; then
    echo "reusing STABLE $STABLE"
else
    STABLE=$(deploy src/defi/Stable.sol:Stable)
fi
# Official factory and router embed too much bytecode for the tx gas cap.
# Deploy the pair once, then a clone factory and a small router.
if [ -n "${PAIR_IMPL:-}" ]; then
    echo "reusing UniswapV2Pair $PAIR_IMPL"
else
    PAIR_IMPL=$(deploy lib/v2-core/contracts/UniswapV2Pair.sol:UniswapV2Pair)
fi
FACTORY=$(deploy src/defi/V2CloneFactory.sol:V2CloneFactory "constructor(address)" "$PAIR_IMPL")
ROUTER=$(deploy src/defi/MiniRouter.sol:MiniRouter "constructor(address,address)" "$FACTORY" "$WETH")
must cast send "$FACTORY" "createPair(address,address)" "$WETH" "$STABLE" "${tx_flags[@]}"

if [ "$ETH_IN" = "0" ]; then
    PAIR=$(cast call "$FACTORY" "getPair(address,address)(address)" "$WETH" "$STABLE" --rpc-url "$HEGOTA_RPC_URL")
else
    must cast send "$STABLE" "mint(address,uint256)" "$SENDER" "$STABLE_IN" "${tx_flags[@]}"
    must cast send "$STABLE" "approve(address,uint256)" "$ROUTER" "$STABLE_IN" "${tx_flags[@]}"
    DEADLINE=$(( $(date +%s) + 3600 ))
    must cast send "$ROUTER" \
        "addLiquidityETH(address,uint256,uint256,uint256,address,uint256)" \
        "$STABLE" "$STABLE_IN" 0 0 "$SENDER" "$DEADLINE" \
        --value "$ETH_IN" \
        "${tx_flags[@]}"
    PAIR=$(cast call "$FACTORY" "getPair(address,address)(address)" "$WETH" "$STABLE" --rpc-url "$HEGOTA_RPC_URL")
fi

echo "WETH $WETH"
echo "STABLE $STABLE"
echo "V2CloneFactory $FACTORY"
echo "MiniRouter $ROUTER"
echo "UniswapV2PairImpl $PAIR_IMPL"
echo "WETH_STABLE_PAIR $PAIR"
