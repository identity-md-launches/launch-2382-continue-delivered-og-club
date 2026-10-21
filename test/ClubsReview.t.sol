// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {MockDelegateRegistry} from "./helpers/ClubLaunchMocks.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";

/// @dev Independent review of the Swarm Pepe / levels / walls / one-of-each changes. Expected geometry is
///      computed from the brief's coordinate rules, never from the contract's mask constants.
abstract contract ClubsReviewBase is ClubsTestBase {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    MockDelegateRegistry internal registry;
    OGClubClubs internal dclubs; // same stack, delegation switched on
    uint256 internal nextId = 1000;

    function setUp() public virtual override {
        super.setUp();
        registry = new MockDelegateRegistry();
        dclubs = new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            registry,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        dclubs.setSaleOpen(true);
        fund(alice, 1e40);
    }

    // ---------- independent model of the brief ----------

    function inFloor(uint8 level, uint256 x, uint256 y) internal pure returns (bool) {
        if (x >= 16 || y >= 16) return false;
        if (level == 1) return x < 10 && y < 10;
        if (level == 2) return x < 14 && y < 10;
        if (level == 3) return (x < 14 && y < 10) || (x < 10 && y < 16);
        return true;
    }

    function isDoor(uint256 x, uint256 y) internal pure returns (bool) {
        return y == 4 && (x == 0 || x == 1);
    }

    function wallLen(uint8 level, uint8 side) internal pure returns (uint256) {
        uint8[4] memory s0 = [10, 14, 14, 16];
        uint8[4] memory s1 = [10, 10, 16, 16];
        return side == 0 ? s0[level - 1] : s1[level - 1];
    }

    // ---------- helpers ----------

    function newDesign(address to, uint8 w, uint8 h, bool wall) internal returns (uint256 id) {
        id = nextId++;
        clubs.setFootprint(id, w, h, wall);
        stock(to, id, 2);
    }

    function tryPlace(address from, uint256 clubId, uint256 id, uint8 x, uint8 y, uint8 rot)
        internal
        returns (bytes4 err)
    {
        vm.prank(from);
        try furniture.safeTransferFrom(from, address(clubs), id, 1, abi.encode(clubId, x, y, rot)) {
            return bytes4(0);
        } catch (bytes memory reason) {
            return bytes4(reason);
        }
    }

    function upgradeTo(address who, uint256 clubId, uint8 level) internal {
        while (clubs.levelOf(clubId) < level) {
            vm.prank(who);
            clubs.upgradeClub(clubId);
        }
    }

    function mintFresh(address who, uint256 pepeId) internal returns (uint256) {
        pepes.mint(who, pepeId);
        vm.prank(who);
        return clubs.mintClub(pepeId);
    }
}

