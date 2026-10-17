# NIGHTSHIFT (SHIFT)

A fixed-supply ERC-20 on Ethereum that burns 1% of every ordinary transfer. Built for an IMD
custom-token launch: the whole supply is minted once to the deploying factory, and the launch's
own flows (swarm distribution, pool seeding, sells into the Uniswap v4 PoolManager) are delivered
whole so the launch cannot arrive short. What the PoolManager pays out (a buy) is taxed like any
other transfer.

| Item | Value |
| --- | --- |
| Solidity contract | `ShiftToken` (`src/ShiftToken.sol`) |
| `name()` / `symbol()` | `NIGHTSHIFT` / `SHIFT` |
| Decimals | 18 |
| Total supply | 1,000,000,000 SHIFT = `1000000000000000000000000000` minor units |
| Burn fee | 1% (`BURN_BPS = 100` of `BPS_DENOMINATOR = 10_000`), a constant |
| Compiler | solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`, evm `cancun` |
| Base | OpenZeppelin Contracts v5.4.0 `ERC20`, vendored under `lib/openzeppelin/` |

## Behaviour

**Ordinary transfers.** For a `transfer` or `transferFrom` of `value` between two ordinary
accounts:

- the sender is debited exactly `value`;
- `value * 100 / 10_000` (rounded down) is burned: `totalSupply` falls by that amount and a
  `Transfer(sender, 0x0, fee)` event is emitted, followed by `FeeBurned(sender, recipient, fee)`;
- the recipient is credited `value - fee`, with a `Transfer(sender, recipient, value - fee)` event.

`transferFrom` consumes allowance for the gross `value`. Amounts under 100 minor units burn
nothing (rounding down); this is deliberate and economically nil at 18 decimals, since splitting a
transfer saves at most 1 wei of burn per extra transaction. A self-transfer is still taxed. A
zero-value transfer burns nothing. If the sender cannot cover the gross `value`, the transfer
reverts with `ERC20InsufficientBalance(sender, balance, value)` and nothing is burned, for any
`value` up to `type(uint256).max` (the fee is computed with `Math.mulDiv`, so it never overflows).

**Launch-exempt transfers.** A transfer is delivered in full, with no burn, when:

1. its sender *or* recipient is the IMD ProjectFactory (`FACTORY`, a constructor argument);
2. its sender *or* recipient is this launch's MerkleDistributor, read from the factory at
   transfer time with `distributorOf(LAUNCH_NUMBER)`;
3. its *recipient* is the Uniswap v4 PoolManager (`POOL_MANAGER`, a constructor argument).

That covers exactly the launch flows that must settle an exact delta: factory to distributor,
distributor to claimant, factory to PoolManager (seed) and trader to PoolManager (sell). A payout
*from* the PoolManager (a buy, or a `take` of a credit) is taxed like any other transfer: the
PoolManager is debited the gross amount, the recipient receives 99%, and 1% is burned. The
PoolManager is a permissionless singleton, so exempting it as a sender would let anyone move SHIFT
burn-free by settling it in and taking it out; exempting it only as a recipient closes that route
while keeping the seed and every sell exact.

The distributor lookup is a `staticcall`; if the factory has no code, the call fails, it returns
fewer than 32 bytes, or the returned word is not a clean 160-bit address, no distributor is exempt
and the transfer is taxed as usual, so the token never bricks on a factory problem.

**Nothing else.** There is no owner, no mint, no pause, no blocklist, no `burnFrom`, no proxy,
no `delegatecall` and no `selfdestruct`. The supply can only shrink.

## Deployment parameters

`ShiftToken` is deployed by the IMD factory through `ProjectFactory.launchCustom`. Its
constructor takes three static arguments, all filled by the launch manifest:

| Argument | Type | Manifest value | Meaning |
| --- | --- | --- | --- |
| `factory_` | `address` | `$factory` | The ProjectFactory; must not be zero |
| `poolManager_` | `address` | `$poolManager` | The Uniswap v4 PoolManager on Ethereum; must not be zero |
| `launchNumber_` | `uint64` | `$launchNumber` | This launch's number, used to look up its distributor |

The constructor mints `INITIAL_SUPPLY` to `msg.sender` (the factory) and makes no external
calls, so it deploys on an empty chain. Launch facts fixed by the job, not by this code:

- Chain: Ethereum mainnet (chain id 1).
- Pair: IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`), fee 12500 (1.25%), tick spacing 60.
- Economics: 88% of the supply seeds the pool at a 2,500 IMD opening market cap; the swarm's 10%
  goes to the MerkleDistributor; the remaining 2% goes to
  `0x83027ad9d0d5374335086c539dadd1db983441b0`.

The manifest (`launch.json`) is written by the manifest step after acceptance, not here.

## After launch

Nothing to configure. The token has no owner and no setters. The only post-launch dependency is
the factory's `distributorOf(launchNumber)` answer, which the factory records when it creates the
launch's distributor.

## Assumptions

- The factory, the PoolManager and the distributor are the only addresses whose flows must be
  exact. Any other contract that holds SHIFT (a router, a vault, an exchange hot wallet) receives
  1% less than sent and must account for SHIFT as a fee-on-transfer token.
- `distributorOf(uint64)` on the factory returns the distributor for this launch number and
  returns the zero address (or reverts) for launches that have none. Another launch's distributor
  is not exempt.
- Exemption is by address, not by caller. The factory and the distributor are exempt in both
  directions; the PoolManager only as a recipient, so sells and the seed settle exactly while buys
  and `take`s are taxed. Holders can still hold SHIFT inside the PoolManager as ERC-6909 claims and
  pass those claims around without a burn, but turning a claim back into SHIFT (`take`) is taxed, so
  the route out costs the same 1% as a direct transfer.
- The factory's `distributorOf(launchNumber)` answer is correct and does not change after launch.
  It is read on every taxed transfer (up to two `staticcall`s, roughly 5-6k gas each), and whoever
  can change that answer can name any address as a burn-exempt hub or un-name the real distributor
  so claims arrive 1% short. The factory is IMD's and outside this repository; this is the token's
  one external trust boundary.
- The burn rate is a compile-time constant. Changing it requires a new token.

## Operational responsibilities

- **Integrators and holders**: treat SHIFT as fee-on-transfer. Measure received balances rather
  than trusting the sent amount. Liquidity pools other than the launch pool, lending markets and
  bridges that do not support fee-on-transfer tokens will misbehave.
- **The launch (IMD's deployer)**: nothing beyond deploying with the three arguments above. No
  key, role or configuration survives deployment.
- **Nobody** can mint, freeze, seize, pause or upgrade. There is no emergency switch; the
  trade-off is deliberate and documented so nobody expects one.

## Tests

`test/ShiftToken.t.sol` covers construction, the 1% burn on `transfer` and `transferFrom`
(including rounding, zero amounts, self-transfers, compounding across hops and a fuzzed
conservation check), every launch-exempt flow in both the unset and set distributor states, the
PoolManager being exempt only as a recipient (a settle-and-take hop between two holders burns the
same 1% as a direct transfer), robustness when the factory is an EOA, its lookup reverts, returns
a short reply or returns a word that is not an address, the revert paths (short balance including
`type(uint256).max`, short allowance, zero recipient, factory pulling without allowance), the
absence of any mint/admin surface, and a scan of the runtime for `DELEGATECALL`, `CALLCODE` and
`SELFDESTRUCT`.

```sh
forge build
forge test
forge fmt --check
```

Tests read no environment variables and pass in any order or in parallel. Tests passing is not a
security audit; an independent adversarial review is expected before the launch is admitted.
