# OG Club clubs, staking, furniture and raffles

OG Club awards ERC-1155 furniture through raffles paid with nontransferable points
accrued by staking OG. There are no lootboxes or token-paid furniture purchases.
`OGClubClubs` provides transferable ERC-721 rooms linked one-to-one to Swarm Pepes, bought and expanded with OG. Furniture can be
placed in a room permanently; the on-chain layout and its contents follow the
club when it is sold. Only OGClubClubs changes application behavior from the delivered
clubs repository at `292e20dec8afa05dc98367c8a9f47bd39a4b66a5`. Furniture, staking,
farm vault, raffle, MockOG and the existing libraries are unchanged.
This Foundry project uses the existing Solidity 0.8.26/Cancun configuration and
vendored OpenZeppelin 5.0.2 / forge-std 1.9.7 dependencies ([VENDOR.md](VENDOR.md)).
Builds and tests require no RPC, secrets, FFI, or downloaded dependencies.

## Contracts and configuration

All constructors are nonpayable, use explicit owners, and make no dependency
calls. They can run on an empty chain through the launch factory. Contracts are
immutable implementations, without proxies, upgrades, transfer pauses or owner sweeps.
Ownership uses OpenZeppelin's two-step transfer. Libraries are internal/inlined.

| Contract | Constructor arguments, in order |
| --- | --- |
| `MockOG` | initial recipient (Sepolia/local only) |
| `OGClubFurniture` | owner, initial royalty receiver |
| `OGClubFarmVault` | token, owner |
| `OGClubStaking` | token, immutable vault, owner, pointsPerTokenDay |
| `OGClubRaffle` | staking, furniture, owner, immutable raffleNotice |
| `MockSwarmPepe` | none (public mint, Sepolia/local only) |
| `OGClubClubs` | token, vault, price, furniture, owner, royaltyReceiver, pepes, delegates, level2Price, level3Price, level4Price |

The supplied `launch.json` is for **Sepolia, chain ID 11155111**, and deploys these
seven contracts in that order. `$owner` is the launch's configured owner
(`0x5b95a971b4583a5f011e9da082acdd679b870d06`); contract
references resolve to the preceding deployments. MockOG deliberately has
unrestricted minting, so anyone can acquire arbitrary stake and raffle points on
this test network. **MockOG is Sepolia-only** (local tests also use it), and its
initial trillion-token supply is not a cap. MockSwarmPepe is also Sepolia/local-only:
anyone can call `mint(to, pepeId)` for an unminted ID. Do not reuse
this manifest for mainnet.

The selected testnet accrual rate is **1e18 point units per whole token per day**
(one point); `Deploy.DEFAULT_POINTS_PER_TOKEN_DAY` names this default. Ticket
prices are owner-announced point amounts in each pool, not an ERC-20 payment.
Other fixed limits are three blocks for `TARGET_DELAY`, 32 pools and 128 total
prize lines per raffle, and 30 days for the maximum raffle notice.

## Owner setup and mainnet handoff

The factory performs constructor deployments only. **It cannot grant the two
raffle roles.** After deployment, the configured owner must execute these calls,
using the confirmed deployed raffle address, before creating the first raffle:

1. `furniture.grantMinter(raffle)` as the furniture's **first successful grant**.
2. `staking.grantSpender(raffle)` as staking's **first successful grant**.
3. Verify `minters(raffle)` and `spenders(raffle)` are true, set the furniture
   base URI, then create the announced raffles.

The first grant in each contract is immediate and permanently spends that
contract's bootstrap. Granting another address first makes the raffle wait. All
later grants, including re-grants of revoked roles, are seven-day proposals.
Anyone can activate in `[activatesAt, activatesAt + 7 days]`, inclusive. At the
next second the proposal is absent for activation/cancellation; its raw mapping
value may remain until a new proposal or revocation. Re-proposing restarts the
full delay. Cancel only removes a live proposal; revoke immediately clears both
permission and any proposal. Neither supply nor ownership handover resets this.

For a separate **mainnet** launch:

- Use the **existing OG token**, never deploy MockOG. The actual token address
  is an operator input, not a guessed address in this repository.
- Use a **fresh deployer** and set **OWNER to a Safe**. The deployer/factory gains
  no ownership and cannot perform the Safe's role grants.