contract ClubsReviewPepeTest is ClubsReviewBase {
    function test_HolderMintsClubWithPepeIdAndEventCarriesIt() public {
        uint256 bal = token.balanceOf(alice);
        vm.expectEmit(address(clubs));
        emit OGClubClubs.ClubMinted(3, alice, alice, PRICE / 2, PRICE - PRICE / 2, 3);
        vm.prank(alice);
        assertEq(clubs.mintClub(3), 3);
        assertEq(clubs.ownerOf(3), alice);
        assertTrue(clubs.clubsMinted(3));
        assertFalse(clubs.clubsMinted(2));
        assertEq(clubs.levelOf(3), 1);
        assertEq(bal - token.balanceOf(alice), PRICE);
        assertEq(clubs.totalSupply(), 2);
    }

    function test_NonHolderAndApprovedPepeOperatorCannotMint() public {
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        clubs.mintClub(2); // bob's pepe
        // An ERC-721 approval on the pepe is not a delegation.
        vm.prank(bob);
        pepes.setApprovalForAll(alice, true);
        vm.prank(bob);
        pepes.approve(alice, 2);
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        clubs.mintClub(2);
        assertFalse(clubs.clubsMinted(2));
    }

    function test_NonexistentPepeReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 77));
        clubs.mintClub(77);
        assertFalse(clubs.clubsMinted(77));
    }

    function test_DelegatedHotWalletMintsPaysAndReceives() public {
        address hot = makeAddr("hot");
        fund(hot, PRICE);
        vm.prank(hot);
        token.approve(address(dclubs), PRICE);
        vm.prank(bob);
        registry.delegateERC721(hot, address(pepes), 2, bytes32(0), true);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(hot);
        assertEq(dclubs.mintClub(2), 2);
        assertEq(dclubs.ownerOf(2), hot);
        assertEq(token.balanceOf(hot), 0);
        assertEq(token.balanceOf(bob), bobBefore);
        assertEq(pepes.ownerOf(2), bob);
    }

    function test_DelegationMustMatchHolderTokenCollectionAndRights() public {
        address hot = makeAddr("hot");
        fund(hot, 10 * PRICE);
        vm.prank(hot);
        token.approve(address(dclubs), type(uint256).max);
        // Wrong token id.
        vm.prank(bob);
        registry.delegateERC721(hot, address(pepes), 99, bytes32(0), true);
        // Wrong collection.
        MockSwarmPepe other = new MockSwarmPepe();
        vm.prank(bob);
        registry.delegateERC721(hot, address(other), 2, bytes32(0), true);
        // Non-zero rights: the contract asks for rights 0 only.
        vm.prank(bob);
        registry.delegateERC721(hot, address(pepes), 2, bytes32("subrights"), true);
        // Delegated by someone who is not the holder.
        vm.prank(alice);
        registry.delegateERC721(hot, address(pepes), 2, bytes32(0), true);
        vm.prank(hot);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        dclubs.mintClub(2);
        // An undelegated wallet still cannot mint after bob delegates to hot.
        vm.prank(bob);
        registry.delegateERC721(hot, address(pepes), 2, bytes32(0), true);
        address cold = makeAddr("undelegated");
        fund(cold, PRICE);
        vm.prank(cold);
        token.approve(address(dclubs), PRICE);
        vm.prank(cold);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        dclubs.mintClub(2);
        vm.prank(hot);
        dclubs.mintClub(2);
        assertEq(dclubs.ownerOf(2), hot);
    }

    function test_DelegationFromPreviousHolderDiesWithPepeTransfer() public {
        address hot = makeAddr("hot");
        fund(hot, PRICE);
        vm.prank(hot);
        token.approve(address(dclubs), PRICE);
        vm.prank(bob);
        registry.delegateERC721(hot, address(pepes), 2, bytes32(0), true);
        vm.prank(bob);
        pepes.transferFrom(bob, alice, 2);
        vm.prank(hot);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        dclubs.mintClub(2);
    }

    function test_ZeroRegistryIgnoresDelegation() public {
        // `clubs` was built with delegates == address(0). A registry entry elsewhere is irrelevant.
        assertEq(address(clubs.delegates()), address(0));
        address hot = makeAddr("hot");
        fund(hot, PRICE);
        vm.prank(bob);
        registry.delegateERC721(hot, address(pepes), 2, bytes32(0), true);
        vm.prank(hot);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        clubs.mintClub(2);
        vm.prank(bob);
        clubs.mintClub(2);
        assertEq(clubs.ownerOf(2), bob);
    }

    function test_SecondMintForSamePepeRevertsEverAfterTransfers() public {
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        clubs.mintClub(1);
        // Pepe sold: the new holder cannot mint again.
        vm.prank(alice);
        pepes.transferFrom(alice, bob, 1);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        clubs.mintClub(1);
        // Club sold too, back to the pepe holder: still no second club.
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        clubs.mintClub(1);
        assertEq(clubs.totalSupply(), 1);
    }

    function test_ClubIdIsPepeIdNotSequential() public {
        uint256 big = type(uint256).max - 5;
        assertEq(mintFresh(bob, big), big);
        assertEq(mintFresh(bob, 0), 0);
        vm.prank(bob);
        assertEq(clubs.mintClub(2), 2);
        assertEq(clubs.ownerOf(big), bob);
        assertEq(clubs.tokenOfOwnerByIndex(bob, 0), big);
        assertEq(clubs.tokenOfOwnerByIndex(bob, 1), 0);
        assertEq(clubs.tokenOfOwnerByIndex(bob, 2), 2);
    }

    function test_ClosedSaleBlocksHolder() public {
        clubs.setSaleOpen(false);
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.SaleClosed.selector);
        clubs.mintClub(3);
    }
}

