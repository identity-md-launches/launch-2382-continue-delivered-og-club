# OG Club Clubs launch adaptation

This continues the delivered clubs repository at
`292e20dec8afa05dc98367c8a9f47bd39a4b66a5`. Only OGClubClubs changes existing
application behavior. OGClubFurniture, OGClubFarmVault, OGClubStaking,
OGClubRaffle, MockOG, the existing libraries and the original raffle deployment
script retain their source. Build configuration and dependencies are unchanged.
No packages, submodules or network dependencies were added. All checks run
locally without RPC access or deployment credentials; no live deployment,
broadcast, signing or factory call was performed.

The supplied protected constructor/runtime/ownership checks and pinned security
and L2 references were read as task inputs. This is a Sepolia application-only
launch; no L2-specific changes, launch token, proxy or migration are introduced.
The requester explicitly requires launch.json to be updated, overriding the
quoted background that would leave it to a later manifest step.

## Changes and reasons

| Files | Change and reason |
| --- | --- |
| `src/OGClubClubs.sol` | Replaced both old mint entry points with `mintClub(pepeId)`. The current Pepe holder or a delegate.xyz v2 delegate pays and receives the club. Immutable `pepes` and optional `delegates` dependencies, a permanent `clubsMinted` flag, and Pepe-equal club IDs enforce one club per Pepe ever. Missing Pepes revert through ERC721; transfer approval alone is insufficient. Constructor rejects zero Pepes. |
| `src/interfaces/IDelegateRegistry.sol` | Added only the v2 ERC721 query specified by the task. This is an interface, not a new deployable application or external library. Zero registry disables delegation; holders bypass the registry call. |
| `src/OGClubClubs.sol` | Added levels 1–4, four constant uint256 floor masks using bit `y*16+x`, a level view and immutable prices stored in three Solidity immutables from three scalar constructor arguments (levels 2, 3, 4), as required by the launch manifest format. `upgradeClub` requires the holder or club-approved account, is reentrancy guarded, charges the caller, and emits upgrade/metadata events. Each mask contains the previous level and floor door bits never move. |
| `src/OGClubClubs.sol` | Refactored the existing exact payment split/receipt checks into `_pay` for both minting and upgrades. Kept half rounded down to the burn sink, remainder to vault, final recipient checks and exact payer debit. Failures roll back level, eligibility, allowances and all transfers. No OG payment enters club custody. |
| `src/OGClubClubs.sol` | Added wall footprints with height 1, width 1–4, two independent uint32 occupancy maps, level-specific side lengths and the side-1 door exclusion. Placement keeps the same four-word ABI: wall `rot` is side, `x` is start, `y` must be zero. `Piece`, footprint views and events include the wall flag. Added `wallTaken` for rendering and verification. |
| `src/OGClubClubs.sol` | Added per-club design membership and `hasDesign`, with `AlreadyHasDesign` on any second copy. Membership follows club transfers. Footprint locking now also locks the wall flag globally. Preserved permanent custody and the existing ERC1155 `from` authorization rule. |
| `src/OGClubClubs.sol` | Rejected vault equal to the burn sink, token or furniture; retained zero and self rejection. Replaced the unreachable 100-piece cap with the reachable 285-piece cap. Added named `BadPlacementData` for length and noncanonical uint8 words. Moved ClubMinted before safe delivery so receiver activity cannot precede it. These resolve the reproduced review findings below. |
| `src/OGClubClubs.sol` | Metadata batch notifications now start at token ID zero because Pepe IDs need not start at one. Kept enumeration, royalties, URI-prefix freeze, two-step ownership and sale control. Closing mint sales does not stop upgrades, placements or transfers. Room level upgrades do not change contract code. |
| `src/mocks/MockSwarmPepe.sol` | Added the requested Sepolia/local public-mint ERC721 fixture. Its nonpayable constructor takes no arguments and confers no admin role. Public mint accepts a recipient and arbitrary unused ID, including zero, with safe delivery. The existing MockOG is untouched. Neither mock is deployed by the mainnet club script. |
| `script/DeployClubs.s.sol` | Sepolia now deploys the Pepe mock, uses the supplied real v2 registry and fixed 200,000e18 / 400,000e18 / 800,000e18 upgrade prices, loads wall-aware footprints and opens the test sale as before. Mainnet reads SWARM_PEPES, DELEGATE_REGISTRY and exactly three comma-separated UPGRADE_PRICES, checks the live vault token before deployment, broadcasts from DEPLOYER_KEY and passes OWNER directly to the constructor. A Safe is never a broadcaster. Owner setup calldata is printed for later execution and the sale stays closed. Both scripts print dependency addresses and constructor arguments. |
| `script/club-footprints.json` | Expanded the JSON row format to `[id,w,h,wall]`, using numeric wall flags 0/1. Added an explicitly documented Sepolia example catalogue with floor pieces and wall widths 1–4. Parsing validates dimensions, wall height/flag, unsigned values, row length and uniqueness before deployment. Production catalogue values remain owner-settable and are not assumed by the factory manifest. |
| `launch.json` | Preserved the five original application deployments and arguments; inserted MockSwarmPepe before clubs and added the Pepe, delegation and upgrade-price inputs. There are seven applications, with backward references and explicit owners. The club constructor and manifest both have eleven scalar arguments. Array inputs are unsupported by this launch format, so the three prices are separate uint256 inputs; script configuration retains its three-element array. Notes fit the 4,000-character schema limit. Notes state MockOG is Sepolia-only, retain the raffle FIRST grantMinter/grantSpender handoff, and document club setup, prices, geometry and Safe deployment. |
| `README.md` | Documented mint authorization, immutable dependencies/prices, permanent mint eligibility, sparse IDs, levels, floor/wall geometry, unique designs, errors/events/views, payment accounting, owner powers, constructor-only setup and the two scripts. Retained the existing staking/raffle/vault documentation and required first grants. Both mocks are explicitly Sepolia/local-only. |
| `test/helpers/ClubsTestBase.sol`, existing club test files, `test/ImportedAudit.t.sol` | Updated constructor/placement APIs and Pepe ownership fixtures. Multiple-piece geometry tests now use distinct designs. Retained prior checks for receipts, approval and balance failure, nonstandard tokens, reentrancy, real furniture custody, receiver callbacks, metadata, royalties and owner limits. Legacy invariant campaigns still independently exercise level-1 behavior. Removed the synthetic storage cap test in favor of a real reachable fill. Existing audit tests for unchanged applications remain. |
| `test/ClubsLaunch.t.sol`, `test/helpers/ClubLaunchMocks.sol` | Added delegate, holder, missing/zero/max/sparse ID, once-ever mint, transfer and event-order tests; all new constructor rejections; levels, exact odd splits, no-return/taxed/callback token upgrades, approvals, masks, retained tiles and metadata events; walls, side lengths, doors, wall flag locks and independent occupancy; duplicate designs across clubs/transfers; 285 real distinct placements followed by ClubFull. The test registry binds all five authorization query arguments. |
| `test/ClubsLaunchInvariant.t.sol`, `test/helpers/LaunchLayoutModel.sol` | Added independent cell-by-cell floor/wall geometry for random levels, dimensions, positions, sides, rotations and repeated designs. Stateful actions mint, delegate, revoke, transfer both NFTs, approve club accounts, place via furniture operators, upgrade, deliberately short-pay and toggle sales. Invariants check exact once-per-Pepe identity, all mint/upgrade accounting, zero protocol OG custody, layouts, design uniqueness and exact per-ID furniture holdings. Rejected operations preserve modeled state. |
| `test/ClubsDeployment.t.sol` | Updated script, JSON and empty-chain constructor tests. Added wrong-token and missing vault rejection before the deployer's nonce changes; distinct deployer with contract owner; public mock mint; and one-call CREATE2 deployment of all seven manifest applications. Rehearses owner/dependency relationships, code size/opcode restrictions and the unchanged owner raffle bootstrap. |
| `test/test_launch.py` | Checks the seven entries against compiler ABIs, backward references, owner arguments and exact values. Regressions reject nested arrays, eleven manifest entries against the old nine-input ABI, and notes exceeding 4,000 characters. The delivered ABI and manifest each have eleven scalar inputs encoding to eleven words. |
| `test/ADDITIONAL_COVERAGE.md`, `ADAPTATION.md` | Updated the coverage map and recorded this assignment's changes, findings, verification and operational boundaries. |