- Set **RAFFLE_NOTICE=604800** (seven days). Sepolia uses zero.
- `script/Deploy.s.sol` takes `TOKEN`, `OWNER`, `RAFFLE_NOTICE`, and optionally
  `POINTS_PER_TOKEN_DAY` (default 1e18). Its `deploy` helper builds the four
  production applications; `deploySepolia` additionally creates MockOG and is
  restricted to Sepolia/local chain IDs. Both leave role grants to the owner.
  This existing script remains the raffle-stack helper; the separate club
  scripts described below add the new application.

No contract has been deployed or broadcast as part of this work.

## Clubs: minting by Swarm Pepe

Clubs are named **OG Club Clubs**, symbol **OGCLUBS**. Approve exactly `price`
OG units, then call `mintClub(pepeId)`. The caller must own that Swarm Pepe or
be authorized by the current holder through delegate.xyz v2's
`checkDelegateForERC721(caller, holder, pepes, pepeId, bytes32(0))`. Ordinary
ERC-721 transfer approval is not mint authorization. The supplied registry is
`0x00000000000000447e69651d841bD8D104Bed493`; a constructor registry address of
zero explicitly disables delegation. Holder minting does not query the registry.
The registry must be available on the target chain for delegate minting.

The caller pays and receives the club through safe ERC-721 delivery. The club ID
**equals the Pepe ID**, including zero if the collection has that ID; IDs are
not sequential. Each Pepe can mint only once, ever. Selling either NFT does not
reset `clubsMinted(pepeId)`, and the club can subsequently trade independently
of the Pepe. `mintClubTo` and the no-argument mint function have been removed.
The sale starts closed. The owner can close new mints without restricting club
transfers, upgrades or furniture placement. Minting and upgrades are reentrancy
guarded, and neither has a free owner path.

Each mint or upgrade transfers `floor(payment / 2)` directly from the payer to
`0x000000000000000000000000000000000000dEaD`, with the remainder sent directly
to the immutable farm vault. Odd-price dust goes to the vault. This sink transfer
does not reduce the ERC-20's reported supply. Final increases at both recipients
and the payer's total debit must match exactly; any failure rolls back payment,
allowance use and club state. Constructors reject a zero vault, the predicted
club address, the burn sink, the OG token address and the furniture address.
The mainnet script also checks that the live farm vault uses the configured OG.

Use a standard fixed-balance OG token. Transfer taxes, sender fees, rebasing and
dishonest balance reporting are unsupported. No-return ERC-20s are supported by
SafeERC20. Payments never pass through the club contract. Unsolicited ERC-20
donations remain possible and irrecoverable; the zero-balance invariant covers
protocol operations. Revenue increases the vault's season budget under its
unchanged 50% allocation rule.

## Room levels and placement

Every club starts at level 1, with `(0,0)` the fixed back corner. The four
constant floor masks use bit `y * 16 + x`; every level contains the preceding
floor. Upgrades preserve all existing pieces and occupied tiles.

| Level | Floor | Wall side 0 length | Wall side 1 length | Price to reach level |
| --- | --- | ---: | ---: | ---: |
| 1 | `x < 10, y < 10` | 10 | 10 | Mint: 100,000 OG |
| 2 | `x < 14, y < 10` | 14 | 10 | 200,000 OG |
| 3 | Level 2 plus `x < 10, y < 16` (an L) | 14 | 16 | 400,000 OG |
| 4 | `x < 16, y < 16` | 16 | 16 | 800,000 OG |

These Sepolia prices use 18 decimals; the three upgrade prices are also the
specified mainnet values. Mint price remains an explicit constructor input.
`upgradeClub(clubId)` requires the current club holder, its token-approved account
or an operator approved for all. **The caller pays**, including an approved
operator. Approve `upgradePrice(levelOf(clubId))` before calling. Prices are
immutable and positive. `upgradePrice(4)` returns zero; another upgrade reverts
`MaxLevel`. Level arguments outside 1–4 revert `BadLevel`.

To place furniture, transfer **one** unit of the configured furniture contract:

```solidity
furniture.safeTransferFrom(
    from,
    address(clubs),
    furnitureId,
    1,
    abi.encode(uint256(clubId), uint8(x), uint8(y), uint8(rot))
);
```

