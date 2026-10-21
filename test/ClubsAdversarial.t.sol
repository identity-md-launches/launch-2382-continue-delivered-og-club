// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors, IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {MockOG} from "../src/mocks/MockOG.sol";

/// @dev An ERC-721 receiver that, inside the mint callback, places furniture into the club it was just
///      given (allowed) and tries to mint again and upgrade (must fail).
contract PlacingReentrantReceiver is IERC721Receiver {
    OGClubClubs public immutable clubs;
    OGClubFurniture public immutable furniture;
    bool public placedInCallback;
    bool public mintAgainSucceeded;
    bool public mintToAgainSucceeded;
    bytes public mintAgainError;

    constructor(OGClubClubs clubs_, OGClubFurniture furniture_) {
        clubs = clubs_;
        furniture = furniture_;
    }

    function go() external returns (uint256) {
        clubs.token().approve(address(clubs), type(uint256).max);
        return clubs.mintClub(4);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(clubs)) return this.onERC721Received.selector;
        furniture.safeTransferFrom(address(this), address(clubs), 1, 1, abi.encode(id, uint8(5), uint8(5), uint8(0)));
        placedInCallback = true;
        try clubs.mintClub(5) {
            mintAgainSucceeded = true;
        } catch (bytes memory err) {
            mintAgainError = err;
        }
        try clubs.upgradeClub(id) {
            mintToAgainSucceeded = true;
        } catch {}
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
}