contract ClubsReviewLevelsTest is ClubsReviewBase {
    function test_MintAtLevelOnePricesAndViews() public view {
        assertEq(clubs.levelOf(1), 1);
        assertEq(clubs.upgradePrice(1), _upgradePrices()[0]);
        assertEq(clubs.upgradePrice(2), _upgradePrices()[1]);
        assertEq(clubs.upgradePrice(3), _upgradePrices()[2]);
        assertEq(clubs.upgradePrice(4), 0);
    }

    function test_BadLevelViewsRevert() public {
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.floorMask(0);
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.floorMask(5);
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.upgradePrice(0);
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.upgradePrice(5);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.levelOf(2);
    }

    function test_FloorMasksMatchCoordinateRulesBitForBit() public view {
        for (uint8 level = 1; level <= 4; ++level) {
            uint256 mask = clubs.floorMask(level);
            uint256 expected;
            for (uint256 y; y < 16; ++y) {
                for (uint256 x; x < 16; ++x) {
                    if (inFloor(level, x, y)) expected |= uint256(1) << (y * 16 + x);
                }
            }
            assertEq(mask, expected);
            if (level > 1) assertEq(mask & clubs.floorMask(level - 1), clubs.floorMask(level - 1), "holds the last");
        }
    }

    function test_UpgradeToFourExactSplitsReceiptsEvents() public {
        uint256 payerStart = token.balanceOf(alice);
        uint256 total;
        for (uint8 level = 1; level < 4; ++level) {
            uint256 p = _upgradePrices()[level - 1];
            uint256 burnBefore = token.balanceOf(BURN);
            uint256 vaultBefore = token.balanceOf(address(vault));
            vm.expectEmit(address(clubs));
            emit OGClubClubs.ClubUpgraded(1, level + 1, alice, p / 2, p - p / 2);
            vm.expectEmit(address(clubs));
            emit IERC4906.MetadataUpdate(1);
            vm.prank(alice);
            clubs.upgradeClub(1);
            assertEq(clubs.levelOf(1), level + 1);
            assertEq(token.balanceOf(BURN) - burnBefore, p / 2);
            assertEq(token.balanceOf(address(vault)) - vaultBefore, p - p / 2);
            total += p;
        }
        assertEq(payerStart - token.balanceOf(alice), total);
        assertEq(token.balanceOf(address(clubs)), 0);
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.MaxLevel.selector);
        clubs.upgradeClub(1);
        assertEq(clubs.levelOf(1), 4);
    }

    function test_OnlyHolderOrApprovedUpgradesAndCallerPays() public {
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        clubs.upgradeClub(1);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        clubs.upgradeClub(1); // contract owner has no power
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.upgradeClub(2);
        // Pepe holder of the club's pepe is not the club holder once the club is sold.
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        clubs.upgradeClub(1);
        // Token approval: operator pays.
        fund(operator, PRICE * 20);
        vm.prank(bob);
        clubs.approve(operator, 1);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(operator);
        clubs.upgradeClub(1);
        assertEq(token.balanceOf(bob), bobBefore);
        assertEq(token.balanceOf(operator), PRICE * 20 - _upgradePrices()[0]);
        // Operator-for-all.
        vm.prank(bob);
        clubs.approve(address(0), 1);
        vm.prank(operator);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        clubs.upgradeClub(1);
        vm.prank(bob);
        clubs.setApprovalForAll(operator, true);
        vm.prank(operator);
        clubs.upgradeClub(1);
        assertEq(clubs.levelOf(1), 3);
    }

    function test_UpgradeOneWeiShortRevertsAtomically() public {
        address poor = makeAddr("poor");
        pepes.mint(poor, 50);
        fund(poor, PRICE + _upgradePrices()[0] - 1);
        vm.prank(poor);
        clubs.mintClub(50);
        vm.prank(poor);
        vm.expectRevert();
        clubs.upgradeClub(50);
        assertEq(clubs.levelOf(50), 1);
        assertEq(token.balanceOf(poor), _upgradePrices()[0] - 1);
    }

    function test_LevelFollowsClubTransfer() public {
        upgradeTo(alice, 1, 3);
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        assertEq(clubs.levelOf(1), 3);
        vm.prank(bob);
        clubs.upgradeClub(1);
        assertEq(clubs.levelOf(1), 4);
    }

    /// Every single tile at every level: accepted exactly when the brief says it is in the room and not a door.
    function test_EverySingleTileAtEveryLevelAgainstModel() public {
        for (uint8 level = 1; level <= 4; ++level) {
            uint256 clubId = 500 + level;
            mintFresh(alice, clubId);
            upgradeTo(alice, clubId, level);
            for (uint8 y; y < 16; ++y) {
                for (uint8 x; x < 16; ++x) {
                    uint256 id = newDesign(alice, 1, 1, false);
                    bytes4 err = tryPlace(alice, clubId, id, x, y, 0);
                    if (!inFloor(level, x, y)) assertEq(err, OGClubClubs.OutOfRoom.selector);
                    else if (isDoor(x, y)) assertEq(err, OGClubClubs.BlocksDoor.selector);
                    else assertEq(err, bytes4(0));
                }
            }
            uint256 expectedCount = level == 1 ? 98 : level == 2 ? 138 : level == 3 ? 198 : 254;
            assertEq(clubs.pieceCount(clubId), expectedCount);
        }
    }

    function test_ExpansionEdgesRevertBeforeAndWorkAfterAndPiecesKeepTiles() public {
        uint256 a = newDesign(alice, 1, 1, false); // x 10..13 strip
        uint256 b = newDesign(alice, 1, 1, false); // L front wing
        uint256 c = newDesign(alice, 2, 1, false); // x 14..15
        uint256 d = newDesign(alice, 1, 1, false); // far corner
        uint256 e = newDesign(alice, 4, 4, false);
        assertEq(tryPlace(alice, 1, e, 6, 6, 0), bytes4(0)); // fills (6..9, 6..9)
        assertEq(tryPlace(alice, 1, a, 13, 9, 0), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, b, 9, 15, 0), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, c, 14, 0, 0), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, d, 15, 15, 0), OGClubClubs.OutOfRoom.selector);
        upgradeTo(alice, 1, 2);
        assertEq(tryPlace(alice, 1, b, 9, 15, 0), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, b, 0, 10, 0), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, a, 13, 9, 0), bytes4(0));
        upgradeTo(alice, 1, 3);
        assertEq(tryPlace(alice, 1, c, 14, 0, 0), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, d, 10, 10, 0), OGClubClubs.OutOfRoom.selector); // L notch stays closed
        assertEq(tryPlace(alice, 1, b, 9, 15, 0), bytes4(0));
        upgradeTo(alice, 1, 4);
        assertEq(tryPlace(alice, 1, c, 14, 0, 0), bytes4(0));
        assertEq(tryPlace(alice, 1, d, 15, 15, 0), bytes4(0));
        // Old tiles are still taken and the original 4x4 cannot be re-placed over.
        assertTrue(clubs.tileTaken(1, 6, 6));
        assertTrue(clubs.tileTaken(1, 9, 9));
        assertTrue(clubs.tileTaken(1, 13, 9));
        uint256 f = newDesign(alice, 1, 1, false);
        assertEq(tryPlace(alice, 1, f, 7, 7, 0), OGClubClubs.TileTaken.selector);
        assertEq(clubs.pieceCount(1), 5);
    }

    function test_DoorBlockedByMultiTilePiecesAtEveryLevel() public {
        for (uint8 level = 1; level <= 4; ++level) {
            uint256 clubId = 600 + level;
            mintFresh(alice, clubId);
            upgradeTo(alice, clubId, level);
            uint256 wide = newDesign(alice, 4, 1, false);
            assertEq(tryPlace(alice, clubId, wide, 0, 4, 0), OGClubClubs.BlocksDoor.selector);
            assertEq(tryPlace(alice, clubId, wide, 1, 4, 0), OGClubClubs.BlocksDoor.selector);
            assertEq(tryPlace(alice, clubId, wide, 1, 1, 1), OGClubClubs.BlocksDoor.selector); // vertical over (1,4)
            assertEq(tryPlace(alice, clubId, wide, 2, 4, 0), bytes4(0));
            assertFalse(clubs.tileTaken(clubId, 0, 4));
            assertFalse(clubs.tileTaken(clubId, 1, 4));
        }
    }
}

