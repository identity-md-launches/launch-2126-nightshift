# NIGHTSHIFT (SHIFT)

A fixed-supply ERC-20 on Ethereum that burns 1% of every ordinary transfer. Built for an IMD
custom-token launch: the whole supply is minted once to the deploying factory, and the launch's
own flows (swarm distribution, pool seeding, buys and sells through the Uniswap v4 PoolManager)
are delivered whole so the launch cannot arrive short.

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
nothing (rounding down). A self-transfer is still taxed. A zero-value transfer burns nothing.
If the sender cannot cover the gross `value`, the transfer reverts with
`ERC20InsufficientBalance(sender, balance, value)` and nothing is burned.

**Launch-exempt transfers.** A transfer whose sender *or* recipient is one of the following is
delivered in full, with no burn:

1. the IMD ProjectFactory (`FACTORY`, a constructor argument);
2. the Uniswap v4 PoolManager (`POOL_MANAGER`, a constructor argument);
3. this launch's MerkleDistributor, read from the factory at transfer time with
   `distributorOf(LAUNCH_NUMBER)`.

That covers exactly the launch's flows: factory to distributor, distributor to claimant, factory
to PoolManager (seed), PoolManager to trader (buy) and trader to PoolManager (sell). The lookup is
a `staticcall`; if the factory has no code or the call fails, no distributor is exempt and the
transfer is taxed as usual, so the token never bricks on a factory problem.

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
- Exemption is by address, not by caller: a transfer *to* the factory or PoolManager is also
  delivered whole. This is intentional, so sells into the pool settle exactly.
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
conservation check), every launch-exempt flow in both the unset and set distributor states,
robustness when the factory is an EOA or its lookup reverts, the revert paths (short balance,
short allowance, zero recipient, factory pulling without allowance), the absence of any
mint/admin surface, and a scan of the runtime for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`.

```sh
forge build
forge test
forge fmt --check
```

Tests read no environment variables and pass in any order or in parallel. Tests passing is not a
security audit; an independent adversarial review is expected before the launch is admitted.