## Imported review: reproduction and disposition

Before edits, six temporary tests in `test/scratch/ReviewBefore.t.sol` reproduced
the seven observations (one script test covered both script findings). All six
passed against the arriving source. That scratch source is not a deliverable;
permanent regression tests below check the corrected behavior. None of the
seven findings was dismissed as unreproduced.

| Finding ID | Evidence on arrival and fix |
| --- | --- |
| `ad9329f4fd554c5945626184d353fb9eca0e9639ff76f0e0b3b6e3c75d8a11ad` | A burn-sink vault deployed successfully but every paid mint failed UnexpectedTokenDebit. Constructor now rejects it. `ClubsPepeTest.test_NewConstructorRejections` and `ClubsMintTest.test_BurnSinkCannotAlsoBeVaultAndPayerCannotPayItself` cover rejection and retained self-payment protection. |
| `3982761c7a0bebea7ef4fdeee1d263f2af46862aa92c734bf1083b7581787afb` | Token and furniture vaults each deployed, minted successfully and received the vault half with no recovery path. Both addresses now fail construction; each is tested in `test_NewConstructorRejections`. |
| `30727c6c68a7ecd803df4138733a6dd4d4ea7504c8c2fcc1ad6e1649b00fe83b` | A 127-byte placement produced ERC1155InvalidReceiver(clubs) through OZ's empty-reason rewrite. `_decodePlacement` now raises BadPlacementData for wrong lengths and noncanonical uint8 words. `test_MissingClubAndMalformedDataCannotLockFurniture` and `test_MalformedDataAlwaysReverts` assert that selector and unchanged custody/layout. |
| `e02fed1a38a0ec09d9935f5199edd4486c3adde6f72f3f8f38edc0772c26bc3f` | The old mainnet script accepted a vault for another token and a mint sent OG into it. The script now checks token() before broadcasting. `test_MainnetScriptRejectsWrongVaultTokenBeforeDeploying` covers mismatched and nonexistent vaults and unchanged deployer nonce. Constructors still perform no external checks, as required by empty-chain deployment. |
| `cf38c9cdcc53a6984757e8675d0a6b91d131849f12669bf77ea92d96f860efe7` | Source inspection and a local broadcast trace confirmed construction used OWNER's nonce and footprint calls were sent as OWNER. A Safe cannot sign those EOA broadcasts. This consequence was not tested by a live signing attempt. The script now uses the separate key only for construction and prints owner calls; `test_MainnetScriptDeploysFromSeparateKeyWithContractOwnerAndLeavesSetupToOwner` proves the contract owner's address differs from the actual deployer and no owner signature is needed for deployment. |
| `6dbeb344162e18237ca3dcb5face799247f3abff537f2a13b698e8bd5e16ea4d` | Filling all 98 old usable tiles made further placements fail while the 100-piece guard remained unreachable. The requested level/wall geometry permits exactly 285 one-wide pieces. `test_ClubFullReachableAt285DistinctDesignsWithoutStorageCheats` reaches it through real ERC1155 transfers, checks every held design, and rejects the next fresh design with ClubFull. |
| `fc064cbb2f6461ace12f89b679f3be053ed017e256e4302a7affc04a39f37362` | A receiver transferred its freshly minted club onward before ClubMinted appeared. ClubMinted now precedes `_safeMint`. `test_AuditMintEventPrecedesReceiverTransfer` records and checks ordering and the final owner. Receiver placement and reentrant mint/upgrade rejection remain tested. |

