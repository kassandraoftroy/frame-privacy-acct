# frame-privacy-acct

Smart-account infra for Hegotá, meant to sit behind **one** MSP `DEFAULT` tail.
Newest MSP admits a generic leftover call (zero value, gas/calldata caps). Proof
`recipient` is the **smart account** (payout dest). The tail target is
**Multicall3**, not a custom withdrawal hook.

```
DEFAULT(Multicall3, aggregate3([...]))
```

`msg.sender` of the inner calls is Multicall3. That is enough, because:

- MSP `claimWithdrawal(who)` pays `who`, not the caller
- `FrameAccountFactory.createAccount` is permissionless
- `EntryPoint.handleOps` is permissionless
- `FrameAccount.executeBatch` checks the owner signature in calldata

Do not credit Multicall3.

## 4337 path (eth-infinitism SimpleAccount v0.8)

Multicall legs:

1. `claimWithdrawal(account)` — funds the counterfactual CREATE2 address
2. `handleOps([userOp], beneficiary = account)` — `userOp.initCode` deploys via
   `SimpleAccountFactory`; `callData` is `execute` / `executeBatch`

`SimpleAccountFactory.createAccount` is gated to EntryPoint's `SenderCreator`.
Do not call it from Multicall3. There is no bundler: set `beneficiary` to the
account so leftover 4337 prepaid gas returns to the user. The account pays
EntryPoint from the claimed ETH even though the outer FrameTx already paid
pool gas.

On mainnet-like chains EntryPoint v0.8 lives at `0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108`. Hegotá needs its own deployment.

## FrameAccount path

Multicall legs:

1. `claimWithdrawal(account)`
2. `FrameAccountFactory.createAccount(owner, salt)` (no-op if already deployed)
3. `FrameAccount.executeBatch(calls, signature)`

Anyone can call the account; the owner ECDSA is in the batch. The owner may
also call `executeBatch` directly without a signature.

## Layout

| Piece | Source |
|---|---|
| Multicall3 | `mds1/multicall` v3.1.0 |
| EntryPoint, SimpleAccount, SimpleAccountFactory | `eth-infinitism/account-abstraction` v0.8.0 |
| FrameAccount, FrameAccountFactory | this repo |
| Multicall3Artifact | compile shim: Multicall3 is `pragma solidity 0.8.12`, so tests/`Deploy.s.sol` `create` from its artifact instead of importing it into 0.8.24+ files |

```
forge test
```

Deploy:

```
forge script script/Deploy.s.sol --broadcast --rpc-url <hegota>
```
