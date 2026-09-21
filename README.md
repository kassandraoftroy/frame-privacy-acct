# frame-privacy-acct

FrameAccount, a CREATE2 factory, and the shared **WithdrawalSingleton** used
as the MSP v2 proof recipient.

The MSP pool does not know about these contracts. A public withdrawal sets
`recipient` to the singleton and encodes the fourth frame as
`DEFAULT(singleton, settleWithdrawal(nf1, extra))`. Extra is an owner-signed
FrameAccount intent: `abi.encode(owner, salt, calls, signature)`.

## How `nf1` is bound to a user

The pool only records `(recipient, amount)` for `nf1`. Recipient is the shared
singleton, so the pool does not know which user owns the credit.

Binding lives on the singleton: `bound[nf1] → FrameAccount`. That mapping is
ordinary storage, so it **only exists if `settleWithdrawal` returns**. A revert
rolls it back. Then:

| Situation | Who can take `nf1` |
|---|---|
| Original FrameTx (fourth frame still in the spend) | Extra is inside the spend authorizer signature. A third party cannot swap dest on **that** tx. |
| `settleWithdrawal` **returned** (claim or batch may have failed) | Only that CREATE2 account. Later extras with a different owner revert `NotBoundAccount`. |
| `settleWithdrawal` **reverted** (bad sig, OOG, panic before return) | Pool credit remains. Anyone can retry with a **different** extra. The receive-gate only blocks unlabeled `claimWithdrawal`, not dest substitution. |

There is no way, without MSP recording authorizer or dest, for the singleton
to know the “original” user after a fully reverting fourth frame. `lock` would
be first-writer-wins and is therefore omitted (an attacker would lock first).

## `settleWithdrawal`

1. Recovers the owner over FrameAccount's `executeDigest` (nonce 0 if the
   account is undeployed). A bad sig reverts **before** `bound` is written.
2. Writes `bound[nf1]` if unset; otherwise requires the same account.
3. CREATE2s via the pinned factory if needed.
4. `claimWithdrawal(nf1)` behind a receive-gate. Claim/batch failures are
   swallowed so a returned call keeps the bind; credit stays on the pool if
   the claim did not succeed.
5. Forwards claimed ETH to the account.
6. Tries `executeBatch`. Owner retries on the account (new nonce/sig) if the
   batch failed after the pull.

Existing accounts (same factory owner+salt) skip deploy.

```
forge test
```

Deploy (proof recipient = singleton):

```
MSP_POOL=0x... forge script script/Deploy.s.sol --broadcast
```