## Boundaries and owner handoff

- The factory deploys constructors only. The owner must configure footprints and
  metadata and open the sale. The mainnet script prints those calls and never
  temporarily owns clubs. Sepolia's script retains owner-broadcast test setup.
- The raffle's first furniture grantMinter and staking grantSpender must target
  the confirmed raffle address. Their immediate bootstrap, later delays and
  draw-window monitoring remain unchanged and documented; clubs consume neither
  role. No code tries to initialize them through the factory.
- Sepolia uses both public mocks. Their public minting is intentional and not
  production scarcity. Mainnet addresses and the deployer key are operator
  script inputs; no production address or credential is invented here.
- The supplied delegate.xyz address is configured without a constructor code
  check. Local tests use a query-compatible mock; no live registry availability
  or production collection behavior is claimed. A zero registry is the explicit
  opt-out supported by the brief.
- Footprint examples are test data. The owner configures the real catalogue
  before opening production placements. A footprint is permanently fixed once
  used, including its floor/wall flag.
- Metadata freeze fixes the prefix, while layouts and levels may still change.
  The owner retains the requested sale/unused-footprint/royalty powers but has
  no withdrawal, seizure, free-mint or arbitrary club-transfer permission.
- Zero OG custody refers to protocol payments, not unsolicited token donations.
  Exact furniture custody assumes the configured real furniture contract.
  Singleton ERC1155 batches retain the vendored OZ behavior described in README.

