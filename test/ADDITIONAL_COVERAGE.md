# Additional contributor tests

These tests extend the delivered suite without changing application code,
configuration, deployment inputs, or dependencies. They run offline with the
existing Foundry and OpenZeppelin dependencies.

| File | Additional coverage |
| --- | --- |
| `FeeFlowInvariant.t.sol` | Four actors stake, partially/full unstake, spend points, propose four-leaf Merkle seasons, partially claim, cancel, release, and restake payouts. Separate campaigns use ordinary and 7.5% recipient-tax tokens, six token decimals, and a rate of `3e18 + 17`. |
| `RaffleSequenceInvariant.t.sol` | Four actors and up to four raffles with two pools each; capped/uncapped entry, cancellation, time/block advancement, commit, expired targets, valid/corrupted headers, permissionless claims, authorized redirection, and invalid/duplicate claims. |
| `RaffleAtomicity.t.sol` | Late failures after earlier wallet mints, a rejecting final recipient and its recovery, failed creation after an earlier pool was stored, cumulative prize-count overflow, independent claim bitmaps, and shuffled/fragmented multi-item claims with duplicate item IDs. |
| `TokenFailureAtomicity.t.sol` | A token that mutates balances then returns false; failure after the unstake fee has already transferred; packed stake overflow; dust exits; payout rollback after another allocation was paid; sender surcharges with multiple reservations; and no-return token payouts. |
| `ClubsAdversarial.t.sol` | Independent OGClubClubs edge cases: uint8 extremes and rot 4..255, exact right/bottom edges, rotation swaps for an asymmetric 3x1, every shape touching either door tile, a fuzzed single-tile door rule, single-tile overlaps and touching edges, non-canonical/short/long/packed layout data, missing club ids 0/max, minting furniture straight into the contract, the hook called directly, amounts 0/2, footprint revision until first placement, club approval vs approval-for-all and revocation, cross-club approval, the contract owner's lack of placement rights, a filled 98-tile room, a receiver that places during its mint callback but cannot mint again, non-receiver contracts, exact-price allowance/balance boundaries, a fuzzed split for any price, metadata/royalty bounds, the pending owner, renounced ownership and interface IDs. |
| `ClubsAdversarialInvariant.t.sol` | Four actors mint clubs for their Pepes, transfer clubs, grant/revoke club approvals, place as holder, approved spender, stranger or ERC-1155 operator into existing and missing clubs at bounded, partly off-grid positions, while the owner sets valid and invalid footprints. An independent tile model decides each placement's outcome. A rejection must give a reason that really holds and change nothing. Invariants: no $OG ever held, burn/vault split conserved, pieces equal custody per id, stored layouts fit, never overlap or cover the door and agree with `tileTaken`, and locked footprints never change. |

The fee-flow campaigns use a closed token economy: each actor receives its
initial tokens once, and the vault receives only unstake fees. Ghost balances
track token transfers and burns, not contract-reported stakes. Points are checked
against the complete time integral of independently tracked balances, with one
final division, rather than reproducing the implementation's checkpoint and
remainder algorithm. Every season's reserve is independently summed from unpaid
allocations. Failed calls leave these models unchanged. At the end of each
sequence, every actor must still be able to withdraw its entire stake.

The raffle campaign records successful purchases and intended NFT recipients.
At drawing, it checks distinct tickets, ticket bounds, winner counts, and prize
multisets without implementing the Feistel algorithm again. It snapshots these
validated results and checks their stability after subsequent actions. Minted
supply and each wallet's receipts must equal consumed win bits. After every
random history, it completes all noncancelled raffles and claims all remaining
wins; total supply must equal the sum of their winner counts. Synthetic headers
are authenticated using `vm.setBlockhash`, with a consistent header per block
number. The existing real Sepolia fixture tests remain in the full suite.

Each new invariant campaign runs 128 sequences of depth 96 with unexpected
reverts treated as failures. Selectors target only the handlers. Known economic
transitions are seeded so the invariants never pass merely because no stake,
season, draw, or claim exists. Intentional invalid actions assert their exact
custom errors; a successful invalid action fails the test. The fragmented-claim
property runs 512 cases. Inputs are bounded without `vm.assume` or `vm.setEnv`.

Scope limits: these are finite fuzz campaigns, not a proof of statistical
uniformity, censorship resistance, or correctness of rebasing/dishonest tokens.
The fee-flow campaigns omit unsolicited staking donations, as the existing
donation regression covers their separation from stake accounting. They test
recipient taxes, not support for extra sender debits; the latter must revert.

Run from the repository root:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5c29c56089b215dc03f374d8592a6045dee713ee11c3c0babe257c2a9594b991 forge test
forge fmt --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py' -v
```

The launch adaptation also adds `ClubsLaunch.t.sol` for Pepe/delegate minting,
levels and receipts, walls, unique designs, the 285-piece reachable cap, and audit
regressions. `ClubsLaunchInvariant.t.sol` uses `LaunchLayoutModel.sol` to exercise
all levels and both walls, independently reconstructing each layout and checking
rejected-state preservation, single mint per Pepe and mint/upgrade conservation.
Legacy level-1 tests now use distinct furniture IDs for multiple placements.

The two legacy club invariant handlers check the complete affected board after
each mint, transfer and placement attempt. Global invariants still reconstruct
all layouts and compare to the independent grids after every action; they fetch
each grid once instead of once per cell. Every sequence ends with an exhaustive
occupancy-view sweep. Runs and depths are unchanged. The manifest tests also
reject nested constructor values, ABI argument-count mismatches and notes
longer than 4,000 characters.