contract ClubsReviewWallsTest is ClubsReviewBase {
    function test_WallFootprintRulesAndLockCarriesFlag() public {
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(900, 1, 2, true);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(900, 5, 1, true);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(900, 0, 1, true);
        clubs.setFootprint(900, 4, 1, true);
        (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(900);
        assertEq(w, 4);
        assertEq(h, 1);
        assertTrue(set && wall && !locked);
        clubs.setFootprint(900, 3, 1, false); // still revisable, wall flag can flip before lock
        (,,,, wall) = clubs.footprintOf(900);
        assertFalse(wall);
        clubs.setFootprint(900, 3, 1, true);
        stock(alice, 900, 1);
        assertEq(tryPlace(alice, 1, 900, 0, 0, 0), bytes4(0));
        (w,, set, locked, wall) = clubs.footprintOf(900);
        assertTrue(set && locked && wall);
        vm.expectRevert(OGClubClubs.FootprintLocked.selector);
        clubs.setFootprint(900, 3, 1, false);
        OGClubClubs.Piece[] memory ps = clubs.piecesOf(1);
        assertEq(ps.length, 1);
        assertTrue(ps[0].wall);
        assertEq(ps[0].rot, 0);
    }

    function test_EveryWidthStartAndSideAtEveryLevelAgainstModel() public {
        for (uint8 level = 1; level <= 4; ++level) {
            for (uint8 side; side < 2; ++side) {
                for (uint8 w = 1; w <= 4; ++w) {
                    for (uint8 start; start < 18; ++start) {
                        uint256 clubId = uint256(keccak256(abi.encode(level, side, w, start)));
                        mintFresh(alice, clubId);
                        upgradeTo(alice, clubId, level);
                        uint256 id = newDesign(alice, w, 1, true);
                        bytes4 err = tryPlace(alice, clubId, id, start, 0, side);
                        bool coversDoor = side == 1 && start <= 4 && start + w > 4;
                        if (start + w > wallLen(level, side)) assertEq(err, OGClubClubs.OutOfRoom.selector);
                        else if (coversDoor) assertEq(err, OGClubClubs.BlocksDoor.selector);
                        else assertEq(err, bytes4(0));
                    }
                }
            }
        }
    }

    function test_DoorPositionOnSideOne() public {
        uint256 two = newDesign(alice, 2, 1, true);
        assertEq(tryPlace(alice, 1, two, 3, 0, 1), OGClubClubs.BlocksDoor.selector); // 3..4
        assertEq(tryPlace(alice, 1, two, 4, 0, 1), OGClubClubs.BlocksDoor.selector); // 4..5
        assertEq(tryPlace(alice, 1, two, 5, 0, 1), bytes4(0)); // 5..6
        uint256 two0 = newDesign(alice, 2, 1, true);
        assertEq(tryPlace(alice, 1, two0, 3, 0, 0), bytes4(0)); // side 0 has no door
        assertFalse(clubs.wallTaken(1, 1, 4));
        assertTrue(clubs.wallTaken(1, 1, 5));
        assertTrue(clubs.wallTaken(1, 0, 4));
    }

    function test_PastEndThenFitsAfterUpgrade() public {
        uint256 s0 = newDesign(alice, 4, 1, true);
        uint256 s1 = newDesign(alice, 4, 1, true);
        assertEq(tryPlace(alice, 1, s0, 7, 0, 0), OGClubClubs.OutOfRoom.selector); // 7..10 > 10
        assertEq(tryPlace(alice, 1, s0, 6, 0, 0), bytes4(0));
        uint256 s0b = newDesign(alice, 4, 1, true);
        upgradeTo(alice, 1, 2);
        assertEq(tryPlace(alice, 1, s0b, 11, 0, 0), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, s1, 7, 0, 1), OGClubClubs.OutOfRoom.selector); // side 1 still 10 at L2
        assertEq(tryPlace(alice, 1, s0b, 10, 0, 0), bytes4(0));
        upgradeTo(alice, 1, 3);
        assertEq(tryPlace(alice, 1, s1, 13, 0, 1), OGClubClubs.OutOfRoom.selector); // 13..16 > 16
        assertEq(tryPlace(alice, 1, s1, 12, 0, 1), bytes4(0));
        assertTrue(clubs.wallTaken(1, 1, 15));
        uint256 s0c = newDesign(alice, 2, 1, true);
        assertEq(tryPlace(alice, 1, s0c, 14, 0, 0), OGClubClubs.OutOfRoom.selector); // side 0 still 14 at L3
        upgradeTo(alice, 1, 4);
        assertEq(tryPlace(alice, 1, s0c, 14, 0, 0), bytes4(0));
        assertTrue(clubs.wallTaken(1, 0, 15));
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.wallTaken(1, 0, 16);
    }

    function test_OverlapPerSideAndSidesAndFloorIndependent() public {
        uint256 a = newDesign(alice, 3, 1, true);
        uint256 b = newDesign(alice, 2, 1, true);
        uint256 c = newDesign(alice, 3, 1, true);
        uint256 f = newDesign(alice, 3, 1, false);
        assertEq(tryPlace(alice, 1, a, 0, 0, 0), bytes4(0)); // side 0: 0..2
        assertEq(tryPlace(alice, 1, b, 2, 0, 0), OGClubClubs.TileTaken.selector);
        assertEq(tryPlace(alice, 1, b, 3, 0, 0), bytes4(0));
        assertEq(tryPlace(alice, 1, c, 0, 0, 1), bytes4(0)); // side 1: 0..2 does not collide with side 0
        assertEq(tryPlace(alice, 1, f, 0, 0, 0), bytes4(0)); // floor (0..2,0) does not collide with walls
        assertTrue(clubs.tileTaken(1, 0, 0));
        assertTrue(clubs.wallTaken(1, 0, 0));
        assertTrue(clubs.wallTaken(1, 1, 0));
        assertFalse(clubs.wallTaken(1, 1, 3));
        assertEq(clubs.pieceCount(1), 4);
    }

    function test_BadWallCoordinatesRevert() public {
        uint256 a = newDesign(alice, 1, 1, true);
        assertEq(tryPlace(alice, 1, a, 0, 1, 0), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, a, 0, 255, 1), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, a, 0, 0, 2), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, a, 0, 0, 255), OGClubClubs.OutOfRoom.selector);
        assertEq(tryPlace(alice, 1, a, 255, 0, 0), OGClubClubs.OutOfRoom.selector);
        (,,, bool locked,) = clubs.footprintOf(a);
        assertFalse(locked);
        assertEq(clubs.pieceCount(1), 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.wallTaken(1, 2, 0);
    }
}

