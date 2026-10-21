// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {MockOG} from "../src/mocks/MockOG.sol";

/// @dev Drives clubs with several actors, club approvals, furniture operators, transfers and owner footprint
///      changes. Every placement attempt is checked against an independent per-club tile model: the model
///      decides whether it must succeed; a rejection must leave every observable unchanged.
contract AdversarialClubsHandler is Test {
    uint256 internal constant ITEMS = 6; // ids 1..6; id 6 starts with no footprint
    uint256 internal constant MAX_CLUBS = 6;

    OGClubClubs public immutable clubs;
    OGClubFurniture public immutable furniture;
    MockOG public immutable token;
    address public immutable admin;
    address[4] internal actors;

    // Ghosts.
    mapping(uint256 clubId => bool[100]) internal grid;
    mapping(uint256 clubId => uint256) public ghostPieces;
    mapping(uint256 clubId => mapping(uint256 item => bool)) public ghostDesign;
    mapping(uint256 item => uint256) public ghostHeld;
    mapping(uint256 item => uint8) public ghostW;
    mapping(uint256 item => uint8) public ghostH;
    mapping(uint256 item => bool) public ghostSet;
    mapping(uint256 item => bool) public ghostLocked;
    uint256 public ghostMints;
    uint256 public ghostBurned;
    uint256 public ghostToVault;
    uint256 public successfulPlacements;
    uint256 public rejectedPlacements;

    constructor(OGClubClubs clubs_, OGClubFurniture furniture_, MockOG token_, address admin_) {
        clubs = clubs_;
        furniture = furniture_;
        token = token_;
        admin = admin_;
        actors = [makeAddr("inv a"), makeAddr("inv b"), makeAddr("inv c"), makeAddr("inv d")];
        for (uint256 item = 1; item < ITEMS; ++item) {
            (uint8 w, uint8 h, bool set,,) = clubs_.footprintOf(item);
            ghostW[item] = w;
            ghostH[item] = h;
            ghostSet[item] = set;
        }
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function clubCount() public view returns (uint256) {
        return clubs.totalSupply();
    }

    function gridAt(uint256 clubId, uint256 tile) external view returns (bool) {
        return grid[clubId][tile];
    }

    function expectedGrid(uint256 clubId) external view returns (bool[100] memory) {
        return grid[clubId];
    }

    function _assertGrid(uint256 clubId) private view {
        for (uint8 y; y < 10; ++y) {
            for (uint8 x; x < 10; ++x) {
                assertEq(clubs.tileTaken(clubId, x, y), grid[clubId][uint256(y) * 10 + x]);
            }
        }
    }

    // ------------------------------------------------------------------ actions

    function mint(uint8 payerSeed, uint8 toSeed, bool useTo) external {
        if (clubCount() >= MAX_CLUBS) return;
        address payer = actors[payerSeed % 4];
        address to = payer;
        toSeed; // Mint-to was removed: caller is now the Pepe holder and recipient.
        useTo;
        uint256 price = clubs.price();
        token.mint(payer, price);
        vm.prank(payer);
        token.approve(address(clubs), price);
        uint256 burnBefore = token.balanceOf(clubs.BURN_ADDRESS());
        uint256 vaultBefore = token.balanceOf(clubs.vault());
        uint256 expectedId = ghostMints + 1;
        MockSwarmPepe(address(clubs.pepes())).mint(payer, expectedId);
        vm.prank(payer);
        uint256 id = clubs.mintClub(expectedId);
        ++ghostMints;
        assertEq(id, ghostMints, "club ID must equal the minted Pepe ID");
        assertEq(clubs.ownerOf(id), to);
        ghostBurned += token.balanceOf(clubs.BURN_ADDRESS()) - burnBefore;
        ghostToVault += token.balanceOf(clubs.vault()) - vaultBefore;
        _assertGrid(id);
    }

    function transferClub(uint8 clubSeed, uint8 toSeed) external {
        uint256 n = clubCount();
        if (n == 0) return;
        uint256 clubId = clubs.tokenByIndex(clubSeed % n);
        address holder = clubs.ownerOf(clubId);
        address to = actors[toSeed % 4];
        bytes memory before = abi.encode(clubs.piecesOf(clubId));
        vm.prank(holder);
        clubs.transferFrom(holder, to, clubId);
        assertEq(abi.encode(clubs.piecesOf(clubId)), before, "layout must travel unchanged");
        _assertGrid(clubId);
    }

    function approveClub(uint8 clubSeed, uint8 spenderSeed, bool forAll, bool on) external {
        uint256 n = clubCount();
        if (n == 0) return;
        uint256 clubId = clubs.tokenByIndex(clubSeed % n);
        address holder = clubs.ownerOf(clubId);
        address spender = actors[spenderSeed % 4];
        if (spender == holder) return;
        vm.prank(holder);
        if (forAll) clubs.setApprovalForAll(spender, on);
        else clubs.approve(on ? spender : address(0), clubId);
    }

    function setFootprint(uint8 itemSeed, uint8 wSeed, uint8 hSeed) external {
        uint256 item = 1 + itemSeed % ITEMS;
        uint8 w = uint8(wSeed % 6); // includes invalid 0 and 5
        uint8 h = uint8(hSeed % 6);
        vm.prank(admin);
        try clubs.setFootprint(item, w, h, false) {
            assertFalse(ghostLocked[item], "locked footprint changed");
            assertTrue(w >= 1 && w <= 4 && h >= 1 && h <= 4, "bad footprint accepted");
            ghostW[item] = w;
            ghostH[item] = h;
            ghostSet[item] = true;
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(
                (ghostLocked[item] && sel == OGClubClubs.FootprintLocked.selector)
                    || sel == OGClubClubs.BadFootprint.selector,
                "unexpected setFootprint failure"
            );
            assertTrue(ghostLocked[item] || w == 0 || h == 0 || w > 4 || h > 4, "valid footprint refused");
        }
    }

    struct Attempt {
        uint256 clubId;
        address from;
        address caller;
        uint256 item;
        uint8 x;
        uint8 y;
        uint8 rot;
        bool exists;
        uint256 heldBefore;
        uint256 fromBefore;
        uint256 countBefore;
        bytes4 expected;
    }

    /// @param clubSeed values past the supply target a missing club.
    /// @param mode 0: `from` transfers its own; 1: an ERC-1155 operator transfers on `from`'s behalf.
    function place(
        uint8 clubSeed,
        uint8 fromSeed,
        uint8 callerSeed,
        uint8 itemSeed,
        uint8 x,
        uint8 y,
        uint8 rot,
        uint8 mode
    ) external {
        Attempt memory a;
        uint256 n = clubCount();
        a.clubId = clubSeed % (n + 2); // 0 and n+1 do not exist
        a.exists = a.clubId != 0 && a.clubId <= n;
        a.from = actors[fromSeed % 4];
        // Bias towards the club holder so that a meaningful fraction succeeds.
        if (a.exists && fromSeed % 3 != 0) a.from = clubs.ownerOf(a.clubId);
        a.caller = mode % 2 == 0 ? a.from : actors[callerSeed % 4];
        a.item = 1 + itemSeed % ITEMS;
        a.x = uint8(bound(x, 0, 11));
        a.y = uint8(bound(y, 0, 11));
        a.rot = uint8(bound(rot, 0, 4));
        if (a.caller != a.from && !furniture.isApprovedForAll(a.from, a.caller)) {
            vm.prank(a.from);
            furniture.setApprovalForAll(a.caller, true);
        }
        _mintItem(a.from, a.item);
        a.expected = _expectedError(a.clubId, a.from, a.item, a.x, a.y, a.rot);
        a.heldBefore = furniture.balanceOf(address(clubs), a.item);
        a.fromBefore = furniture.balanceOf(a.from, a.item);
        a.countBefore = a.exists ? clubs.pieceCount(a.clubId) : 0;
        _attempt(a);
    }

    function _mintItem(address to, uint256 item) private {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = item;
        amounts[0] = 1;
        furniture.mintBatch(to, ids, amounts);
    }

    function _attempt(Attempt memory a) private {
        bytes memory data = abi.encode(a.clubId, a.x, a.y, a.rot);
        vm.prank(a.caller);
        try furniture.safeTransferFrom(a.from, address(clubs), a.item, 1, data) {
            assertEq(a.expected, bytes4(0), "model rejects a placement the contract accepted");
            _recordPlacement(a.clubId, a.item, a.x, a.y, a.rot, a.countBefore);
        } catch (bytes memory err) {
            assertTrue(a.expected != bytes4(0), "model accepts a placement the contract rejected");
            // Any violated rule is an acceptable reason.
            assertTrue(
                _violated(bytes4(err), a.clubId, a.from, a.item, a.x, a.y, a.rot), "rejected for a rule that holds"
            );
            assertEq(furniture.balanceOf(address(clubs), a.item), a.heldBefore);
            assertEq(furniture.balanceOf(a.from, a.item), a.fromBefore);
            if (a.exists) assertEq(clubs.pieceCount(a.clubId), a.countBefore);
            (,,, bool locked,) = clubs.footprintOf(a.item);
            assertEq(locked, ghostLocked[a.item]);
            ++rejectedPlacements;
        }
        // Check the entire affected board even when placement was rejected.
        if (a.exists) _assertGrid(a.clubId);
    }

    // ------------------------------------------------------------------ model

    function _recordPlacement(uint256 clubId, uint256 item, uint8 x, uint8 y, uint8 rot, uint256 index) private {
        (uint256 w, uint256 h) = _dims(item, rot);
        for (uint256 yy = y; yy < y + h; ++yy) {
            for (uint256 xx = x; xx < x + w; ++xx) {
                grid[clubId][yy * 10 + xx] = true;
            }
        }
        ghostDesign[clubId][item] = true;
        ++ghostPieces[clubId];
        ++ghostHeld[item];
        ghostLocked[item] = true;
        ++successfulPlacements;
        OGClubClubs.Piece[] memory pieces = clubs.piecesOf(clubId);
        assertEq(pieces.length, index + 1);
        assertEq(pieces[index].furnitureId, item);
        assertEq(pieces[index].x, x);
        assertEq(pieces[index].y, y);
        assertEq(pieces[index].rot, rot);
    }

    function _dims(uint256 item, uint8 rot) private view returns (uint256 w, uint256 h) {
        (w, h) = (ghostW[item], ghostH[item]);
        if (rot == 1 || rot == 3) (w, h) = (h, w);
    }

    function _authorized(uint256 clubId, address from) private view returns (bool) {
        address holder = clubs.ownerOf(clubId);
        return from == holder || clubs.isApprovedForAll(holder, from) || clubs.getApproved(clubId) == from;
    }

    function _fits(uint256 item, uint8 x, uint8 y, uint8 rot) private view returns (bool) {
        if (rot > 3) return false;
        (uint256 w, uint256 h) = _dims(item, rot);
        return uint256(x) + w <= 10 && uint256(y) + h <= 10;
    }

    function _coversDoor(uint256 item, uint8 x, uint8 y, uint8 rot) private view returns (bool) {
        (, uint256 h) = _dims(item, rot);
        // Door tiles (0,4) and (1,4): any piece starting in column 0 or 1 covers one of them on row 4.
        return y <= 4 && 4 < uint256(y) + h && x <= 1;
    }

    function _overlaps(uint256 clubId, uint256 item, uint8 x, uint8 y, uint8 rot) private view returns (bool) {
        (uint256 w, uint256 h) = _dims(item, rot);
        for (uint256 yy = y; yy < y + h; ++yy) {
            for (uint256 xx = x; xx < x + w; ++xx) {
                if (grid[clubId][yy * 10 + xx]) return true;
            }
        }
        return false;
    }

    function _expectedError(uint256 clubId, address from, uint256 item, uint8 x, uint8 y, uint8 rot)
        private
        view
        returns (bytes4)
    {
        if (clubId == 0 || clubId > clubCount()) return OGClubClubs.NonexistentToken.selector;
        if (!_authorized(clubId, from)) return OGClubClubs.NotClubOwner.selector;
        if (!ghostSet[item]) return OGClubClubs.NoFootprint.selector;
        if (ghostPieces[clubId] >= 285) return OGClubClubs.ClubFull.selector;
        if (ghostDesign[clubId][item]) return OGClubClubs.AlreadyHasDesign.selector;
        if (!_fits(item, x, y, rot)) return OGClubClubs.OutOfRoom.selector;
        if (_coversDoor(item, x, y, rot)) return OGClubClubs.BlocksDoor.selector;
        if (_overlaps(clubId, item, x, y, rot)) return OGClubClubs.TileTaken.selector;
        return bytes4(0);
    }

    function _violated(bytes4 sel, uint256 clubId, address from, uint256 item, uint8 x, uint8 y, uint8 rot)
        private
        view
        returns (bool)
    {
        bool exists = clubId != 0 && clubId <= clubCount();
        if (sel == OGClubClubs.NonexistentToken.selector) return !exists;
        if (!exists) return false;
        if (sel == OGClubClubs.NotClubOwner.selector) return !_authorized(clubId, from);
        if (sel == OGClubClubs.NoFootprint.selector) return !ghostSet[item];
        if (!ghostSet[item]) return false;
        if (sel == OGClubClubs.ClubFull.selector) return ghostPieces[clubId] >= 285;
        if (sel == OGClubClubs.AlreadyHasDesign.selector) return ghostDesign[clubId][item];
        if (sel == OGClubClubs.OutOfRoom.selector) return !_fits(item, x, y, rot);
        if (!_fits(item, x, y, rot)) return false;
        if (sel == OGClubClubs.BlocksDoor.selector) return _coversDoor(item, x, y, rot);
        if (sel == OGClubClubs.TileTaken.selector) return _overlaps(clubId, item, x, y, rot);
        return false;
    }
}

contract ClubsAdversarialInvariantTest is Test {
    uint256 internal constant PRICE = 100_000e18 + 7;

    MockSwarmPepe internal pepes;
    IDelegateRegistry internal delegates;

    function _upgradePrices() internal pure returns (uint256[3] memory) {
        return [uint256(200_000e18 + 1), 400_000e18 + 3, 800_000e18 + 7];
    }
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubFarmVault internal vault;
    OGClubClubs internal clubs;
    AdversarialClubsHandler internal handler;
    address internal admin = makeAddr("inv admin");
    uint256 internal burnStart;
    uint256 internal vaultStart;

    function setUp() public {
        pepes = new MockSwarmPepe();
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), makeAddr("inv royalty"));
        vault = new OGClubFarmVault(token, address(this));
        clubs = new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            admin,
            makeAddr("inv royalty"),
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        vm.startPrank(admin);
        clubs.setSaleOpen(true);
        clubs.setFootprint(1, 1, 1, false);
        clubs.setFootprint(2, 2, 1, false);
        clubs.setFootprint(3, 2, 2, false);
        clubs.setFootprint(4, 4, 4, false);
        clubs.setFootprint(5, 1, 3, false);
        vm.stopPrank();
        handler = new AdversarialClubsHandler(clubs, furniture, token, admin);
        furniture.grantMinter(address(handler));
        burnStart = token.balanceOf(clubs.BURN_ADDRESS());
        vaultStart = token.balanceOf(address(vault));

        // Seed so invariants are never vacuous: two clubs and some placements exist from the start.
        handler.mint(0, 0, false);
        handler.mint(1, 2, true);
        handler.place(1, 0, 0, 0, 2, 2, 0, 0);
        handler.place(2, 1, 1, 3, 5, 5, 1, 0);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = AdversarialClubsHandler.mint.selector;
        selectors[1] = AdversarialClubsHandler.transferClub.selector;
        selectors[2] = AdversarialClubsHandler.approveClub.selector;
        selectors[3] = AdversarialClubsHandler.setFootprint.selector;
        selectors[4] = AdversarialClubsHandler.place.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_NoTokensEverHeldAndSplitConserved() public view {
        assertEq(token.balanceOf(address(clubs)), 0, "contract holds $OG");
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()) - burnStart, handler.ghostBurned());
        assertEq(token.balanceOf(address(vault)) - vaultStart, handler.ghostToVault());
        assertEq(handler.ghostBurned() + handler.ghostToVault(), PRICE * handler.ghostMints());
        assertEq(handler.ghostBurned(), (PRICE / 2) * handler.ghostMints());
        assertEq(clubs.totalSupply(), handler.ghostMints());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_PiecesEqualCustodyPerItem() public view {
        uint256 n = clubs.totalSupply();
        uint256[7] memory counted;
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 clubId = clubs.tokenByIndex(i);
            OGClubClubs.Piece[] memory pieces = clubs.piecesOf(clubId);
            assertEq(pieces.length, handler.ghostPieces(clubId));
            assertEq(clubs.pieceCount(clubId), pieces.length);
            for (uint256 p; p < pieces.length; ++p) {
                counted[pieces[p].furnitureId]++;
            }
            total += pieces.length;
        }
        uint256 held;
        for (uint256 item = 1; item <= 6; ++item) {
            assertEq(furniture.balanceOf(address(clubs), item), counted[item], "custody != recorded pieces");
            assertEq(counted[item], handler.ghostHeld(item));
            held += furniture.balanceOf(address(clubs), item);
        }
        assertEq(held, total);
        assertEq(handler.ghostHeld(0), 0);
    }

    /// @dev Rebuild each club's occupancy from its stored pieces alone and compare with the view and the model.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_LayoutsFitNeverOverlapNeverCoverDoor() public view {
        uint256 n = clubs.totalSupply();
        for (uint256 i; i < n; ++i) {
            uint256 clubId = clubs.tokenByIndex(i);
            OGClubClubs.Piece[] memory pieces = clubs.piecesOf(clubId);
            bool[100] memory occ;
            for (uint256 p; p < pieces.length; ++p) {
                (uint8 w, uint8 h, bool set, bool locked,) = clubs.footprintOf(pieces[p].furnitureId);
                assertTrue(set && locked, "placed id without locked footprint");
                assertLe(pieces[p].rot, 3);
                if (pieces[p].rot % 2 == 1) (w, h) = (h, w);
                assertLe(uint256(pieces[p].x) + w, 10, "piece off grid (x)");
                assertLe(uint256(pieces[p].y) + h, 10, "piece off grid (y)");
                for (uint256 yy = pieces[p].y; yy < uint256(pieces[p].y) + h; ++yy) {
                    for (uint256 xx = pieces[p].x; xx < uint256(pieces[p].x) + w; ++xx) {
                        uint256 t = yy * 10 + xx;
                        assertFalse(occ[t], "pieces overlap");
                        assertTrue(t != 40 && t != 41, "piece covers the door");
                        occ[t] = true;
                    }
                }
            }
            assertEq(abi.encode(occ), abi.encode(handler.expectedGrid(clubId)), "model disagrees");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_LockedFootprintsNeverChange() public view {
        for (uint256 item = 1; item <= 6; ++item) {
            (uint8 w, uint8 h, bool set, bool locked,) = clubs.footprintOf(item);
            assertEq(locked, handler.ghostLocked(item));
            assertEq(set, handler.ghostSet(item));
            assertEq(w, handler.ghostW(item));
            assertEq(h, handler.ghostH(item));
        }
    }

    function afterInvariant() external view {
        // Guard against a campaign that silently exercises nothing.
        assertGt(handler.successfulPlacements(), 0, "no placement succeeded");
        // Global view consistency after each sequence, in addition to each affected board in the handler.
        for (uint256 i; i < clubs.totalSupply(); ++i) {
            uint256 clubId = clubs.tokenByIndex(i);
            bool[100] memory expected = handler.expectedGrid(clubId);
            for (uint8 y; y < 10; ++y) {
                for (uint8 x; x < 10; ++x) {
                    assertEq(clubs.tileTaken(clubId, x, y), expected[uint256(y) * 10 + x]);
                }
            }
        }
    }
}