First, the owner registers `setFootprint(id, w, h, wall)`. Floor dimensions are
1–4; wall width is 1–4 and its height must be 1. Dimensions and the wall flag
can change until any club successfully places that ID. That first placement
locks the definition globally forever; rejected placements do not lock it.
Catalogue IDs, including zero, are owner-configured. A club may hold **only one
permanent piece of each ID**, floor or wall. `AlreadyHasDesign` rejects a second
copy, including after a club transfer. Other clubs may hold the same design.

For a floor piece, rotations 0–3 are allowed; 1 and 3 swap width and height.
The entire rectangle must lie inside the current level's mask, avoid occupied
floor tiles, and keep `(0,4)` and `(1,4)` free at every level. In particular, a
rectangle anchored in the level-3 L cannot extend into its missing corner.
The contract uses one uint256 floor bitmap per club.

For a wall piece, interpret `rot` as side 0 or 1, `x` as its starting position
along the wall, and require `y == 0`. Side 0 runs along `y = 0` (positions x);
side 1 runs along `x = 0` (positions y). The width must fit the side's current
length and must not overlap another piece on that side. **Side 1 position 4 is
the door**: width 2 starting at 3 or 4 fails, starting at 5 fits. Each side has
its own uint32 occupancy bitmap; floor and both walls are independent. A fully
expanded club can reach `MAX_PIECES = 285`: 254 distinct one-tile floor designs,
16 one-wide designs on side 0, and 15 on side 1. A further fresh design reverts
`ClubFull`. The test reaches this cap through real transfers without storage cheats.

Placement authenticates the ERC-1155 **`from` address** as club holder or an
approved club account, and separately relies on normal furniture transfer
approval. A furniture operator can therefore permanently place its principal's
pieces into that principal's club without a separate club approval. A club
approval does not authorize spending someone else's furniture. These approvals
grant permanent-placement power and should be given accordingly.

Only the immutable furniture contract can call the single-item hook. Data must
be exactly four canonical ABI words; wrong lengths or uint8 words over 255
revert `BadPlacementData`. Bad geometry/rotation uses `OutOfRoom`, door coverage
uses `BlocksDoor`, and occupied floor or wall space uses `TileTaken`. The batch
hook rejects all calls. The unchanged OpenZeppelin 5.0.2 ERC-1155 routes a
one-element batch through the single-item hook, so it accepts one valid placement;
empty and multi-element batches revert. Minting furniture directly into clubs
fails. Furniture never leaves club custody: no removal, relocation, withdrawal,
ERC-1155 approval or privileged seizure path exists.

## Rendering, metadata and owner powers

`ClubMinted(id, to, payer, burned, toVault, pepeId)` records the initial recipient
before safe delivery can trigger a receiver's onward transfer or placement.
`ClubUpgraded(clubId, newLevel, payer, burned, toVault)` and
`FurniturePlaced(clubId, furnitureId, x, y, rot, index, wall)` are followed by
ERC-4906 `MetadataUpdate(clubId)`. Placement indices start at zero.

| View | Result |
| --- | --- |
| `clubsMinted(pepeId)` | Whether this Pepe has ever minted a club |
| `levelOf(clubId)`, `floorMask(level)`, `upgradePrice(currentLevel)` | Level, geometry and next price |
| `piecesOf(clubId)` | Ordered `Piece { furnitureId, x, y, rot, wall }[]` |
| `pieceCount(clubId)`, `hasDesign(clubId, id)` | Piece count and design membership |
| `tileTaken(clubId, x, y)` | Floor occupancy; reserved door tiles return false |
| `wallTaken(clubId, side, position)` | Wall occupancy; side-1 door position returns false |
| `footprintOf(id)` | `(uint8 w, uint8 h, bool set, bool locked, bool wall)` |
| `tokenByIndex`, `tokenOfOwnerByIndex`, `totalSupply` | ERC-721 enumeration, including sparse IDs |
| `token`, `vault`, `price`, `furniture`, `pepes`, `delegates`, `saleOpen` | Payment, dependency and sale configuration |

Club layout views reject missing clubs with `NonexistentToken`; occupancy views
reject coordinates outside the current floor or wall. Transfers preserve level,
layout and design membership, clear token approvals and change who can place or
upgrade. Pepe ownership is only checked at mint; subsequent club rights depend
on the club NFT.