/// @dev Independent adversarial unit tests for OGClubClubs with the real OGClubFurniture and vault.
contract ClubsAdversarialTest is Test {
    uint256 internal constant PRICE = 100_000e18 + 3;

    MockSwarmPepe internal pepes;
    IDelegateRegistry internal delegates;

    function _upgradePrices() internal pure returns (uint256[3] memory) {
        return [uint256(200_000e18 + 1), 400_000e18 + 3, 800_000e18 + 7];
    }
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubFarmVault internal vault;
    OGClubClubs internal clubs;

    address internal admin = makeAddr("adv admin");
    address internal royalty = makeAddr("adv royalty");
    address internal alice = makeAddr("adv alice");
    address internal bob = makeAddr("adv bob");
    address internal carol = makeAddr("adv carol");

    function setUp() public {
        pepes = new MockSwarmPepe();
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), royalty);
        vault = new OGClubFarmVault(token, address(this));
        clubs = new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            admin,
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        furniture.grantMinter(address(this));
        vm.startPrank(admin);
        clubs.setSaleOpen(true);
        clubs.setFootprint(1, 1, 1, false);
        clubs.setFootprint(2, 2, 1, false);
        clubs.setFootprint(3, 2, 2, false);
        clubs.setFootprint(4, 4, 4, false);
        clubs.setFootprint(5, 3, 1, false);
        clubs.setFootprint(11, 1, 1, false);
        clubs.setFootprint(12, 2, 1, false);
        clubs.setFootprint(13, 2, 2, false);
        clubs.setFootprint(15, 3, 1, false);
        clubs.setFootprint(16, 3, 1, false);
        clubs.setFootprint(17, 3, 1, false);
        vm.stopPrank();
        _fund(alice, 10 * PRICE);
        _fund(bob, 10 * PRICE);
        for (uint256 id = 1; id <= 17; ++id) {
            _stock(alice, id, 50);
            _stock(bob, id, 50);
        }
        pepes.mint(alice, 1);
        pepes.mint(bob, 2);
        pepes.mint(bob, 3);
        vm.prank(alice);
        assertEq(clubs.mintClub(1), 1);
    }

    // ------------------------------------------------------------------ helpers

    function _fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(clubs), type(uint256).max);
    }

    function _stock(address who, uint256 id, uint256 amount) internal {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = amount;
        furniture.mintBatch(who, ids, amounts);
    }

    function _place(address from, uint256 clubId, uint256 item, uint8 x, uint8 y, uint8 rot) internal {
        vm.prank(from);
        furniture.safeTransferFrom(from, address(clubs), item, 1, abi.encode(clubId, x, y, rot));
    }

    function _expectPlaceRevert(address from, uint256 clubId, uint256 item, uint8 x, uint8 y, uint8 rot, bytes4 err)
        internal
    {
        uint256 countBefore = clubs.pieceCount(clubId);
        uint256 heldBefore = furniture.balanceOf(address(clubs), item);
        uint256 fromBefore = furniture.balanceOf(from, item);
        (,,, bool lockedBefore,) = clubs.footprintOf(item);
        vm.prank(from);
        vm.expectRevert(err);
        furniture.safeTransferFrom(from, address(clubs), item, 1, abi.encode(clubId, x, y, rot));
        assertEq(clubs.pieceCount(clubId), countBefore, "piece count changed on rejection");
        assertEq(furniture.balanceOf(address(clubs), item), heldBefore, "custody changed on rejection");
        assertEq(furniture.balanceOf(from, item), fromBefore, "sender balance changed on rejection");
        (,,, bool lockedAfter,) = clubs.footprintOf(item);
        assertEq(lockedAfter, lockedBefore, "lock changed on rejection");
    }

    function _expectRawRevert(address from, uint256 item, bytes memory data) internal {
        uint256 heldBefore = furniture.balanceOf(address(clubs), item);
        vm.prank(from);
        vm.expectRevert(OGClubClubs.BadPlacementData.selector);
        furniture.safeTransferFrom(from, address(clubs), item, 1, data);
        assertEq(furniture.balanceOf(address(clubs), item), heldBefore);
    }

    // ------------------------------------------------------------------ grid edges

    function test_Uint8ExtremesAndRotFourAreOutOfRoom() public {
        _expectPlaceRevert(alice, 1, 1, 255, 0, 0, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 1, 0, 255, 0, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 1, 10, 0, 0, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 1, 0, 10, 0, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 1, 5, 5, 4, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 1, 5, 5, 255, OGClubClubs.OutOfRoom.selector);
        (,,, bool locked,) = clubs.footprintOf(1);
        assertFalse(locked, "rejected attempts must not lock the footprint");
    }

    function test_ExactRightAndBottomEdgesFitAndOneMoreDoesNot() public {
        _expectPlaceRevert(alice, 1, 4, 7, 6, 0, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 4, 6, 7, 0, OGClubClubs.OutOfRoom.selector);
        _place(alice, 1, 4, 6, 6, 0); // 4x4 covering 6..9 x 6..9
        _place(alice, 1, 1, 9, 0, 0);
        _place(alice, 1, 11, 0, 9, 0);
        assertTrue(clubs.tileTaken(1, 9, 9));
        assertTrue(clubs.tileTaken(1, 6, 6));
        assertFalse(clubs.tileTaken(1, 5, 9));
        assertEq(clubs.pieceCount(1), 3);
    }

    function test_RotationSwapsOnlyOnOddRotations() public {
        // 3x1 (id 5). rot 0/2: 3 wide, 1 tall. rot 1/3: 1 wide, 3 tall.
        _expectPlaceRevert(alice, 1, 5, 8, 0, 0, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 5, 8, 0, 2, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 5, 9, 8, 1, OGClubClubs.OutOfRoom.selector);
        _expectPlaceRevert(alice, 1, 5, 9, 8, 3, OGClubClubs.OutOfRoom.selector);

        _place(alice, 1, 5, 9, 0, 1); // covers (9,0),(9,1),(9,2)
        _place(alice, 1, 15, 7, 9, 2); // covers (7,9),(8,9),(9,9)
        _place(alice, 1, 16, 8, 3, 3); // covers (8,3),(8,4),(8,5)
        _place(alice, 1, 17, 2, 0, 0); // covers (2,0),(3,0),(4,0)
        assertTrue(clubs.tileTaken(1, 9, 2));
        assertFalse(clubs.tileTaken(1, 9, 3));
        assertTrue(clubs.tileTaken(1, 9, 9));
        assertTrue(clubs.tileTaken(1, 8, 5));
        assertFalse(clubs.tileTaken(1, 8, 6));
        assertTrue(clubs.tileTaken(1, 4, 0));
        assertFalse(clubs.tileTaken(1, 5, 0));

        OGClubClubs.Piece[] memory pieces = clubs.piecesOf(1);
        assertEq(pieces.length, 4);
        assertEq(pieces[2].x, 8);
        assertEq(pieces[2].y, 3);
        assertEq(pieces[2].rot, 3);
    }

    function test_EveryShapeThatTouchesEitherDoorTileIsRejected() public {
        _expectPlaceRevert(alice, 1, 1, 0, 4, 0, OGClubClubs.BlocksDoor.selector);
        _expectPlaceRevert(alice, 1, 1, 1, 4, 0, OGClubClubs.BlocksDoor.selector);
        _expectPlaceRevert(alice, 1, 4, 0, 1, 0, OGClubClubs.BlocksDoor.selector); // rows 1..4 cols 0..3
        _expectPlaceRevert(alice, 1, 4, 1, 4, 0, OGClubClubs.BlocksDoor.selector); // corner on (1,4)
        _expectPlaceRevert(alice, 1, 2, 1, 3, 1, OGClubClubs.BlocksDoor.selector); // vertical (1,3),(1,4)
        _expectPlaceRevert(alice, 1, 5, 1, 2, 3, OGClubClubs.BlocksDoor.selector); // vertical (1,2..4)
        // Neighbours of the door are fine.
        _place(alice, 1, 1, 2, 4, 0);
        _place(alice, 1, 3, 0, 2, 0); // (0..1, 2..3)
        _place(alice, 1, 13, 0, 5, 0); // (0..1, 5..6)
        assertFalse(clubs.tileTaken(1, 0, 4), "door tile reported as furniture");
        assertFalse(clubs.tileTaken(1, 1, 4), "door approach reported as furniture");
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_SingleTileDoorRuleIsExactlyTheTwoDoorTiles(uint8 x, uint8 y) public {
        x = uint8(bound(x, 0, 9));
        y = uint8(bound(y, 0, 9));
        bool door = y == 4 && x <= 1;
        if (door) {
            _expectPlaceRevert(alice, 1, 1, x, y, 0, OGClubClubs.BlocksDoor.selector);
        } else {
            _place(alice, 1, 1, x, y, 0);
            assertTrue(clubs.tileTaken(1, x, y));
            assertEq(clubs.pieceCount(1), 1);
        }
    }

    function test_OverlapAtASingleSharedTileIsRejected() public {
        _place(alice, 1, 4, 3, 3, 0); // 3..6 x 3..6
        _expectPlaceRevert(alice, 1, 1, 6, 6, 0, OGClubClubs.TileTaken.selector);
        _expectPlaceRevert(alice, 1, 3, 2, 2, 0, OGClubClubs.TileTaken.selector); // shares (3,3)
        _expectPlaceRevert(alice, 1, 2, 6, 2, 1, OGClubClubs.TileTaken.selector); // (6,2),(6,3): shares (6,3)
        _expectPlaceRevert(alice, 1, 2, 5, 6, 2, OGClubClubs.TileTaken.selector); // (5,6),(6,6)
        // Touching edges is not overlapping.
        _place(alice, 1, 2, 7, 6, 2); // (7,6),(8,6)
        _place(alice, 1, 12, 6, 1, 1); // (6,1),(6,2)
        assertEq(clubs.pieceCount(1), 3);
    }

    function test_TileTakenViewBounds() public {
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.tileTaken(1, 10, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.tileTaken(1, 0, 10);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.tileTaken(2, 0, 0);
        assertFalse(clubs.tileTaken(1, 9, 9));
    }

    // ------------------------------------------------------------------ data / caller validation

    function test_MalformedDataAlwaysReverts() public {
        // Too short, too long, empty, packed encoding.
        _expectRawRevert(alice, 1, "");
        _expectRawRevert(alice, 1, abi.encode(uint256(1), uint8(2), uint8(2)));
        _expectRawRevert(alice, 1, abi.encode(uint256(1), uint8(2), uint8(2), uint8(0), uint256(0)));
        _expectRawRevert(alice, 1, abi.encodePacked(uint256(1), uint8(2), uint8(2), uint8(0)));
        // Right length but coordinates outside uint8 (non-canonical): must not wrap to a valid tile.
        _expectRawRevert(alice, 1, abi.encode(uint256(1), uint256(258), uint256(2), uint256(0)));
        _expectRawRevert(alice, 1, abi.encode(uint256(1), uint256(2), uint256(256 + 2), uint256(0)));
        _expectRawRevert(alice, 1, abi.encode(uint256(1), uint256(2), uint256(2), uint256(256)));
        assertEq(clubs.pieceCount(1), 0);
        assertFalse(clubs.tileTaken(1, 2, 2));
    }

    function test_MissingClubIdsRejectedIncludingZeroAndMax() public {
        uint256[3] memory missing = [uint256(0), 2, type(uint256).max];
        for (uint256 i; i < missing.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(OGClubClubs.NonexistentToken.selector);
            furniture.safeTransferFrom(
                alice, address(clubs), 1, 1, abi.encode(missing[i], uint8(2), uint8(2), uint8(0))
            );
        }
        assertEq(furniture.balanceOf(address(clubs), 1), 0);
        (,,, bool locked,) = clubs.footprintOf(1);
        assertFalse(locked);
        // A club minted later starts empty: nothing was recorded against its id in advance.
        vm.prank(bob);
        assertEq(clubs.mintClub(2), 2);
        assertEq(clubs.pieceCount(2), 0);
        assertFalse(clubs.tileTaken(2, 2, 2));
    }

    function test_MinterCannotPushFurnitureStraightIntoTheClubContract() public {
        // A mint has from == address(0): it can never be authorised, whatever the data.
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 1;
        amounts[0] = 1;
        vm.expectRevert();
        furniture.mintBatch(address(clubs), ids, amounts);

        ids = new uint256[](2);
        amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        amounts[0] = 1;
        amounts[1] = 1;
        vm.expectRevert(OGClubClubs.BatchNotAccepted.selector);
        furniture.mintBatch(address(clubs), ids, amounts);
        assertEq(furniture.balanceOf(address(clubs), 1), 0);
        assertEq(furniture.balanceOf(address(clubs), 2), 0);
    }

    function test_HookCalledDirectlyByAnyoneButFurnitureIsRejected() public {
        bytes memory data = abi.encode(uint256(1), uint8(2), uint8(2), uint8(0));
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.NotFurniture.selector);
        clubs.onERC1155Received(alice, alice, 1, 1, data);
        vm.prank(admin);
        vm.expectRevert(OGClubClubs.NotFurniture.selector);
        clubs.onERC1155Received(admin, alice, 1, 1, data);
        assertEq(clubs.pieceCount(1), 0);
    }

    function test_AmountZeroAndTwoRejected() public {
        bytes memory data = abi.encode(uint256(1), uint8(2), uint8(2), uint8(0));
        vm.startPrank(alice);
        vm.expectRevert(OGClubClubs.BadAmount.selector);
        furniture.safeTransferFrom(alice, address(clubs), 1, 0, data);
        vm.expectRevert(OGClubClubs.BadAmount.selector);
        furniture.safeTransferFrom(alice, address(clubs), 1, 2, data);
        vm.stopPrank();
        assertEq(clubs.pieceCount(1), 0);
        assertEq(furniture.balanceOf(address(clubs), 1), 0);
    }

    function test_UnfootprintedIdRejectedAndDoesNotLock() public {
        _expectPlaceRevert(alice, 1, 6, 2, 2, 0, OGClubClubs.NoFootprint.selector);
        (uint8 w, uint8 h, bool set, bool locked,) = clubs.footprintOf(6);
        assertEq(w, 0);
        assertEq(h, 0);
        assertFalse(set);
        assertFalse(locked);
        vm.prank(admin);
        clubs.setFootprint(6, 1, 4, false);
        _place(alice, 1, 6, 2, 0, 0);
        assertTrue(clubs.tileTaken(1, 2, 3));
        (,,, locked,) = clubs.footprintOf(6);
        assertTrue(locked);
    }

    // ------------------------------------------------------------------ authorization

    function test_ClubApprovalsGrantPlacementAndRevocationRemovesIt() public {
        // Bob is approved for club 1 only through getApproved.
        vm.prank(alice);
        clubs.approve(bob, 1);
        _place(bob, 1, 1, 2, 2, 0);
        vm.prank(alice);
        clubs.approve(address(0), 1);
        _expectPlaceRevert(bob, 1, 1, 3, 3, 0, OGClubClubs.NotClubOwner.selector);

        // Bob as operator for all of Alice's clubs.
        vm.prank(alice);
        clubs.setApprovalForAll(bob, true);
        _place(bob, 1, 11, 3, 3, 0);
        vm.prank(alice);
        clubs.setApprovalForAll(bob, false);
        _expectPlaceRevert(bob, 1, 1, 4, 4, 0, OGClubClubs.NotClubOwner.selector);

        // Pieces carry their original placement data.
        OGClubClubs.Piece[] memory pieces = clubs.piecesOf(1);
        assertEq(pieces.length, 2);
        assertEq(pieces[0].x, 2);
        assertEq(pieces[1].x, 3);
    }

    function test_FurnitureOperatorOfAStrangerCannotPlaceIntoOperatorsOwnClub() public {
        // Bob lets Alice move his furniture; Alice owns club 1. The furniture comes from Bob, who has no club right.
        vm.prank(bob);
        furniture.setApprovalForAll(alice, true);
        vm.prank(alice);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        furniture.safeTransferFrom(bob, address(clubs), 1, 1, abi.encode(uint256(1), uint8(2), uint8(2), uint8(0)));
        assertEq(clubs.pieceCount(1), 0);
    }

    function test_ApprovalForOneClubDoesNotExtendToAnother() public {
        vm.prank(bob);
        assertEq(clubs.mintClub(2), 2);
        vm.prank(bob);
        clubs.approve(carol, 2);
        _stock(carol, 1, 5);
        _place(carol, 2, 1, 2, 2, 0);
        _expectPlaceRevert(carol, 1, 1, 2, 2, 0, OGClubClubs.NotClubOwner.selector);
        // Bob owns club 2 but not club 1.
        _expectPlaceRevert(bob, 1, 1, 2, 2, 0, OGClubClubs.NotClubOwner.selector);
        // Contract owner has no placement right either.
        _stock(admin, 1, 1);
        _expectPlaceRevert(admin, 1, 1, 2, 2, 0, OGClubClubs.NotClubOwner.selector);
    }

    function test_TransferredClubKeepsLayoutAndMovesPlacementRight() public {
        _place(alice, 1, 4, 5, 5, 1);
        _place(alice, 1, 2, 2, 0, 1);
        bytes memory before = abi.encode(clubs.piecesOf(1));
        vm.prank(alice);
        clubs.approve(carol, 1);
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        assertEq(abi.encode(clubs.piecesOf(1)), before, "layout changed on transfer");
        assertEq(furniture.balanceOf(address(clubs), 4), 1);
        assertEq(furniture.balanceOf(address(clubs), 2), 1);
        _expectPlaceRevert(alice, 1, 1, 0, 0, 0, OGClubClubs.NotClubOwner.selector);
        _stock(carol, 1, 1);
        _expectPlaceRevert(carol, 1, 1, 0, 0, 0, OGClubClubs.NotClubOwner.selector); // token approval cleared
        _place(bob, 1, 1, 0, 0, 0);
        assertEq(clubs.pieceCount(1), 3);
    }

    // ------------------------------------------------------------------ footprints

    function test_FootprintCanBeRevisedUntilFirstPlacementOnly() public {
        vm.prank(admin);
        clubs.setFootprint(5, 1, 3, false);
        (uint8 w, uint8 h, bool set, bool locked,) = clubs.footprintOf(5);
        assertEq(w, 1);
        assertEq(h, 3);
        assertTrue(set);
        assertFalse(locked);

        // A rejected placement does not lock.
        _expectPlaceRevert(alice, 1, 5, 0, 8, 0, OGClubClubs.OutOfRoom.selector);
        vm.prank(admin);
        clubs.setFootprint(5, 4, 1, false);

        // Placing in any club locks globally.
        vm.prank(bob);
        clubs.mintClub(2);
        _place(bob, 2, 5, 0, 0, 0);
        vm.prank(admin);
        vm.expectRevert(OGClubClubs.FootprintLocked.selector);
        clubs.setFootprint(5, 1, 1, false);
        (w, h,, locked,) = clubs.footprintOf(5);
        assertEq(w, 4);
        assertEq(h, 1);
        assertTrue(locked);
        // Other ids unaffected.
        vm.prank(admin);
        clubs.setFootprint(3, 1, 1, false);
    }

    function test_FootprintBoundsAndOwnerOnly() public {
        vm.startPrank(admin);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(9, 0, 1, false);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(9, 1, 0, false);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(9, 5, 1, false);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(9, 1, 255, false);
        clubs.setFootprint(9, 4, 4, false);
        clubs.setFootprint(type(uint256).max, 1, 1, false);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        clubs.setFootprint(9, 1, 1, false);
    }

    // ------------------------------------------------------------------ custody

    function test_NobodyCanMoveFurnitureOutOfTheContract() public {
        _place(alice, 1, 3, 5, 5, 0);
        assertFalse(furniture.isApprovedForAll(address(clubs), alice));
        assertFalse(furniture.isApprovedForAll(address(clubs), admin));
        address[3] memory callers = [alice, admin, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, callers[i], address(clubs))
            );
            furniture.safeTransferFrom(address(clubs), callers[i], 3, 1, "");
        }
        assertEq(furniture.balanceOf(address(clubs), 3), 1);
        // No receive / fallback.
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(clubs).call{value: 1}("");
        assertFalse(ok);
    }

    function test_FullRoomRejectsEverythingElse() public {
        for (uint8 y; y < 10; ++y) {
            for (uint8 x; x < 10; ++x) {
                if (y == 4 && x <= 1) continue;
                uint256 item = 100 + uint256(y) * 10 + x;
                vm.prank(admin);
                clubs.setFootprint(item, 1, 1, false);
                _stock(alice, item, 1);
                _place(alice, 1, item, x, y, 0);
            }
        }
        assertEq(clubs.pieceCount(1), 98);
        _expectPlaceRevert(alice, 1, 1, 0, 0, 0, OGClubClubs.TileTaken.selector);
        _expectPlaceRevert(alice, 1, 1, 0, 4, 0, OGClubClubs.BlocksDoor.selector);
    }

    // ------------------------------------------------------------------ minting

    function test_ReentrantReceiverPlacesButCannotMintTwice() public {
        PlacingReentrantReceiver receiver = new PlacingReentrantReceiver(clubs, furniture);
        token.mint(address(receiver), 5 * PRICE);
        pepes.mint(address(receiver), 4);
        pepes.mint(address(receiver), 5);
        _stock(address(receiver), 1, 1);
        uint256 supplyBefore = clubs.totalSupply();
        uint256 id = receiver.go();
        assertEq(id, 4);
        assertEq(clubs.totalSupply(), supplyBefore + 1);
        assertTrue(receiver.placedInCallback());
        assertFalse(receiver.mintAgainSucceeded());
        assertFalse(receiver.mintToAgainSucceeded());
        assertEq(
            receiver.mintAgainError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(clubs.pieceCount(4), 1);
        assertEq(token.balanceOf(address(receiver)), 4 * PRICE);
        assertEq(token.balanceOf(address(clubs)), 0);
    }

    function test_ContractHolderThatCannotReceiveReverts() public {
        // Pepe transfers can reach a wallet without ERC721 receiving support; a club safe mint cannot.
        vm.prank(bob);
        pepes.transferFrom(bob, address(furniture), 2);
        token.mint(address(furniture), PRICE);
        vm.startPrank(address(furniture));
        token.approve(address(clubs), PRICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(furniture)));
        clubs.mintClub(2);
        vm.stopPrank();
        assertEq(token.balanceOf(address(furniture)), PRICE);
        assertFalse(clubs.clubsMinted(2));
        assertEq(clubs.totalSupply(), 1);
        vm.prank(address(furniture));
        pepes.transferFrom(address(furniture), bob, 2);
        vm.prank(bob);
        assertEq(clubs.mintClub(2), 2);
    }

    function test_MintPaysFromCallerAndClosingSaleStopsMinting() public {
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        uint256 id = clubs.mintClub(2);
        assertEq(clubs.ownerOf(id), bob);
        assertEq(token.balanceOf(bob), bobBefore - PRICE);
        vm.prank(admin);
        clubs.setSaleOpen(false);
        vm.prank(bob);
        vm.expectRevert(OGClubClubs.SaleClosed.selector);
        clubs.mintClub(3);
        vm.prank(admin);
        clubs.setSaleOpen(true);
        vm.prank(bob);
        assertEq(clubs.mintClub(3), 3);
    }

    function test_ExactlyPriceAllowanceAndBalanceSucceedOneWeiShortFails() public {
        pepes.mint(carol, 4);
        pepes.mint(carol, 5);
        token.mint(carol, PRICE);
        vm.prank(carol);
        token.approve(address(clubs), PRICE - 1);
        vm.prank(carol);
        vm.expectRevert();
        clubs.mintClub(4);
        vm.prank(carol);
        token.approve(address(clubs), PRICE);
        vm.prank(carol);
        clubs.mintClub(4);
        assertEq(token.balanceOf(carol), 0);
        assertEq(token.allowance(carol, address(clubs)), 0);
        vm.prank(carol);
        token.approve(address(clubs), PRICE);
        vm.prank(carol);
        vm.expectRevert();
        clubs.mintClub(5);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_SplitForAnyPrice(uint256 price, uint8 mints) public {
        price = bound(price, 1, type(uint128).max);
        uint256 n = bound(mints, 1, 8);
        OGClubClubs c = new OGClubClubs(
            token,
            address(vault),
            price,
            IERC1155(address(furniture)),
            admin,
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        vm.prank(admin);
        c.setSaleOpen(true);
        address payer = makeAddr("fuzz payer");
        token.mint(payer, price * n);
        vm.prank(payer);
        token.approve(address(c), type(uint256).max);
        uint256 burnBefore = token.balanceOf(c.BURN_ADDRESS());
        uint256 vaultBefore = token.balanceOf(address(vault));
        for (uint256 i; i < n; ++i) {
            pepes.mint(payer, i + 100);
            vm.prank(payer);
            assertEq(c.mintClub(i + 100), i + 100);
        }
        uint256 burned = token.balanceOf(c.BURN_ADDRESS()) - burnBefore;
        uint256 toVault = token.balanceOf(address(vault)) - vaultBefore;
        assertEq(burned + toVault, price * n);
        assertEq(burned, (price / 2) * n, "burn rounds down");
        assertGe(toVault, burned);
        assertLe(toVault - burned, n);
        assertEq(token.balanceOf(address(c)), 0);
        assertEq(token.balanceOf(payer), 0);
        assertEq(c.totalSupply(), n);
    }

    // ------------------------------------------------------------------ admin

    function test_MetadataAndRoyaltyEdges() public {
        assertEq(clubs.tokenURI(1), "1.json");
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.tokenURI(0);
        vm.startPrank(admin);
        clubs.setBaseURI("ipfs://x/");
        assertEq(clubs.tokenURI(1), "ipfs://x/1.json");
        clubs.freezeMetadata();
        vm.expectRevert(OGClubClubs.MetadataFrozen.selector);
        clubs.setBaseURI("ipfs://y/");
        vm.expectRevert(OGClubClubs.MetadataFrozen.selector);
        clubs.freezeMetadata();

        (address r, uint256 amount) = clubs.royaltyInfo(1, 10_000);
        assertEq(r, royalty);
        assertEq(amount, 500);
        clubs.setRoyalty(carol, 1000);
        (r, amount) = clubs.royaltyInfo(1, 10_000);
        assertEq(r, carol);
        assertEq(amount, 1000);
        vm.expectRevert(OGClubClubs.RoyaltyTooHigh.selector);
        clubs.setRoyalty(carol, 1001);
        vm.expectRevert(OGClubClubs.ZeroAddress.selector);
        clubs.setRoyalty(address(0), 100);
        clubs.setRoyalty(carol, 0);
        (, amount) = clubs.royaltyInfo(1, 10_000);
        assertEq(amount, 0);
        vm.stopPrank();
        assertEq(clubs.tokenURI(1), "ipfs://x/1.json");
    }

    function test_PendingOwnerHasNoPowerUntilAcceptAndOldOwnerLosesIt() public {
        vm.prank(admin);
        clubs.transferOwnership(carol);
        assertEq(clubs.owner(), admin);
        assertEq(clubs.pendingOwner(), carol);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, carol));
        clubs.setSaleOpen(false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        clubs.acceptOwnership();
        vm.prank(carol);
        clubs.acceptOwnership();
        assertEq(clubs.owner(), carol);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        clubs.setSaleOpen(false);
        vm.prank(carol);
        clubs.setSaleOpen(false);
        assertFalse(clubs.saleOpen());
    }

    function test_RenouncedOwnershipKeepsPlacementWorking() public {
        vm.prank(admin);
        clubs.renounceOwnership();
        assertEq(clubs.owner(), address(0));
        _place(alice, 1, 1, 3, 3, 0);
        assertEq(clubs.pieceCount(1), 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, admin));
        clubs.setFootprint(6, 1, 1, false);
    }

    function test_InterfacesAndImmutables() public view {
        assertTrue(clubs.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(clubs.supportsInterface(0x780e9d63)); // ERC721Enumerable
        assertTrue(clubs.supportsInterface(0x5b5e139f)); // ERC721Metadata
        assertTrue(clubs.supportsInterface(0x2a55205a)); // ERC2981
        assertTrue(clubs.supportsInterface(0x49064906)); // ERC4906
        assertTrue(clubs.supportsInterface(0x4e2312e0)); // ERC1155Receiver
        assertTrue(clubs.supportsInterface(0x01ffc9a7)); // ERC165
        assertFalse(clubs.supportsInterface(0xffffffff));
        assertEq(clubs.name(), "OG Club Clubs");
        assertEq(clubs.symbol(), "OGCLUBS");
        assertEq(address(clubs.token()), address(token));
        assertEq(clubs.vault(), address(vault));
        assertEq(clubs.price(), PRICE);
        assertEq(address(clubs.furniture()), address(furniture));
        assertEq(clubs.BURN_ADDRESS(), 0x000000000000000000000000000000000000dEaD);
    }
}
