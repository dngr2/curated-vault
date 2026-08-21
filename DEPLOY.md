# Deploying curated-vault

`script/Deploy.s.sol` deploys one `CuratedVault` over an existing loan-token asset.

## Env
| Var | Meaning |
|---|---|
| `ASSET` | the loan-token ERC-20 the vault allocates (must already exist on-chain) |
| `VAULT_NAME` / `VAULT_SYMBOL` | share-token metadata (optional) |
| `CURATOR` | address that manages markets/caps/queues (optional; defaults to the deployer) |

## Deploy
```bash
export ASSET=0xLoanToken
# testnet first — free via a faucet
forge script script/Deploy.s.sol:Deploy --rpc-url <RPC> --account <keystore-or-ledger> --broadcast
```
Use a dedicated deployer key (keystore/hardware, not a plaintext key holding real funds).

## After deploy (curator)
1. `addMarket(market, cap)` for each isolated LendingMarket that uses the same asset.
2. `setSupplyQueue([...])` — order deposits flow into markets.
3. `setWithdrawQueue([...])` — order withdrawals pull from markets.

Only the underlying markets' assets are ever touched; the curator has no path to depositor funds.
Verify addresses + source on the explorer. **This code is unaudited** — not a substitute for a
third-party audit.
