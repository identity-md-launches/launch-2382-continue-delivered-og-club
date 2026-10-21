// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockDelegateRegistry} from "./helpers/ClubLaunchMocks.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @dev Drives pepes, delegations, mints, upgrades, club transfers/approvals and placements in random
///      order with several actors. Every call's success or failure is predicted from ghost state first.
contract ClubsReviewHandler is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant PRICE = 100_000e18 + 1;
    uint256 internal constant DESIGNS = 24;

    MockOG public token;
    OGClubFurniture public furniture;
    OGClubFarmVault public vault;
    MockSwarmPepe public pepes;
    MockDelegateRegistry public registry;
    OGClubClubs public clubs;

    address[4] public actors;
    uint256[] public pepeIds; // every pepe ever minted
    mapping(uint256 => bool) public pepeExists;
    mapping(uint256 => uint256) public mintsPerPepe;
    uint256 public clubCount;
    uint256 public ghostPaid;
    uint256 public ghostBurned;
    uint256 public ghostPlaced;
    uint256 public ghostRejected;
    mapping(uint256 => uint8) public ghostLevel;

    constructor() {
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), address(this));
        vault = new OGClubFarmVault(token, address(this));
        pepes = new MockSwarmPepe();
        registry = new MockDelegateRegistry();
        clubs = new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            address(this),
            address(this),
            pepes,
            registry,
            200_000e18 + 1,
            400_000e18 + 3,
            800_000e18 + 7
        );
        furniture.grantMinter(address(this));
        clubs.setSaleOpen(true);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("inv actor ", vm.toString(i)));
            token.mint(actors[i], 1e30);
            vm.prank(actors[i]);
            token.approve(address(clubs), type(uint256).max);
        }
        // Designs 1..24: a mix of floor shapes and wall widths.
        for (uint256 id = 1; id <= DESIGNS; ++id) {
            bool wall = id % 3 == 0;
            uint8 w = uint8(1 + id % 4);
            uint8 h = wall ? 1 : uint8(1 + (id / 4) % 3);
            clubs.setFootprint(id, w, h, wall);
        }
        // Half the pepe id space exists from the start, spread over the actors.
        for (uint256 k; k < 10; k += 2) {
            uint256 id = _pepe(k);
            pepes.mint(actors[k % actors.length], id);
            pepeExists[id] = true;
            pepeIds.push(id);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pepe(uint256 seed) internal pure returns (uint256) {
        // A small id space so collisions (re-mints, transfers) are common, plus id 0 and a huge id.
        uint256 k = seed % 10;
        if (k == 8) return 0;
        if (k == 9) return type(uint256).max;
        return 1 + k;
    }

    function _club(uint256 seed) internal view returns (bool ok, uint256 id) {
        uint256 n = clubs.totalSupply();
        if (n == 0) return (false, 0);
        return (true, clubs.tokenByIndex(seed % n));
    }

    function mintPepe(uint256 actorSeed, uint256 pepeSeed) external {
        uint256 id = _pepe(pepeSeed);
        if (pepeExists[id]) return;
        pepes.mint(_actor(actorSeed), id);
        pepeExists[id] = true;
        pepeIds.push(id);
    }

    function transferPepe(uint256 pepeSeed, uint256 toSeed) external {
        uint256 id = _pepe(pepeSeed);
        if (!pepeExists[id]) return;
        address from = pepes.ownerOf(id);
        vm.prank(from);
        pepes.transferFrom(from, _actor(toSeed), id);
    }

    function delegate(uint256 pepeSeed, uint256 toSeed, bool enable) external {
        uint256 id = _pepe(pepeSeed);
        if (!pepeExists[id]) return;
        address holder = pepes.ownerOf(id);
        vm.prank(holder);
        registry.delegateERC721(_actor(toSeed), address(pepes), id, bytes32(0), enable);
    }

    function setSale(uint256 seed) external {
        // Closing is rare so that most sequences keep minting.
        clubs.setSaleOpen(seed % 5 != 0);
    }

    function mintClub(uint256 actorSeed, uint256 pepeSeed) external {
        uint256 id = _pepe(pepeSeed);
        address caller = _actor(actorSeed);
        // Usually the holder, sometimes anyone (delegated or not).
        if (actorSeed % 4 != 0 && pepeExists[id]) caller = pepes.ownerOf(id);
        bool expectOk = clubs.saleOpen() && pepeExists[id] && mintsPerPepe[id] == 0;
        if (expectOk) {
            address holder = pepes.ownerOf(id);
            expectOk =
                caller == holder || registry.checkDelegateForERC721(caller, holder, address(pepes), id, bytes32(0));
        }
        uint256 before = token.balanceOf(caller);
        vm.prank(caller);
        try clubs.mintClub(id) returns (uint256 got) {
            assertTrue(expectOk, "mint succeeded where it must fail");
            assertEq(got, id);
            assertEq(clubs.ownerOf(id), caller);
            assertEq(before - token.balanceOf(caller), PRICE);
            mintsPerPepe[id]++;
            clubCount++;
            ghostPaid += PRICE;
            ghostBurned += PRICE / 2;
            ghostLevel[id] = 1;
        } catch {
            assertFalse(expectOk, "mint failed where it must succeed");
            assertEq(token.balanceOf(caller), before);
        }
    }

    function upgrade(uint256 actorSeed, uint256 clubSeed) external {
        (bool exists, uint256 id) = _club(clubSeed);
        if (!exists) return;
        address caller = actorSeed % 3 != 0 ? clubs.ownerOf(id) : _actor(actorSeed / 3);
        address holder = clubs.ownerOf(id);
        uint8 level = clubs.levelOf(id);
        assertEq(level, ghostLevel[id], "level drifted");
        bool authorized = caller == holder || clubs.getApproved(id) == caller || clubs.isApprovedForAll(holder, caller);
        bool expectOk = authorized && level < 4;
        uint256 p = clubs.upgradePrice(level);
        vm.prank(caller);
        try clubs.upgradeClub(id) {
            assertTrue(expectOk, "upgrade succeeded where it must fail");
            ghostPaid += p;
            ghostBurned += p / 2;
            ghostLevel[id] = level + 1;
        } catch {
            assertFalse(expectOk, "upgrade failed where it must succeed");
        }
    }

    function transferClub(uint256 clubSeed, uint256 toSeed) external {
        (bool exists, uint256 id) = _club(clubSeed);
        if (!exists) return;
        address holder = clubs.ownerOf(id);
        vm.prank(holder);
        clubs.transferFrom(holder, _actor(toSeed), id);
    }

    function approveClub(uint256 clubSeed, uint256 toSeed, bool forAll) external {
        (bool exists, uint256 id) = _club(clubSeed);
        if (!exists) return;
        address holder = clubs.ownerOf(id);
        vm.prank(holder);
        if (forAll) clubs.setApprovalForAll(_actor(toSeed), toSeed % 2 == 0);
        else clubs.approve(_actor(toSeed), id);
    }

    function place(uint256 actorSeed, uint256 clubSeed, uint256 designSeed, uint8 x, uint8 y, uint8 rot) external {
        (bool exists, uint256 clubId) = _club(clubSeed);
        if (!exists) return;
        address from = actorSeed % 4 != 0 ? clubs.ownerOf(clubId) : _actor(actorSeed / 4);
        uint256 design = 1 + designSeed % DESIGNS;
        bytes memory data = _placementData(clubId, design, x, y, rot);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = design;
        amounts[0] = 1;
        furniture.mintBatch(from, ids, amounts);
        _tryPlace(from, clubId, design, data);
    }

    function _placementData(uint256 clubId, uint256 design, uint8 x, uint8 y, uint8 rot)
        internal
        view
        returns (bytes memory)
    {
        (,,,, bool wall) = clubs.footprintOf(design);
        // Bias coordinates into the room so successes are common, but keep out-of-range values reachable.
        x = x % 9 == 0 ? uint8(x % 18) : uint8(x % 10);
        y = wall ? (y % 7 == 0 ? 1 : 0) : y % 9 == 0 ? uint8(y % 18) : uint8(y % 10);
        rot = wall ? uint8(rot % 3) : uint8(rot % 5);
        return abi.encode(clubId, x, y, rot);
    }

    function _authorized(address who, uint256 clubId) internal view returns (bool) {
        address holder = clubs.ownerOf(clubId);
        return who == holder || clubs.getApproved(clubId) == who || clubs.isApprovedForAll(holder, who);
    }

    function _tryPlace(address from, uint256 clubId, uint256 design, bytes memory data) internal {
        uint256 count = clubs.pieceCount(clubId);
        bool had = clubs.hasDesign(clubId, design);
        bool authorized = _authorized(from, clubId);
        vm.prank(from);
        try furniture.safeTransferFrom(from, address(clubs), design, 1, data) {
            assertTrue(authorized, "unauthorized placement");
            assertFalse(had, "second copy of a design placed");
            assertEq(clubs.pieceCount(clubId), count + 1);
            ghostPlaced++;
        } catch {
            assertEq(clubs.pieceCount(clubId), count, "rejected placement changed layout");
            assertEq(clubs.hasDesign(clubId, design), had);
            ghostRejected++;
        }
    }

    function pepeIdsLength() external view returns (uint256) {
        return pepeIds.length;
    }
}