contract ClubsReviewDesignTest is ClubsReviewBase {
    function test_SecondCopyRevertsFloorAndWallOtherClubsUnaffectedAndSurvivesTransfer() public {
        uint256 fl = newDesign(alice, 1, 1, false);
        uint256 wl = newDesign(alice, 1, 1, true);
        vm.prank(alice);
        clubs.mintClub(3);
        assertFalse(clubs.hasDesign(1, fl));
        assertEq(tryPlace(alice, 1, fl, 0, 0, 0), bytes4(0));
        assertEq(tryPlace(alice, 1, wl, 0, 0, 0), bytes4(0));
        assertTrue(clubs.hasDesign(1, fl));
        assertTrue(clubs.hasDesign(1, wl));
        // A second copy, even at a free, valid spot, is refused.
        assertEq(tryPlace(alice, 1, fl, 5, 5, 0), OGClubClubs.AlreadyHasDesign.selector);
        assertEq(tryPlace(alice, 1, wl, 5, 0, 1), OGClubClubs.AlreadyHasDesign.selector);
        // The other club may hold one of each.
        assertFalse(clubs.hasDesign(3, fl));
        assertEq(tryPlace(alice, 3, fl, 5, 5, 0), bytes4(0));
        assertEq(tryPlace(alice, 3, wl, 5, 0, 1), bytes4(0));
        // Transfer the club to bob: still one of each for bob.
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        stock(bob, fl, 1);
        stock(bob, wl, 1);
        assertEq(tryPlace(bob, 1, fl, 7, 7, 0), OGClubClubs.AlreadyHasDesign.selector);
        assertEq(tryPlace(bob, 1, wl, 7, 0, 0), OGClubClubs.AlreadyHasDesign.selector);
        assertEq(clubs.pieceCount(1), 2);
        assertEq(furniture.balanceOf(address(clubs), fl), 2);
        assertEq(furniture.balanceOf(address(clubs), wl), 2);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.hasDesign(2, fl);
    }
}