## Verification

The existing compiler, optimizer, EVM target, dependencies, fuzz runs and
invariant settings are retained. No via-IR configuration or reduced test budget
was introduced. The new invariant suite uses the configured 128 runs at depth
64; the new placement fuzz test uses 256 runs. The legacy suites retain their
own existing inline settings.

Commands used for final verification:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x5c29c56089b215dc03f374d8592a6045dee713ee11c3c0babe257c2a9594b991 forge test
forge fmt --check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py' -v
```

The new club runtime is 15,524 bytes (EIP-170 limit 24,576). The seven-contract
factory test checks each init-code size, deployed runtime, reachable forbidden
opcodes, explicit owners and resolved dependencies. The external protected
harness needs launch-service inputs; this work uses local equivalents without
reading or inventing those service values. No Slither, Mythril, explorer
verification or live-chain audit is claimed.

## Local-check repair

The incoming work passed its reported behavior checks but failed manifest
validation: the array entry was not a string and notes exceeded 4,000 characters.
The earlier attempt had flattened only the manifest, causing eleven entries to
be checked against a nine-input constructor. This repair changes both the
constructor and manifest to eleven scalar inputs. It preserves the same encoded
price words, positive-price checks, immutable storage and all runtime behavior.
All Solidity construction sites and the script's printed argument labels now
use those scalar inputs. No new dependency or application is introduced.

The incoming manifest regression test accepted nested arrays, so it did not
model the launch schema. It now checks string-only values, exact compiler ABI
arity/types, the notes limit and the two previously rejected representations.
Notes retain the Sepolia-only mocks and mandatory raffle owner handoff.

The prior local test run exceeded its 600-second budget. The legacy club
invariants now compare reconstructed geometry against each handler's full grid
in one call after every action, instead of making hundreds of repeated per-cell
calls across unaffected clubs. Handlers check every tile of the affected club
after each mint, transfer and accepted or rejected placement. A global view
sweep still runs at each sequence's end. Geometry, footprint locks, custody and
payment checks still run after every action, with all original fuzz runs and
depths unchanged. This affects test performance only.

| Final repair check | Result |
| --- | --- |
| `forge build` | Passed with the existing compiler, optimizer, EVM target and dependencies. |
| `forge test` with the supplied seed | 223 tests passed across 32 suites; zero failures or skips. Completed in 351.05 seconds, within the reported 600-second local-check limit. |
| `forge fmt --check` | Passed. |
| Python header/manifest tests | All nine passed, including string-only constructor values, exact ABI arity and the notes-length boundary. |
| Constructor-only factory rehearsal | All seven applications deployed together; owner/dependency, runtime-size and forbidden-opcode checks passed. |
| Manifest shape | Eleven scalar club inputs matched eleven manifest strings; notes are 3,123 characters. |

The two optimized legacy club invariant campaigns completed in 41.08 and 83.11
seconds with their original runs/depths. The new level/wall/delegation campaign
also passed unchanged. Compiler lint notices are warnings, not build failures.
The launch service's independent attestation and deployment remain outside this
local verification; no live transaction was sent.