The owner can set the metadata prefix until `freezeMetadata()`. `tokenURI(id)`
is `baseURI + decimal id + ".json"`, initially e.g. `1.json`. Prefix changes and
freezing emit `BatchMetadataUpdate(0, uint256.max)` to include Pepe ID zero.
Freezing survives ownership transfers and freezes the **URI prefix**, not
layouts, levels, unused footprints or content hosted at a mutable URL. Royalties
start at 500 bps (5%); the owner may set a nonzero receiver and 0–1000 bps.
Marketplace enforcement is external. Ownable2Step retains its standard transfer,
cancellation and renunciation behavior. Ownership gives no free club, transfer
privilege, furniture withdrawal or payment sweep.

## Club deployment preparation

The Sepolia `launch.json` preserves the five original applications, adds
`MockSwarmPepe`, and deploys clubs with backward dependency references. The club
constructor has **eleven scalar arguments**. The launch format requires string
words and does not support array constructor inputs, so the three upgrade prices
are separate `uint256` arguments in level 2, 3, 4 order. This changes only their
constructor representation; prices and payment behavior are unchanged. The
mainnet script still accepts the three-value `UPGRADE_PRICES` array. The
manifest/ABI tests check eleven inputs, eleven encoded words, string-only values
and the 4,000-character notes limit. All constructors are nonpayable and make no
dependency calls.

The factory only deploys constructors. Clubs start with the **sale closed**, URI
empty and footprints unset. The owner configures the real catalogue and metadata,
then opens the sale. These ordinary owner calls are not initialization calls.
Clubs need neither a minter nor a spender grant; the raffle's first grants stay
reserved for the confirmed raffle address.

`script/DeployClubs.s.sol` contains two operator-run scripts:

| Script | Inputs and behavior |
| --- | --- |
| `DeployClubsSepolia` | Creates MockOG, furniture, farm vault, MockSwarmPepe and clubs. Uses the real v2 registry, mint price 100,000e18 and upgrade prices 200,000e18 / 400,000e18 / 800,000e18. Takes `OWNER`, optional `ROYALTY_RECEIVER` (defaults to owner) and optional `FOOTPRINTS_JSON`. Broadcasts as the testnet owner, configures footprints and opens the sale. Allows Sepolia or local 31337. |
| `DeployClubsMainnet` | Takes `OG_TOKEN`, `FARM_VAULT`, `CLUB_PRICE`, `FURNITURE`, `OWNER`, `ROYALTY_RECEIVER`, `SWARM_PEPES`, `DELEGATE_REGISTRY`, `UPGRADE_PRICES`, `DEPLOYER_KEY`, and optional `FOOTPRINTS_JSON`. Checks the live vault's `token()` before deployment. Deploys only clubs from `DEPLOYER_KEY`, with `OWNER` passed directly to the constructor. Leaves sale closed and footprints unset; prints the owner configuration calldata. Allows mainnet or local 31337. |

For mainnet, `UPGRADE_PRICES` is the comma-separated base-unit string
`200000000000000000000000,400000000000000000000000,800000000000000000000000`.
`DELEGATE_REGISTRY` is the supplied v2 address, or zero if the operator deliberately
disables delegation. The mainnet script never tries to sign as OWNER: a Safe can
own clubs from construction and execute the printed footprint and sale calls
through its normal authorization flow. It never deploys either test mock. Both
scripts print addresses and ABI constructor arguments, never the deployer key.
This repository preparation does not read deployment keys or broadcast transactions.

Footprint JSON contains `[furnitureId, width, height, wall]` rows with numeric
wall flag 0 or 1. Parsing rejects malformed rows, negative values, invalid
sizes/flags and duplicate IDs before deployment. The supplied JSON is explicitly
an **example Sepolia catalogue**, including widths 1–4 on walls; replace its IDs
and dimensions with the real owner-approved catalogue for production. These
sample IDs are not constructor defaults or installed by the factory manifest.
`[]` leaves all footprints unset. Pass file contents using `FOOTPRINTS_JSON`,
which requires no changes to Foundry filesystem permissions. For local simulation:

```sh
FOOTPRINTS_JSON="$(cat script/club-footprints.json)" \
  forge script script/DeployClubs.s.sol:DeployClubsSepolia \
  --chain-id 11155111 --sender "$OWNER"
```