contract ClubsReviewFixesTest is ClubsReviewBase {
    function deployWith(address vault_, IDelegateRegistry reg, uint256[3] memory prices, address pepes_)
        internal
        returns (OGClubClubs)
    {
        return new OGClubClubs(
            token,
            vault_,
            PRICE,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            IERC721(pepes_),
            reg,
            prices[0],
            prices[1],
            prices[2]
        );
    }

    function test_ConstructorRejections() public {
        uint256[3] memory ok = _upgradePrices();
        vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
        deployWith(BURN, registry, ok, address(pepes));
        vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
        deployWith(address(token), registry, ok, address(pepes));
        vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
        deployWith(address(furniture), registry, ok, address(pepes));
        vm.expectRevert(OGClubClubs.ZeroAddress.selector);
        deployWith(address(vault), registry, ok, address(0));
        for (uint256 i; i < 3; ++i) {
            uint256[3] memory bad = ok;
            bad[i] = 0;
            vm.expectRevert(OGClubClubs.ZeroPrice.selector);
            deployWith(address(vault), registry, bad, address(pepes));
        }
        // Zero registry is allowed and switches delegation off.
        OGClubClubs c = deployWith(address(vault), IDelegateRegistry(address(0)), ok, address(pepes));
        assertEq(address(c.delegates()), address(0));
        assertEq(address(c.pepes()), address(pepes));
        assertEq(c.upgradePrice(1), ok[0]);
        assertEq(c.upgradePrice(3), ok[2]);
        assertEq(c.MAX_PIECES(), 285);
    }

    function test_BadPlacementDataEveryShape() public {
        uint256 id = newDesign(alice, 1, 1, false);
        bytes[] memory bad = new bytes[](9);
        bad[0] = "";
        bad[1] = abi.encode(uint256(1), uint256(2), uint256(2));
        bad[2] = abi.encode(uint256(1), uint256(2), uint256(2), uint256(0), uint256(0));
        bad[3] = abi.encodePacked(uint256(1), uint8(2), uint8(2), uint8(0));
        bad[4] = abi.encode(uint256(1), uint256(256), uint256(2), uint256(0));
        bad[5] = abi.encode(uint256(1), uint256(2), uint256(256), uint256(0));
        bad[6] = abi.encode(uint256(1), uint256(2), uint256(2), uint256(256));
        bad[7] = abi.encode(uint256(1), type(uint256).max, uint256(2), uint256(0));
        bad[8] = bytes.concat(abi.encode(uint256(1), uint256(2), uint256(2)), hex"00");
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(OGClubClubs.BadPlacementData.selector);
            furniture.safeTransferFrom(alice, address(clubs), id, 1, bad[i]);
        }
        (,,, bool locked,) = clubs.footprintOf(id);
        assertFalse(locked);
        assertEq(clubs.pieceCount(1), 0);
        assertEq(furniture.balanceOf(alice, id), 2);
    }

    /// 254 floor + 31 wall single-wide designs fill a level-4 club; the 286th distinct design is ClubFull.
    function test_ClubFullAt285() public {
        upgradeTo(alice, 1, 4);
        uint256 placed;
        for (uint8 y; y < 16; ++y) {
            for (uint8 x; x < 16; ++x) {
                if (isDoor(x, y)) continue;
                uint256 id = newDesign(alice, 1, 1, false);
                assertEq(tryPlace(alice, 1, id, x, y, 0), bytes4(0));
                ++placed;
            }
        }
        for (uint8 side; side < 2; ++side) {
            for (uint8 pos; pos < 16; ++pos) {
                if (side == 1 && pos == 4) continue;
                uint256 id = newDesign(alice, 1, 1, true);
                assertEq(tryPlace(alice, 1, id, pos, 0, side), bytes4(0));
                ++placed;
            }
        }
        assertEq(placed, 285);
        assertEq(clubs.pieceCount(1), 285);
        uint256 extraFloor = newDesign(alice, 1, 1, false);
        uint256 extraWall = newDesign(alice, 1, 1, true);
        assertEq(tryPlace(alice, 1, extraFloor, 0, 4, 0), OGClubClubs.ClubFull.selector);
        assertEq(tryPlace(alice, 1, extraWall, 4, 0, 1), OGClubClubs.ClubFull.selector);
        assertEq(clubs.pieceCount(1), 285);
    }
}