contract ClubsReviewInvariantTest is Test {
    ClubsReviewHandler internal handler;
    OGClubClubs internal clubs;

    function setUp() public {
        handler = new ClubsReviewHandler();
        clubs = handler.clubs();
        // Two clubs exist from the start (pepes 1 and 3, minted by their holders through the handler).
        handler.mintClub(1, 0);
        handler.mintClub(1, 2);
        assertEq(handler.clubCount(), 2);
        targetContract(address(handler));
    }

    /// The handler's own paths work: placements, upgrades and duplicate refusals happen on a fixed sequence.
    function test_HandlerExercisesEveryPath() public {
        uint256 placedBefore = handler.ghostPlaced();
        for (uint256 i; i < 40; ++i) {
            handler.place(1, i, i, uint8(i * 7), uint8(i * 3), uint8(i));
        }
        assertGt(handler.ghostPlaced(), placedBefore);
        assertGt(handler.ghostRejected(), 0);
        uint256 paid = handler.ghostPaid();
        handler.upgrade(1, 0);
        assertGt(handler.ghostPaid(), paid);
        invariant_EveryClubIsAPepeThatMintedOnce();
        invariant_NoOGHeldAndPaymentsSplitExactly();
        invariant_PiecesEqualFurnitureHeldAndLayoutsValid();
    }

    function _inFloor(uint8 level, uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= 16 || y >= 16) return false;
        if (level == 1) return x < 10 && y < 10;
        if (level == 2) return x < 14 && y < 10;
        if (level == 3) return (x < 14 && y < 10) || (x < 10 && y < 16);
        return true;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_EveryClubIsAPepeThatMintedOnce() public view {
        uint256 n = clubs.totalSupply();
        assertEq(n, handler.clubCount());
        for (uint256 i; i < n; ++i) {
            uint256 id = clubs.tokenByIndex(i);
            assertTrue(handler.pepeExists(id), "club id is not a pepe");
            assertTrue(clubs.clubsMinted(id));
            assertEq(handler.mintsPerPepe(id), 1);
        }
        for (uint256 i; i < handler.pepeIdsLength(); ++i) {
            uint256 p = handler.pepeIds(i);
            assertEq(clubs.clubsMinted(p), handler.mintsPerPepe(p) == 1);
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_NoOGHeldAndPaymentsSplitExactly() public view {
        MockOG token = handler.token();
        assertEq(token.balanceOf(address(clubs)), 0);
        uint256 burned = token.balanceOf(clubs.BURN_ADDRESS());
        uint256 toVault = token.balanceOf(address(handler.vault()));
        assertEq(burned, handler.ghostBurned());
        assertEq(burned + toVault, handler.ghostPaid());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_PiecesEqualFurnitureHeldAndLayoutsValid() public view {
        OGClubFurniture furniture = handler.furniture();
        uint256 n = clubs.totalSupply();
        uint256[25] memory perDesign;
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 clubId = clubs.tokenByIndex(i);
            uint8 level = clubs.levelOf(clubId);
            assertEq(level, handler.ghostLevel(clubId));
            OGClubClubs.Piece[] memory ps = clubs.piecesOf(clubId);
            uint256 tiles;
            uint32[2] memory walls;
            for (uint256 k; k < ps.length; ++k) {
                OGClubClubs.Piece memory pc = ps[k];
                perDesign[pc.furnitureId]++;
                assertTrue(clubs.hasDesign(clubId, pc.furnitureId));
                for (uint256 j; j < k; ++j) {
                    assertTrue(ps[j].furnitureId != pc.furnitureId, "one of each broken");
                }
                (uint8 w, uint8 h,, bool locked, bool wall) = clubs.footprintOf(pc.furnitureId);
                assertTrue(locked);
                assertEq(pc.wall, wall);
                if (wall) {
                    uint256 len = pc.rot == 0 ? (level == 1 ? 10 : level == 4 ? 16 : 14) : (level <= 2 ? 10 : 16);
                    assertEq(pc.y, 0);
                    assertLe(pc.rot, 1);
                    assertLe(uint256(pc.x) + w, len, "wall piece past the end");
                    for (uint256 p = pc.x; p < uint256(pc.x) + w; ++p) {
                        uint32 bit = uint32(1 << p);
                        assertEq(walls[pc.rot] & bit, 0, "wall overlap");
                        walls[pc.rot] |= bit;
                        assertTrue(!(pc.rot == 1 && p == 4), "wall covers door");
                    }
                } else {
                    (uint256 ww, uint256 hh) = pc.rot % 2 == 1 ? (uint256(h), uint256(w)) : (uint256(w), uint256(h));
                    for (uint256 yy = pc.y; yy < uint256(pc.y) + hh; ++yy) {
                        for (uint256 xx = pc.x; xx < uint256(pc.x) + ww; ++xx) {
                            assertTrue(_inFloor(level, xx, yy), "outside the level");
                            assertTrue(!(yy == 4 && xx < 2), "covers door");
                            uint256 bit = uint256(1) << (yy * 16 + xx);
                            assertEq(tiles & bit, 0, "floor overlap");
                            tiles |= bit;
                        }
                    }
                }
            }
            total += ps.length;
        }
        for (uint256 id = 1; id <= 24; ++id) {
            assertEq(furniture.balanceOf(address(clubs), id), perDesign[id], "custody differs from pieces");
        }
        assertEq(total, handler.ghostPlaced());
    }
}