The Sepolia script opens even with an empty catalogue. The mainnet script leaves
review and opening to the owner. **MockOG is Sepolia-only**, publicly mintable,
and unsuitable for production payments; MockSwarmPepe is likewise a test mock.
Keep the raffle's first-grant handoff and independent draw monitoring described
above. See [ADAPTATION.md](ADAPTATION.md) for audit reproductions and fixes.

## Staking and points

Approve the staking contract, then call `stake(amount)`. The stake credited is
its actual token balance increase, so a fee deducted from a deposit cannot mint
extra stake or points. `unstake(amount)` is available immediately, including in
the same block as a stake. The immutable vault receives
`ceil(amount * 100 / 10000)` token units and the remaining units go to the staker.
A one-unit withdrawal pays one unit in fees; splitting withdrawals cannot avoid
fees. No points are awarded on unstaked balances.

For a balance held over `seconds`, accrual in point-wei is:

```text
balanceInTokenUnits * pointsPerTokenDay * seconds / (10**tokenDecimals * 86400)
```

`pointsOf(account)` includes pending accrual. Balances are checkpointed before
stake changes and point spending. Division remainders persist, including through
a full exit, so many small checkpoints have exactly the same result as one large
checkpoint. `spendPoints(account, amount)` is available only to authorized
spenders, and never makes an external token transfer. Points have no transfer,
approval, mint, or admin-adjustment function. Zero-point spends are harmless
checkpoints that retain fractions.

Each account occupies **two slots**: `uint128 balance`, `uint48 updatedAt` and
`uint80 remainder` packed together, plus `uint256 points`. The per-account stake
limit is `2**128 - 1` token units; the maximum rate is `2**96 - 1` point units per
token-day. Checked casts and full-precision multiplication prevent truncation and
intermediate overflow. The timestamp range extends to `2**48 - 1` seconds.

