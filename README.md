# curated-vault — a MetaMorpho-style curated allocator over isolated lending markets

An ERC-4626 vault that spreads deposits across **multiple isolated lending markets** (the
[isolated-lending](https://github.com/dngr2/isolated-lending) primitive) according to a curator's
per-market caps and supply/withdraw queues. Passive depositors get a single, diversified,
auto-allocated yield position; the blast radius of any one market is bounded by the cap the curator
set for it.

## The differentiator

- **Curator sets policy, not custody.** The curator (owner) chooses which markets, their caps, and
  the queue order — but has **no privileged path to depositor funds**. The worst a malicious curator
  can do is route deposits into a poor market *up to its public cap*; it can never withdraw
  depositor assets to itself (`test_onlyCurator_canConfigure`, and there is no owner transfer path).
  This is the MetaMorpho trust model, stated plainly.
- **Diversification with a hard per-market ceiling.** Deposits fill the supply queue in order, each
  market only up to its cap; the remainder stays as idle liquidity — never silently over-allocated
  (`test_deposit_leftoverStaysIdleWhenCapped`, mutation-checked: ignoring the cap fails the test).
- **Solvency is a fuzzed invariant.** Over 12,800 fuzzed calls: the redeemable value of all shares
  never exceeds reported net assets (`invariant_solvent`), and reported assets always equal idle
  plus the vault's position in each market (`invariant_navConsistent`).
- **Withdrawals respect real liquidity.** Withdrawals pull from the withdraw queue up to each
  market's available (unborrowed) liquidity, and revert cleanly if the markets can't cover the
  request (`test_withdraw_revertsIfMarketsIlliquid`) — no phantom liquidity.
- **Inflation-attack-safe** via the virtual-shares offset (`test_inflationAttack_neutralized`).

## How it works

| Action | Behavior |
|---|---|
| `addMarket(market, cap)` | curator approves a market (must use this vault's asset) with a supply cap |
| `setCap` / `setSupplyQueue` / `setWithdrawQueue` | curator tunes allocation policy |
| `deposit` / `mint` | pulls assets, allocates across the supply queue up to each cap; remainder idles |
| `withdraw` / `redeem` | pulls back from the withdraw queue (bounded by each market's idle liquidity) |
| `totalAssets()` | idle assets + the vault's supplied position in every tracked market |

Yield flows automatically: as borrowers pay interest in the underlying markets, the vault's supplied
position grows and the share price rises (`test_yieldFlowsToDepositors`).

## Honest scope & trust

- The curator is trusted for **allocation policy** (which markets, what caps) — not custody. Caps
  bound depositor downside and are public.
- Each underlying market's own risks apply — chiefly its **oracle**, which is a trusted input to any
  lending market. Diversification across isolated markets contains, but does not eliminate, that risk.
- `totalAssets()` reads each market's last-accrued value; a market accrues on its own interactions,
  so reported NAV can lag until a market is poked (standard; documented).
- Independent, clean-room implementation, **not audited**, **no mainnet deployment or TVL claimed**.
  Run the tests and get an independent audit before using with real funds. See [`DEPLOY.md`](./DEPLOY.md).

## Testing

`forge test` — **11 tests, all green** (9 unit + 2 fuzzed solvency invariants at 64 runs × 200
depth). The cap-allocation logic is mutation-checked. Solc 0.8.26, `via_ir`, cancun, OpenZeppelin v5.
The `LendingMarket` / `LinearIrm` sources are vendored so this repo builds standalone; the canonical
copies live in [isolated-lending](https://github.com/dngr2/isolated-lending).

## License

MIT.