/// @dev Stateless fuzz over random levels, sides, positions, footprints and rotations against an
///      independent tile model. Each rejected placement must leave every observable unchanged.
contract ClubsReviewFuzzTest is ClubsReviewBase {
    bool[256] private grid;
    bool[16][2] private wallGrid;
    uint256[] private placedIds;

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_RandomSequencesMatchModel(uint256 seed) public {
        uint8 level = 1;
        uint256 clubId = 1;
        for (uint256 step; step < 40; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            if (r % 9 == 0 && level < 4) {
                vm.prank(alice);
                clubs.upgradeClub(clubId);
                ++level;
                continue;
            }
            _step(r, level, clubId);
        }
        _checkAgainstContract(clubId, level);
    }

    struct Op {
        bool wall;
        bool dup;
        uint8 w;
        uint8 h;
        uint8 x;
        uint8 y;
        uint8 rot;
        uint256 id;
    }

    function _step(uint256 r, uint8 level, uint256 clubId) internal {
        Op memory op;
        op.wall = (r >> 8) % 3 == 0;
        op.w = uint8(1 + (r >> 16) % 4);
        op.h = op.wall ? 1 : uint8(1 + (r >> 24) % 4);
        op.x = uint8((r >> 32) % 18);
        op.y = op.wall ? ((r >> 40) % 8 == 0 ? 1 : 0) : uint8((r >> 40) % 18);
        op.rot = op.wall ? uint8((r >> 48) % 3) : uint8((r >> 48) % 5);
        op.dup = placedIds.length > 0 && (r >> 56) % 6 == 0;
        if (op.dup) {
            op.id = placedIds[(r >> 64) % placedIds.length];
            (op.w, op.h,,, op.wall) = clubs.footprintOf(op.id);
        } else {
            op.id = newDesign(alice, op.w, op.h, op.wall);
        }
        bytes4 expected =
            op.dup ? OGClubClubs.AlreadyHasDesign.selector : _expect(level, op.w, op.h, op.x, op.y, op.rot, op.wall);
        uint256 count = clubs.pieceCount(clubId);
        uint256 held = furniture.balanceOf(address(clubs), op.id);
        bytes4 got = tryPlace(alice, clubId, op.id, op.x, op.y, op.rot);
        assertEq(got, expected, "placement outcome differs from model");
        if (got == bytes4(0)) {
            _apply(op.w, op.h, op.x, op.rot, op.y, op.wall);
            placedIds.push(op.id);
            assertTrue(clubs.hasDesign(clubId, op.id));
        } else {
            assertEq(clubs.pieceCount(clubId), count);
            assertEq(furniture.balanceOf(address(clubs), op.id), held);
            if (!op.dup) {
                (,,, bool locked,) = clubs.footprintOf(op.id);
                assertFalse(locked, "rejected placement locked footprint");
                assertFalse(clubs.hasDesign(clubId, op.id));
            }
        }
    }

    function _expect(uint8 level, uint8 w, uint8 h, uint8 x, uint8 y, uint8 rot, bool wall)
        internal
        view
        returns (bytes4)
    {
        if (wall) {
            if (y != 0 || rot > 1 || uint256(x) + w > wallLen(level, rot)) return OGClubClubs.OutOfRoom.selector;
            if (rot == 1 && x <= 4 && uint256(x) + w > 4) return OGClubClubs.BlocksDoor.selector;
            for (uint256 p = x; p < uint256(x) + w; ++p) {
                if (wallGrid[rot][p]) return OGClubClubs.TileTaken.selector;
            }
            return bytes4(0);
        }
        if (rot > 3) return OGClubClubs.OutOfRoom.selector;
        (uint256 ww, uint256 hh) = rot % 2 == 1 ? (uint256(h), uint256(w)) : (uint256(w), uint256(h));
        bool door;
        bool taken;
        for (uint256 yy = y; yy < y + hh; ++yy) {
            for (uint256 xx = x; xx < x + ww; ++xx) {
                if (!inFloor(level, xx, yy)) return OGClubClubs.OutOfRoom.selector;
                if (isDoor(xx, yy)) door = true;
                if (grid[yy * 16 + xx]) taken = true;
            }
        }
        if (door) return OGClubClubs.BlocksDoor.selector;
        if (taken) return OGClubClubs.TileTaken.selector;
        return bytes4(0);
    }

    function _apply(uint8 w, uint8 h, uint8 x, uint8 rot, uint8 y, bool wall) internal {
        if (wall) {
            for (uint256 p = x; p < uint256(x) + w; ++p) {
                wallGrid[rot][p] = true;
            }
            return;
        }
        (uint256 ww, uint256 hh) = rot % 2 == 1 ? (uint256(h), uint256(w)) : (uint256(w), uint256(h));
        for (uint256 yy = y; yy < y + hh; ++yy) {
            for (uint256 xx = x; xx < x + ww; ++xx) {
                grid[yy * 16 + xx] = true;
            }
        }
    }

    function _checkAgainstContract(uint256 clubId, uint8 level) internal view {
        for (uint8 yy; yy < 16; ++yy) {
            for (uint8 xx; xx < 16; ++xx) {
                if (!inFloor(level, xx, yy)) {
                    assertFalse(grid[uint256(yy) * 16 + xx]);
                    continue;
                }
                assertEq(clubs.tileTaken(clubId, xx, yy), grid[uint256(yy) * 16 + xx]);
                if (isDoor(xx, yy)) assertFalse(clubs.tileTaken(clubId, xx, yy));
            }
        }
        for (uint8 side; side < 2; ++side) {
            for (uint8 p; p < wallLen(level, side); ++p) {
                assertEq(clubs.wallTaken(clubId, side, p), wallGrid[side][p]);
            }
        }
        assertFalse(clubs.wallTaken(clubId, 1, 4));
        OGClubClubs.Piece[] memory ps = clubs.piecesOf(clubId);
        assertEq(ps.length, placedIds.length);
        for (uint256 i; i < ps.length; ++i) {
            assertEq(ps[i].furnitureId, placedIds[i]);
            for (uint256 j; j < i; ++j) {
                assertTrue(ps[i].furnitureId != ps[j].furnitureId, "one of each broken");
            }
        }
    }
}