Token decimals (0–18, including OG/MockOG's 18) are read and fixed on the first
stake, not in the constructor. This supports ordinary fixed-balance ERC-20s with
stable metadata, including tokens returning no transfer boolean and fees deducted
from the transferred amount. Outbound transfers must debit exactly the requested
amount; extra sender-side fees revert atomically. Recipients of a taxed token
receive less after that token's own fee. Rebasing/reflection tokens and dishonest
balance reporting are unsupported. Unsolicited transfers to staking are surplus,
not stake or points, and cannot be swept. The balance-equals-total-staked invariant
applies to stake/unstake flows without unsolicited donations or rebases.

## Raffles, winning tickets and claims

The owner calls `createRaffle(opensAt, closesAt, pools)` with a nonempty pool list.
Opening must be at least `now + raffleNotice`; closing must be later. Each pool
has a display-only `uint8 tier`, positive point ticket price, a per-wallet ticket
cap (zero means unlimited), and one or more `{itemId, quantity}` prizes with
positive quantities. Item ID zero and repeated item IDs are supported. Caps are
per wallet **per pool per raffle**, not identity-based or Sybil resistant.
Quantities and total sold tickets per pool are at most `2**48 - 1`.

The terms and prize list cannot be edited. The owner can cancel only **before**
opening, when entry has not yet been possible. `enter(raffleId, poolId, tickets)`
works during `[opensAt, closesAt)`, spends `tickets * ticketPrice`, and appends an
entry for the sender. It records the contiguous half-open range `[first, end)` in
one storage slot, regardless of the ticket count. Ticket indices, pool indices,
entry indices and win indices start at zero; raffle IDs start at one. Tickets
cannot be transferred. Failed spending rolls back the range and cap update.

At or after closing, anyone calls `commitDraw(raffleId)` to target the block
**three blocks ahead**. Anyone may then call `draw(raffleId, header)` when
`target < block.number <= target + 256`. The entire canonical RLP header must
hash to `blockhash(target)`, and its decoded block number must equal the target.
Its `prevRandao` is stored as the seed, even when zero. Drawing never mints or
iterates over pools, tickets or entrants. After drawing the seed cannot change.

Let `W = min(prizes, ticketsSold)` for a pool. The valid wins are exactly
`k = 0 ... W-1`. `winningTicket(raffleId, pool, k)` evaluates an eight-round
Keccak Feistel permutation with cycle walking over ticket indices. `prizeOf`
evaluates a **separate, domain-separated permutation** over the expanded prize
positions and locates its item by binary search of cumulative quantities.
Thus each ticket wins at most once, wallets may win multiple times, and a pool
with enough tickets awards every listed quantity exactly. With fewer tickets,
the unused prize positions are random too; they are never minted.

Both permutations also bind the seed to the chain, raffle contract, raffle ID
and pool. Cycle walking uses the next power-of-four domain (less than four times
the requested size). It is an invertible pseudorandom selection without modulo
bias or a table of entrants. Walk length depends on the seed; it has a short
expected cost, not a fixed worst-case gas bound.

Anyone calls `claim(raffleId, pool, wins)`, where each win is `{k, entry}` and the
supplied entry must contain `winningTicket(k)`. It pays the entry wallet, never
the caller. Claimed win indices are recorded in a bitmap. Adjacent claims for
the same wallet share one `furniture.mintBatch`; grouping by wallet saves gas.
The on-chain work grows with the **wins submitted**, independently of entrant
and ticket counts (prize lookup is bounded by 128 lines). Read `Entered` events
or `getEntry` to locate ticket ranges off chain.

`claimTo(raffleId, pool, wins, to)` requires the caller to be the wallet of **every**
supplied entry and a nonzero recipient. It lets contract wallets redirect prizes.
Receiver or mint-permission failures roll back that transaction's claims and
mints; they remain retryable with the same results indefinitely. Submit subsets
to isolate a rejecting recipient. Claims are guarded against receiver reentrancy.

### Randomness and owner trust

This is the requested on-chain future-block randomness, not an external VRF.
Validators can influence/censor the target block and its prevRandao, and callers
can choose when to commit after closing. If **nobody draws** by target + 256,
anyone can re-commit beginning at target + 257, choosing a new future target.
An operator who withholds unfavorable draws, especially with censorship or no
independent keeper, can obtain another seed and bias results. Permissionless
drawing lets an independent party preserve an available outcome; it does not
eliminate these biases. Operators must monitor closed raffles and retrieve
headers inside the blockhash window. A finalized draw cannot be retargeted.

Owners cannot directly change stakes, point balances or drawn outcomes. They do
control spender authorization; an authorized spender can consume any account's
points, so later grants need scrutiny during their notice window. Furniture
minters can mint arbitrary IDs/quantities outside raffles. Revoking the raffle's
roles stops new point spending or prize delivery until reinstated, although
staking exits remain available and drawn claims retain their results. Prize
quantities are per pool, not global collection scarcity limits.

Furniture retains its original supply tracking, ERC-1155 transfers, metadata URI
format, permanent metadata freeze, and ERC-2981 royalties: initially 5%, owner
adjustable up to 10%. Its owner has no confiscation, privileged transfer or burn
right. Royalties are informational; marketplace enforcement is external.

## Farming vault

Unstake fees accumulate in `OGClubFarmVault`. The owner publishes a farming
allocation with `proposeSeason(root, total)`. Total must be positive and at most
`floor((tokenBalance - reserved) / 2)`. It is reserved immediately, claims open
three days later, and the next proposal must wait at least seven days after the
previous proposal even if that proposal was canceled.

Use sorted-pair OpenZeppelin Merkle trees (compatible with StandardMerkleTree)
and exactly this double-hashed leaf, with the types shown:

```solidity
keccak256(bytes.concat(keccak256(abi.encode(
    uint256(seasonId), address(account), uint256(amount)
))))
```

Season IDs begin at one; generate allocations for the correct ID. Include each
account once per season, since the contract pays only one allocation per account.
Keep the sum of allocations equal to `total`; a root alone cannot prove that sum,
and the contract refuses claims above the remaining season budget. Anyone may
submit `claim(seasonId, account, amount, proof)`, which pays only that account.
There is no relayer redirect. Zero allocations are valid but unnecessary.

`cancelSeason` is owner-only and works strictly before claims open. Claims are
valid during `[opensAt, opensAt + 90 days)`. At exactly `opensAt + 90 days`, claims
stop and the owner may call `releaseSeason` to unreserve the unpaid balance.
Cancellation and release **never transfer tokens**; the released funds become
eligible for later seasons. The owner has no other token-moving function.
The owner chooses recipients/root/total and could include itself in a valid
season: this remains a trust assumption subject to the budget and time limits.

## Header encoder and offline fixtures

`script/encode_header.py` takes an `eth_getBlockByNumber` JSON object or response
wrapper from a file or stdin. It encodes fields after `requestsHash` in the order
**blockAccessListHash, slotNumber** (slotNumber is an integer). It refuses gaps
and all unknown keys except explicitly allowlisted non-header RPC metadata.

```sh
python3 script/encode_header.py test/fixtures/sepolia-11921684.json
```

Sepolia block **11921684** has published hash
`0x0beea75b48cae0d6c13bf5a289c3f64ea9e4473bfacd2f9709d5c0a827e73629`.
The JSON and embedded RLP are checked both against that hash and through raffle
`draw`. Existing real Shanghai, Cancun and Prague fixtures remain tested. See
[test/fixtures/SOURCES.md](test/fixtures/SOURCES.md) for provenance. Always compare
`cast keccak` of the encoded header with the published hash before submitting it.

## Gas and EIP-8037

The project still targets Cancun. These are isolated-call measurements, followed
by a **storage-cost projection**, not a claim to execute the future fork.
[EIP-8037](https://eips.ethereum.org/EIPS/eip-8037) specifies 64 state bytes per
new storage slot and CPSB 1530: **97,920 state gas per fresh slot**, replacing
20,000 Cancun gas. The projected total adds **77,920 per durable fresh slot**
across all callees. Companion EIPs, transaction intrinsic/calldata gas and
refunds are not modeled; these are gross call costs, not receipt or gas-limit
estimates. ERC-20 transfers and ERC-1155 receiver behavior can change costs.

| Operation | Measured Cancun call gas | Fresh slots | EIP-8037 state gas | Storage-repriced call gas |
| --- | ---: | ---: | ---: | ---: |
| First-ever stake, fresh staker | 120,547 | 3 | 293,760 | 354,307 |
| Partial unstake, first checkpoint and first vault fee | 110,662 | 2 | 195,840 | 266,502 |
| First entry, 10 tickets, first point checkpoint | 155,364 | 4 | 391,680 | 467,044 |
| Draw, 23-field header | 74,312 | 1 | 97,920 | 152,232 |
| Claim 1 win to a fresh furniture wallet | 160,885 | 4 | 391,680 | 472,565 |
| Claim 10 distinct items to a fresh furniture wallet | 816,170 | 22 | 2,154,240 | 2,530,410 |

Measured with MockOG, 1e18 accrual, preapproved spending, and freshly granted
roles. Claim rows start with zero collection supply, mint to one EOA, and set the
first claim bitmap word. The ten-win pool has ten different IDs, so it creates
ten recipient balances and ten per-ID supply slots; repeated IDs cost less.
Draw uses the deterministic synthetic header in the gas test; real header sizes
change decoding costs. Permutation costs vary with the seed and domain sizes.
The two-slot staking account, one-slot entry and claim bitmap limit new state.
Reproduce both measurements and the asserted new-slot counts:

```sh
forge test --match-contract GasTest --isolate -vv
```

## Local checks

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5c29c56089b215dc03f374d8592a6045dee713ee11c3c0babe257c2a9594b991 forge test
forge fmt --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py' -v
```

Tests cover accrual fractions and packed bounds, taxed/nonstandard tokens,
reentrancy, spender/minter lapse, raffle time/cap/header boundaries, retargeting,
permutation bijections, exact prize quantities, wrong entries and duplicate
claims, contract-wallet redirection, vault proofs and reserve deadlines. Stateful
invariants check stakes against token custody, independently integrated accrual
minus spending, and vault balances against all remaining reservations. The
retained furniture suite checks supply, transfer authorization, royalties and
frozen metadata. [ADAPTATION.md](ADAPTATION.md) records the changes and audit
reproductions.

Club tests cover exact payment splitting and rollback, safe receivers,
reentrancy, real furniture integration, all rotations, authorization, permanent
custody, metadata, royalties and script/factory deployment. Fuzz tests compare
random levels, floor/wall placements, footprints, rotations and duplicate designs
against an independent cell grid. Stateful club
invariants exercise Pepe ownership/delegation, minting, upgrades, rejected
placements, approvals, sale changes and both NFT transfers,
checking payment conservation, zero protocol OG custody, and an exact match
between per-ID furniture holdings and all clubs' ordered layouts.
