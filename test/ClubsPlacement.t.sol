// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract OtherFurniture is ERC1155 {
    constructor(address holder) ERC1155("") {
        _mint(holder, 1, 1, "");
    }
}

contract ClubsPlacementTest is ClubsTestBase {
    event FurniturePlaced(
        uint256 indexed clubId, uint256 indexed furnitureId, uint8 x, uint8 y, uint8 rot, uint256 index, bool wall
    );
    event MetadataUpdate(uint256 tokenId);

    function test_RealFurnitureAllRotationsViewsAndEvents() public {
        _placeAndCheck(1, 0, 0, 0, 0);
        for (uint8 rot; rot < 4; ++rot) {
            uint8 x = 2 * rot;
            clubs.setFootprint(10 + rot, 2, 1, false);
            stock(alice, 10 + rot, 1);
            _placeAndCheck(10 + rot, x, 6, rot, rot + 1);
            assertTrue(clubs.tileTaken(1, x, 6));
            assertEq(clubs.tileTaken(1, x + 1, 6), rot % 2 == 0);
            assertEq(clubs.tileTaken(1, x, 7), rot % 2 == 1);
        }
        _placeAndCheck(3, 8, 8, 3, 5);
        for (uint8 x = 8; x < 10; ++x) {
            for (uint8 y = 8; y < 10; ++y) {
                assertTrue(clubs.tileTaken(1, x, y));
            }
        }
        assertEq(clubs.pieceCount(1), 6);
        assertEq(furniture.balanceOf(address(clubs), 1), 1);
        for (uint256 i = 10; i < 14; ++i) {
            assertEq(furniture.balanceOf(address(clubs), i), 1);
        }
        assertEq(furniture.balanceOf(address(clubs), 3), 1);
    }

    function test_ClubTokenApprovalAndApprovalForAllPermitOwnersOfFurnitureToPlace() public {
        stock(operator, 1, 4);
        stock(operator, 2, 4);
        vm.prank(alice);
        clubs.approve(operator, 1);
        place(operator, 1, 1, 0, 0, 0);
        vm.prank(alice);
        clubs.approve(address(0), 1);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        place(operator, 1, 1, 1, 0, 0);
        vm.prank(alice);
        clubs.setApprovalForAll(operator, true);
        place(operator, 1, 2, 1, 0, 0);
        vm.prank(alice);
        clubs.setApprovalForAll(operator, false);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        place(operator, 1, 1, 2, 0, 0);
        assertEq(clubs.pieceCount(1), 2);
    }

    function test_FurnitureOperatorCanPlaceFromClubHolder() public {
        vm.prank(alice);
        furniture.setApprovalForAll(operator, true);
        vm.prank(operator);
        furniture.safeTransferFrom(alice, address(clubs), 1, 1, abi.encode(uint256(1), uint8(0), uint8(0), uint8(0)));
        assertEq(clubs.pieceCount(1), 1);
        assertFalse(clubs.isApprovedForAll(alice, operator));
        // Club approval does not replace the ERC1155 sender's own approval.
        vm.prank(alice);
        clubs.approve(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, bob, alice));
        vm.prank(bob);
        furniture.safeTransferFrom(alice, address(clubs), 1, 1, abi.encode(uint256(1), uint8(1), uint8(0), uint8(0)));
    }

    function test_StrangerCannotPlaceOwnFurnitureEvenIfCallerOwnsClub() public {
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        place(bob, 1, 1, 0, 0, 0);
        // The rule authenticates `from`, not merely the ERC1155 operator.
        vm.prank(bob);
        furniture.setApprovalForAll(alice, true);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        vm.prank(alice);
        furniture.safeTransferFrom(bob, address(clubs), 1, 1, abi.encode(uint256(1), uint8(0), uint8(0), uint8(0)));
        assertEq(furniture.balanceOf(bob, 1), 200);
        assertEq(clubs.pieceCount(1), 0);
    }

    function test_TransferCarriesLayoutAndRevokesOldHolderAndTokenApproval() public {
        place(alice, 1, 2, 2, 2, 1);
        bytes32 layout = keccak256(abi.encode(clubs.piecesOf(1)));
        vm.prank(alice);
        clubs.approve(operator, 1);
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        assertEq(keccak256(abi.encode(clubs.piecesOf(1))), layout);
        assertTrue(clubs.tileTaken(1, 2, 2));
        assertTrue(clubs.tileTaken(1, 2, 3));
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        place(alice, 1, 1, 0, 0, 0);
        stock(operator, 1, 1);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        place(operator, 1, 1, 0, 0, 0);
        place(bob, 1, 1, 0, 0, 0);
        OGClubClubs.Piece[] memory pieces = clubs.piecesOf(1);
        assertEq(pieces.length, 2);
        assertEq(pieces[0].furnitureId, 2);
        assertEq(pieces[0].rot, 1);
        assertEq(pieces[1].furnitureId, 1);
    }

    function test_DirectAndFakeERC1155HooksRejected() public {
        bytes memory data = abi.encode(uint256(1), uint8(0), uint8(0), uint8(0));
        vm.expectRevert(OGClubClubs.NotFurniture.selector);
        clubs.onERC1155Received(alice, alice, 1, 1, data);
        OtherFurniture fake = new OtherFurniture(alice);
        vm.expectRevert(OGClubClubs.NotFurniture.selector);
        vm.prank(alice);
        fake.safeTransferFrom(alice, address(clubs), 1, 1, data);
        assertEq(fake.balanceOf(alice, 1), 1);
        assertEq(clubs.pieceCount(1), 0);
    }

    function test_BadAmountsAndBatchTransfersRejected() public {
        bytes memory data = abi.encode(uint256(1), uint8(0), uint8(0), uint8(0));
        for (uint256 amount; amount <= 2; amount += 2) {
            vm.expectRevert(OGClubClubs.BadAmount.selector);
            vm.prank(alice);
            furniture.safeTransferFrom(alice, address(clubs), 1, amount, data);
        }
        for (uint256 length; length <= 2; length += 2) {
            uint256[] memory ids = new uint256[](length);
            uint256[] memory amounts = new uint256[](length);
            for (uint256 i; i < length; ++i) {
                ids[i] = 1;
                amounts[i] = 1;
            }
            vm.expectRevert(OGClubClubs.BatchNotAccepted.selector);
            vm.prank(alice);
            furniture.safeBatchTransferFrom(alice, address(clubs), ids, amounts, data);
        }
        vm.expectRevert(OGClubClubs.BatchNotAccepted.selector);
        clubs.onERC1155BatchReceived(alice, alice, new uint256[](1), new uint256[](1), data);
        assertEq(furniture.balanceOf(alice, 1), 200);
        assertEq(furniture.balanceOf(address(clubs), 1), 0);
        assertEq(clubs.pieceCount(1), 0);
    }

    function test_VendoredFurnitureSingletonBatchUsesSingleHookAndRecordsOnePiece() public {
        // OZ 5.0.2 routes a one-element batch through onERC1155Received. The receiver cannot
        // distinguish that from safeTransferFrom, but it still validates and records exactly one piece.
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = amounts[0] = 1;
        vm.prank(alice);
        furniture.safeBatchTransferFrom(
            alice, address(clubs), ids, amounts, abi.encode(uint256(1), uint8(0), uint8(0), uint8(0))
        );
        assertEq(clubs.pieceCount(1), 1);
        assertEq(furniture.balanceOf(address(clubs), 1), 1);
    }

    function test_NoFootprintBadFootprintsAndPerIdPermanentLock() public {
        stock(alice, 5, 2);
        vm.expectRevert(OGClubClubs.NoFootprint.selector);
        place(alice, 1, 5, 0, 0, 0);
        (uint8 w, uint8 h, bool set, bool locked,) = clubs.footprintOf(5);
        assertEq(w, 0);
        assertEq(h, 0);
        assertFalse(set);
        assertFalse(locked);
        uint8[4] memory bad = [uint8(0), 5, 100, 255];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(OGClubClubs.BadFootprint.selector);
            clubs.setFootprint(5, bad[i], 1, false);
            vm.expectRevert(OGClubClubs.BadFootprint.selector);
            clubs.setFootprint(5, 1, bad[i], false);
        }
        clubs.setFootprint(5, 4, 4, false);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 5, 9, 9, 0);
        clubs.setFootprint(5, 2, 1, false); // Failed placement did not lock the dimensions.
        place(alice, 1, 5, 2, 0, 0);
        (w, h, set, locked,) = clubs.footprintOf(5);
        assertEq(w, 2);
        assertEq(h, 1);
        assertTrue(set);
        assertTrue(locked);
        vm.expectRevert(OGClubClubs.FootprintLocked.selector);
        clubs.setFootprint(5, 2, 1, false); // Even an identical reset is forbidden.
        clubs.setFootprint(1, 3, 2, false); // Other IDs remain editable.
        vm.prank(bob);
        clubs.mintClub(2);
        stock(bob, 5, 1);
        place(bob, 2, 5, 2, 0, 0); // Same locked dimensions apply in every club.
        assertTrue(clubs.tileTaken(2, 3, 0));
    }

    function test_OffGridRotationDoorAndOverlapRevertWithoutChangingAnything() public {
        _reject(2, 9, 0, 0, OGClubClubs.OutOfRoom.selector);
        _reject(2, 0, 9, 1, OGClubClubs.OutOfRoom.selector);
        _reject(2, 9, 0, 2, OGClubClubs.OutOfRoom.selector);
        _reject(2, 0, 9, 3, OGClubClubs.OutOfRoom.selector);
        _reject(1, 10, 0, 0, OGClubClubs.OutOfRoom.selector);
        _reject(1, 0, 255, 0, OGClubClubs.OutOfRoom.selector);
        _reject(1, 0, 0, 4, OGClubClubs.OutOfRoom.selector);
        _reject(1, 0, 0, 255, OGClubClubs.OutOfRoom.selector);
        _reject(1, 0, 4, 0, OGClubClubs.BlocksDoor.selector);
        _reject(1, 1, 4, 0, OGClubClubs.BlocksDoor.selector);
        _reject(3, 0, 3, 0, OGClubClubs.BlocksDoor.selector);
        _reject(2, 1, 3, 1, OGClubClubs.BlocksDoor.selector);
        place(alice, 1, 3, 2, 2, 0);
        _reject(1, 3, 3, 0, OGClubClubs.TileTaken.selector);
        _reject(2, 1, 2, 0, OGClubClubs.TileTaken.selector);
        assertEq(clubs.pieceCount(1), 1);
    }

    function test_MissingClubAndMalformedDataCannotLockFurniture() public {
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        place(alice, 0, 1, 0, 0, 0);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        place(alice, 2, 1, 0, 0, 0);
        bytes[] memory malformed = new bytes[](6);
        malformed[0] = "";
        malformed[1] = abi.encode(uint256(1));
        malformed[2] = new bytes(127);
        malformed[3] = new bytes(129);
        malformed[4] = abi.encode(uint256(1), uint256(256), uint8(0), uint8(0));
        malformed[5] = abi.encode(uint256(1), uint8(0), uint8(0), uint256(256));
        for (uint256 i; i < malformed.length; ++i) {
            vm.expectRevert(OGClubClubs.BadPlacementData.selector);
            vm.prank(alice);
            furniture.safeTransferFrom(alice, address(clubs), 1, 1, malformed[i]);
            assertEq(furniture.balanceOf(alice, 1), 200);
            assertEq(furniture.balanceOf(address(clubs), 1), 0);
            assertEq(clubs.pieceCount(1), 0);
        }
    }

    function test_LevelOneAll98UsableTilesFillWithDistinctDesigns() public {
        for (uint8 y; y < 10; ++y) {
            for (uint8 x; x < 10; ++x) {
                if (y == 4 && x < 2) continue;
                uint256 item = 100 + uint256(y) * 10 + x;
                clubs.setFootprint(item, 1, 1, false);
                stock(alice, item, 1);
                place(alice, 1, item, x, y, 0);
                assertTrue(clubs.hasDesign(1, item));
                assertEq(furniture.balanceOf(address(clubs), item), 1);
            }
        }
        assertEq(clubs.pieceCount(1), 98);
        _reject(1, 0, 0, 0, OGClubClubs.TileTaken.selector);
        _reject(1, 0, 4, 0, OGClubClubs.BlocksDoor.selector);
    }

    function test_FurnitureCannotLeaveForClubHolderOperatorOrContractOwner() public {
        place(alice, 1, 1, 0, 0, 0);
        address[3] memory attackers = [alice, operator, address(this)];
        for (uint256 i; i < attackers.length; ++i) {
            vm.startPrank(attackers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC1155Errors.ERC1155MissingApprovalForAll.selector, attackers[i], address(clubs)
                )
            );
            furniture.safeTransferFrom(address(clubs), bob, 1, 1, "");
            bytes[] memory calls = new bytes[](5);
            calls[0] = abi.encodeWithSignature("removeFurniture(uint256,uint256)", 1, 0);
            calls[1] = abi.encodeWithSignature("withdrawFurniture(uint256,uint256,address)", 1, 0, bob);
            calls[2] = abi.encodeWithSignature("setApprovalForAll(address,bool)", operator, true);
            calls[3] = abi.encodeWithSignature("burn(uint256)", 1);
            calls[4] = abi.encodeWithSignature("moveFurniture(uint256,uint256,uint8,uint8,uint8)", 1, 0, 2, 2, 0);
            for (uint256 j; j < calls.length; ++j) {
                (bool ok,) = address(clubs).call(calls[j]);
                // ERC721 approval succeeds but never approves custody of ERC1155 furniture.
                if (j != 2) assertFalse(ok);
            }
            vm.stopPrank();
            assertFalse(furniture.isApprovedForAll(address(clubs), attackers[i]));
        }
        assertEq(furniture.balanceOf(address(clubs), 1), 1);
        assertEq(clubs.pieceCount(1), 1);
    }

    function _placeAndCheck(uint256 item, uint8 x, uint8 y, uint8 rot, uint256 index) private {
        vm.expectEmit(true, true, false, true, address(clubs));
        emit FurniturePlaced(1, item, x, y, rot, index, false);
        vm.expectEmit(false, false, false, true, address(clubs));
        emit MetadataUpdate(1);
        place(alice, 1, item, x, y, rot);
        OGClubClubs.Piece memory piece = clubs.piecesOf(1)[index];
        assertEq(piece.furnitureId, item);
        assertEq(piece.x, x);
        assertEq(piece.y, y);
        assertEq(piece.rot, rot);
    }

    function _reject(uint256 item, uint8 x, uint8 y, uint8 rot, bytes4 error_) private {
        bytes32 beforeLayout = keccak256(abi.encode(clubs.piecesOf(1)));
        uint256 beforeHeld = furniture.balanceOf(address(clubs), item);
        uint256 beforeOwned = furniture.balanceOf(alice, item);
        bytes32 beforeFootprint = _footprintState(item);
        vm.expectRevert(error_);
        place(alice, 1, item, x, y, rot);
        assertEq(keccak256(abi.encode(clubs.piecesOf(1))), beforeLayout);
        assertEq(furniture.balanceOf(address(clubs), item), beforeHeld);
        assertEq(furniture.balanceOf(alice, item), beforeOwned);
        assertEq(_footprintState(item), beforeFootprint);
    }

    function _footprintState(uint256 item) private view returns (bytes32) {
        (uint8 w, uint8 h, bool set, bool locked,) = clubs.footprintOf(item);
        return keccak256(abi.encode(w, h, set, locked));
    }
}
