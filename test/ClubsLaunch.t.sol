// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {MockDelegateRegistry} from "./helpers/ClubLaunchMocks.sol";
import {ClubReceiptToken} from "./OGClubClubs.t.sol";
import {TestToken, NoReturnToken} from "./helpers/TokenMocks.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Vm} from "forge-std/Vm.sol";

contract ClubFlipper is IERC721Receiver {
    OGClubClubs immutable clubs;
    address immutable recipient;

    constructor(OGClubClubs clubs_, address recipient_) {
        clubs = clubs_;
        recipient = recipient_;
    }

    function buy(uint256 pepeId) external {
        clubs.token().approve(address(clubs), clubs.price());
        clubs.mintClub(pepeId);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender == address(clubs)) clubs.transferFrom(address(this), recipient, id);
        return this.onERC721Received.selector;
    }
}

contract ClubsPepeTest is ClubsTestBase {
    function test_OneClubPerPepeEverEvenAfterPepeAndClubTransfers() public {
        assertTrue(clubs.clubsMinted(1));
        assertFalse(clubs.clubsMinted(2));
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        vm.prank(alice);
        clubs.mintClub(1);
        vm.prank(alice);
        pepes.transferFrom(alice, bob, 1);
        vm.expectRevert(OGClubClubs.AlreadyMinted.selector);
        vm.prank(bob);
        clubs.mintClub(1);
        assertEq(clubs.ownerOf(1), bob);
        assertEq(clubs.totalSupply(), 1);
    }

    function test_IdZeroAndMaxAreValidPepeIdsNoSequentialAllocation() public {
        pepes.mint(alice, 0);
        pepes.mint(alice, type(uint256).max);
        vm.startPrank(alice);
        assertEq(clubs.mintClub(type(uint256).max), type(uint256).max);
        assertEq(clubs.mintClub(0), 0);
        vm.stopPrank();
        assertEq(clubs.tokenByIndex(1), type(uint256).max);
        assertEq(clubs.tokenByIndex(2), 0);
        assertEq(clubs.levelOf(0), 1);
        assertTrue(clubs.clubsMinted(type(uint256).max));
    }

    function test_NonexistentPepeAndNonHolderRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        vm.prank(alice);
        clubs.mintClub(999);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(bob);
        clubs.mintClub(3);
        vm.prank(alice);
        pepes.approve(bob, 3); // ERC721 transfer approval alone is not delegate.xyz authorization.
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(bob);
        clubs.mintClub(3);
        assertFalse(clubs.clubsMinted(3));
    }

    function test_DelegatedWalletPaysAndReceivesAndRevocationAndTransferInvalidateDelegation() public {
        MockDelegateRegistry registry = new MockDelegateRegistry();
        OGClubClubs target = new OGClubClubs(
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
        target.setSaleOpen(true);
        vm.prank(bob);
        token.approve(address(target), 10 * PRICE);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(bob);
        target.mintClub(1);
        vm.startPrank(alice);
        registry.delegateERC721(bob, address(pepes), 1, bytes32(uint256(1)), true);
        registry.delegateERC721(bob, address(furniture), 1, bytes32(0), true);
        vm.stopPrank();
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(bob);
        target.mintClub(1);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 1, bytes32(0), true);
        uint256 holderBefore = token.balanceOf(alice);
        uint256 hotBefore = token.balanceOf(bob);
        vm.prank(bob);
        assertEq(target.mintClub(1), 1);
        assertEq(target.ownerOf(1), bob);
        assertEq(token.balanceOf(bob), hotBefore - PRICE);
        assertEq(token.balanceOf(alice), holderBefore);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(bob); // No token-ID spillover.
        target.mintClub(3);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 3, bytes32(0), true);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 3, bytes32(0), false);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(bob);
        target.mintClub(3);
        vm.prank(alice);
        registry.delegateERC721(bob, address(pepes), 3, bytes32(0), true);
        vm.prank(alice);
        pepes.transferFrom(alice, operator, 3);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(bob);
        target.mintClub(3);
    }

    function test_ZeroRegistryDisablesDelegationButHolderWorks() public {
        assertEq(address(clubs.delegates()), address(0));
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(operator);
        clubs.mintClub(3);
        vm.prank(alice);
        clubs.mintClub(3);
        assertEq(clubs.ownerOf(3), alice);
    }

    function test_AuditMintEventPrecedesReceiverTransfer() public {
        ClubFlipper flipper = new ClubFlipper(clubs, bob);
        pepes.mint(address(flipper), 900);
        token.mint(address(flipper), PRICE);
        vm.recordLogs();
        flipper.buy(900);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 mintIndex = type(uint256).max;
        uint256 onwardIndex;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(clubs)) continue;
            if (logs[i].topics[0] == keccak256("ClubMinted(uint256,address,address,uint256,uint256,uint256)")) {
                mintIndex = i;
                (uint256 burned, uint256 toVault, uint256 pepeId) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(burned + toVault, PRICE);
                assertEq(pepeId, 900);
            }
            if (
                logs[i].topics[0] == keccak256("Transfer(address,address,uint256)")
                    && logs[i].topics[1] == bytes32(uint256(uint160(address(flipper))))
            ) onwardIndex = i;
        }
        assertLt(mintIndex, onwardIndex);
        assertEq(clubs.ownerOf(900), bob);
    }

    function test_NewConstructorRejections() public {
        address[3] memory badVaults = [clubs.BURN_ADDRESS(), address(token), address(furniture)];
        for (uint256 i; i < badVaults.length; ++i) {
            vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
            new OGClubClubs(
                token,
                badVaults[i],
                PRICE,
                IERC1155(address(furniture)),
                address(this),
                royalty,
                pepes,
                delegates,
                _upgradePrices()[0],
                _upgradePrices()[1],
                _upgradePrices()[2]
            );
        }
        vm.expectRevert(OGClubClubs.ZeroAddress.selector);
        new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            IERC721(address(0)),
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        for (uint256 i; i < 3; ++i) {
            uint256[3] memory prices = _upgradePrices();
            prices[i] = 0;
            vm.expectRevert(OGClubClubs.ZeroPrice.selector);
            new OGClubClubs(
                token,
                address(vault),
                PRICE,
                IERC1155(address(furniture)),
                address(this),
                royalty,
                pepes,
                delegates,
                prices[0],
                prices[1],
                prices[2]
            );
        }
    }
}

contract ClubsLevelsTest is ClubsTestBase {
    event ClubUpgraded(uint256 indexed clubId, uint8 newLevel, address indexed payer, uint256 burned, uint256 toVault);
    event MetadataUpdate(uint256 tokenId);

    function test_UpgradesExactOddSplitsEventsAndPricesToMax() public {
        assertEq(clubs.levelOf(1), 1);
        uint256[3] memory prices = _upgradePrices();
        for (uint8 level = 1; level < 4; ++level) {
            uint256 cost = prices[level - 1];
            assertEq(clubs.upgradePrice(level), cost);
            uint256 beforePayer = token.balanceOf(alice);
            uint256 beforeBurn = token.balanceOf(clubs.BURN_ADDRESS());
            uint256 beforeVault = token.balanceOf(address(vault));
            vm.expectEmit(true, true, false, true, address(clubs));
            emit ClubUpgraded(1, level + 1, alice, cost / 2, cost - cost / 2);
            vm.expectEmit(false, false, false, true, address(clubs));
            emit MetadataUpdate(1);
            vm.prank(alice);
            clubs.upgradeClub(1);
            assertEq(clubs.levelOf(1), level + 1);
            assertEq(beforePayer - token.balanceOf(alice), cost);
            assertEq(token.balanceOf(clubs.BURN_ADDRESS()) - beforeBurn, cost / 2);
            assertEq(token.balanceOf(address(vault)) - beforeVault, cost - cost / 2);
            assertEq(token.balanceOf(address(clubs)), 0);
        }
        assertEq(clubs.upgradePrice(4), 0);
        vm.expectRevert(OGClubClubs.MaxLevel.selector);
        vm.prank(alice);
        clubs.upgradeClub(1);
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.upgradePrice(0);
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.upgradePrice(5);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.levelOf(99);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.upgradeClub(99);
    }

    function test_OnlyClubHolderTokenApprovedOrOperatorCanUpgradeAndCallerPays() public {
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        vm.prank(bob);
        clubs.upgradeClub(1);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        clubs.upgradeClub(1); // Contract owner is not a club operator.
        clubs.setSaleOpen(false); // Upgrades and placements remain available.
        vm.prank(alice);
        clubs.approve(bob, 1);
        uint256 beforeAlice = token.balanceOf(alice);
        vm.prank(bob);
        clubs.upgradeClub(1);
        assertEq(token.balanceOf(alice), beforeAlice);
        vm.prank(alice);
        clubs.approve(address(0), 1);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        vm.prank(bob);
        clubs.upgradeClub(1);
        vm.prank(alice);
        clubs.setApprovalForAll(bob, true);
        vm.prank(bob);
        clubs.upgradeClub(1);
        vm.prank(alice);
        clubs.transferFrom(alice, operator, 1);
        vm.expectRevert(OGClubClubs.NotClubOwner.selector);
        vm.prank(bob);
        clubs.upgradeClub(1);
        fund(operator, 2_000_000e18);
        vm.prank(operator);
        clubs.upgradeClub(1);
        assertEq(clubs.levelOf(1), 4);
    }

    function test_FloorMasksExactlyMatchEveryCoordinateAndContainPreviousLevel() public {
        uint256 previous;
        for (uint256 level = 1; level <= 4; ++level) {
            uint256 expected;
            for (uint256 y; y < 16; ++y) {
                for (uint256 x; x < 16; ++x) {
                    bool inside = level == 1
                        ? x < 10 && y < 10
                        : level == 2 ? x < 14 && y < 10 : level == 3 ? (x < 14 && y < 10) || (x < 10 && y < 16) : true;
                    if (inside) expected |= uint256(1) << (16 * y + x);
                }
            }
            assertEq(clubs.floorMask(level), expected);
            assertEq(expected & previous, previous);
            previous = expected;
        }
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.floorMask(0);
        vm.expectRevert(OGClubClubs.BadLevel.selector);
        clubs.floorMask(5);
    }

    function test_ExpansionBoundariesEveryTileOfPieceAndOldTilesRemain() public {
        place(alice, 1, 1, 9, 9, 0);
        for (uint256 id = 10; id < 16; ++id) {
            clubs.setFootprint(id, 1, 1, false);
            stock(alice, id, 2);
        }
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 10, 0, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 11, 13, 9, 0);
        vm.prank(alice);
        clubs.upgradeClub(1);
        place(alice, 1, 10, 10, 0, 0);
        place(alice, 1, 11, 13, 9, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 12, 9, 15, 0);
        vm.prank(alice);
        clubs.upgradeClub(1);
        place(alice, 1, 12, 9, 15, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 13, 10, 10, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 14, 14, 0, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector); // Origin fits, rectangle crosses L notch.
        place(alice, 1, 3, 9, 9, 0);
        vm.prank(alice);
        clubs.upgradeClub(1);
        place(alice, 1, 13, 10, 10, 0);
        place(alice, 1, 14, 14, 0, 0);
        place(alice, 1, 15, 15, 15, 0);
        assertTrue(clubs.tileTaken(1, 9, 9));
        assertTrue(clubs.tileTaken(1, 13, 9));
        assertTrue(clubs.tileTaken(1, 9, 15));
        assertEq(clubs.pieceCount(1), 7);
        vm.expectRevert(OGClubClubs.TileTaken.selector);
        place(alice, 1, 2, 8, 9, 0);
    }

    function test_FloorDoorNeverOpensAtAnyLevel() public {
        for (uint8 level = 1; level <= 4; ++level) {
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 1, 0, 4, 0);
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 1, 1, 4, 0);
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 2, 1, 3, 1);
            assertFalse(clubs.tileTaken(1, 0, 4));
            assertFalse(clubs.tileTaken(1, 1, 4));
            if (level < 4) {
                vm.prank(alice);
                clubs.upgradeClub(1);
            }
        }
    }

    function test_UpgradeReceiptMutationsRevertEntirePaymentAndLevel() public {
        ClubReceiptToken adversary = new ClubReceiptToken();
        OGClubClubs target = new OGClubClubs(
            adversary,
            address(vault),
            101,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            uint256(101),
            203,
            405
        );
        target.setSaleOpen(true);
        adversary.mint(alice, 1000);
        adversary.mint(address(vault), 100);
        adversary.mint(target.BURN_ADDRESS(), 100);
        vm.startPrank(alice);
        adversary.approve(address(target), 1000);
        target.mintClub(1);
        vm.stopPrank();
        for (uint8 mode; mode < 4; ++mode) {
            adversary.configure(address(vault), mode);
            vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
            vm.prank(alice);
            target.upgradeClub(1);
            assertEq(target.levelOf(1), 1);
            assertEq(adversary.balanceOf(alice), 899);
            assertEq(adversary.balanceOf(address(vault)), 151);
            assertEq(adversary.balanceOf(target.BURN_ADDRESS()), 150);
            assertEq(adversary.allowance(alice, address(target)), 899);
            assertEq(adversary.balanceOf(address(target)), 0);
        }
    }

    function test_UpgradeShortAllowanceRollsBackBurnAndLevel() public {
        uint256 cost = clubs.upgradePrice(1);
        vm.prank(alice);
        token.approve(address(clubs), cost - 1);
        uint256 beforeBurn = token.balanceOf(clubs.BURN_ADDRESS());
        uint256 beforeVault = token.balanceOf(address(vault));
        vm.expectRevert();
        vm.prank(alice);
        clubs.upgradeClub(1);
        assertEq(clubs.levelOf(1), 1);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), beforeBurn);
        assertEq(token.balanceOf(address(vault)), beforeVault);
        assertEq(token.allowance(alice, address(clubs)), cost - 1);
    }

    function test_UpgradeReentrancyGuardAndTaxedTokenRejection() public {
        TestToken t = new TestToken(18);
        OGClubClubs target = new OGClubClubs(
            t,
            address(vault),
            10_001,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            uint256(20_001),
            40_003,
            80_007
        );
        target.setSaleOpen(true);
        t.mint(alice, 200_000);
        vm.startPrank(alice);
        t.approve(address(target), 200_000);
        target.mintClub(1);
        vm.stopPrank();
        for (uint256 mode; mode < 2; ++mode) {
            t.configureFee(100, mode == 1);
            vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
            vm.prank(alice);
            target.upgradeClub(1);
            assertEq(target.levelOf(1), 1);
            assertEq(t.balanceOf(alice), 189_999);
        }
        t.configureFee(0, false);
        t.configureCallback(address(target), abi.encodeCall(target.upgradeClub, (1)));
        vm.prank(alice);
        target.upgradeClub(1);
        assertFalse(t.callbackSucceeded());
        assertEq(target.levelOf(1), 2);
        t.configureCallback(address(target), abi.encodeCall(target.mintClub, (3)));
        vm.prank(alice);
        target.upgradeClub(1);
        assertFalse(t.callbackSucceeded());
        assertEq(target.levelOf(1), 3);
        assertFalse(target.clubsMinted(3));
    }

    function test_NoReturnTokenUpgradesAndZeroBurnPriceOne() public {
        NoReturnToken t = new NoReturnToken();
        OGClubClubs target = new OGClubClubs(
            IERC20(address(t)),
            address(vault),
            1,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            uint256(1),
            1,
            1
        );
        target.setSaleOpen(true);
        t.mint(alice, 4);
        vm.startPrank(alice);
        t.approve(address(target), 4);
        target.mintClub(1);
        target.upgradeClub(1);
        target.upgradeClub(1);
        target.upgradeClub(1);
        vm.stopPrank();
        assertEq(target.levelOf(1), 4);
        assertEq(t.balanceOf(alice), 0);
        assertEq(t.balanceOf(target.BURN_ADDRESS()), 0);
        assertEq(t.balanceOf(address(vault)), 4);
    }
}

contract ClubsWallsTest is ClubsTestBase {
    event FurniturePlaced(
        uint256 indexed clubId, uint256 indexed furnitureId, uint8 x, uint8 y, uint8 rot, uint256 index, bool wall
    );
    event FootprintSet(uint256 indexed furnitureId, uint8 w, uint8 h, bool wall);
    event MetadataUpdate(uint256 tokenId);

    function test_WallEventsAndMissingAndOutOfBoundsViews() public {
        vm.expectEmit(true, false, false, true, address(clubs));
        emit FootprintSet(10, 2, 1, true);
        _design(10, 2, true);
        vm.expectEmit(true, true, false, true, address(clubs));
        emit FurniturePlaced(1, 10, 5, 0, 1, 0, true);
        vm.expectEmit(false, false, false, true, address(clubs));
        emit MetadataUpdate(1);
        place(alice, 1, 10, 5, 0, 1);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.wallTaken(99, 0, 0);
        vm.expectRevert(OGClubClubs.NonexistentToken.selector);
        clubs.hasDesign(99, 10);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.wallTaken(1, 2, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.wallTaken(1, 0, 10);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.wallTaken(1, 1, 255);
    }

    function _design(uint256 id, uint8 w, bool wall) internal {
        clubs.setFootprint(id, w, 1, wall);
        stock(alice, id, 2);
    }

    function test_BothWallsAllWidthsDoorAndIndependentFloor() public {
        // Each width gets its own club, so widths 1..4 can be tested at identical coordinates.
        for (uint8 width = 1; width <= 4; ++width) {
            uint256 clubId = 100 + width;
            pepes.mint(alice, clubId);
            vm.prank(alice);
            clubs.mintClub(clubId);
            _design(100 + width, width, true);
            _design(200 + width, width, true);
            place(alice, clubId, 100 + width, 0, 0, 0);
            place(alice, clubId, 200 + width, 5, 0, 1);
            place(alice, clubId, 1, 0, 0, 0); // Floor (0,0) and wall side 0 position 0 are independent.
            for (uint8 pos; pos < width; ++pos) {
                assertTrue(clubs.wallTaken(clubId, 0, pos));
                assertTrue(clubs.wallTaken(clubId, 1, 5 + pos));
            }
            assertFalse(clubs.wallTaken(clubId, 1, 0));
            assertFalse(clubs.wallTaken(clubId, 1, 4));
            assertTrue(clubs.tileTaken(clubId, 0, 0));
            OGClubClubs.Piece[] memory pieces = clubs.piecesOf(clubId);
            assertTrue(pieces[0].wall);
            assertTrue(pieces[1].wall);
            assertFalse(pieces[2].wall);
        }
    }

    function test_WallDoorOverlapSideValidationAndFootprintFlagLock() public {
        _design(10, 2, true);
        _design(11, 1, true);
        _design(12, 1, true);
        vm.expectRevert(OGClubClubs.BlocksDoor.selector);
        place(alice, 1, 10, 3, 0, 1);
        vm.expectRevert(OGClubClubs.BlocksDoor.selector);
        place(alice, 1, 10, 4, 0, 1);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 0, 1, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 0, 0, 2);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 255, 0, 0);
        place(alice, 1, 10, 5, 0, 1);
        vm.expectRevert(OGClubClubs.TileTaken.selector);
        place(alice, 1, 11, 6, 0, 1);
        place(alice, 1, 11, 6, 0, 0); // Same position on the other side is independent.
        vm.expectRevert(OGClubClubs.FootprintLocked.selector);
        clubs.setFootprint(10, 2, 1, false);
        vm.expectRevert(OGClubClubs.FootprintLocked.selector);
        clubs.setFootprint(10, 2, 1, true);
        (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(10);
        assertEq(w, 2);
        assertEq(h, 1);
        assertTrue(set && locked && wall);
        clubs.setFootprint(12, 3, 3, false);
        clubs.setFootprint(12, 3, 1, true); // Unplaced flag may change.
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(13, 1, 2, true);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(13, 0, 1, true);
        vm.expectRevert(OGClubClubs.BadFootprint.selector);
        clubs.setFootprint(13, 5, 1, true);
    }

    function test_WallLengthsAtEveryLevelAndExtensionAfterUpgrade() public {
        for (uint8 level = 1; level <= 4; ++level) {
            uint256 clubId = 100 + level;
            pepes.mint(alice, clubId);
            vm.prank(alice);
            clubs.mintClub(clubId);
            for (uint8 upgrade = 1; upgrade < level; ++upgrade) {
                vm.prank(alice);
                clubs.upgradeClub(clubId);
            }
            for (uint8 side; side < 2; ++side) {
                uint8 length = side == 0 ? (level == 1 ? 10 : level == 4 ? 16 : 14) : (level < 3 ? 10 : 16);
                uint256 item = 1000 + uint256(level) * 10 + side;
                _design(item, 2, true);
                vm.expectRevert(OGClubClubs.OutOfRoom.selector);
                place(alice, clubId, item, length - 1, 0, side);
                place(alice, clubId, item, length - 2, 0, side);
                assertTrue(clubs.wallTaken(clubId, side, length - 1));
            }
        }
        _design(10, 1, true);
        _design(11, 1, true);
        _design(12, 1, true);
        _design(13, 1, true);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 10, 10, 0, 0);
        vm.prank(alice);
        clubs.upgradeClub(1);
        place(alice, 1, 10, 13, 0, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 11, 10, 0, 1);
        vm.prank(alice);
        clubs.upgradeClub(1);
        place(alice, 1, 11, 15, 0, 1);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        place(alice, 1, 12, 14, 0, 0);
        vm.prank(alice);
        clubs.upgradeClub(1);
        place(alice, 1, 12, 15, 0, 0);
        assertTrue(clubs.wallTaken(1, 0, 13));
        assertTrue(clubs.wallTaken(1, 1, 15));
    }

    function test_WallDoorAtEveryLevel() public {
        _design(10, 2, true);
        for (uint8 level = 1; level <= 4; ++level) {
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 10, 3, 0, 1);
            vm.expectRevert(OGClubClubs.BlocksDoor.selector);
            place(alice, 1, 10, 4, 0, 1);
            if (level < 4) {
                vm.prank(alice);
                clubs.upgradeClub(1);
            }
        }
        place(alice, 1, 10, 5, 0, 1);
    }

    function test_OneOfEachFloorAndWallPerClubSurvivesTransfer() public {
        _design(10, 1, true);
        place(alice, 1, 1, 0, 0, 0);
        place(alice, 1, 10, 0, 0, 0);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(alice, 1, 1, 1, 0, 0);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(alice, 1, 10, 1, 0, 0);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(alice, 1, 10, 0, 0, 1);
        vm.prank(alice);
        clubs.mintClub(3);
        place(alice, 3, 1, 0, 0, 0);
        place(alice, 3, 10, 0, 0, 0);
        vm.prank(alice);
        clubs.transferFrom(alice, bob, 1);
        stock(bob, 10, 1);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(bob, 1, 1, 1, 0, 0);
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(bob, 1, 10, 1, 0, 0);
        assertTrue(clubs.hasDesign(1, 1));
        assertTrue(clubs.hasDesign(1, 10));
        assertTrue(clubs.hasDesign(3, 1));
        assertTrue(clubs.hasDesign(3, 10));
        assertEq(furniture.balanceOf(address(clubs), 1), 2);
        assertEq(furniture.balanceOf(address(clubs), 10), 2);
    }

    function test_ClubFullReachableAt285DistinctDesignsWithoutStorageCheats() public {
        vm.startPrank(alice);
        clubs.upgradeClub(1);
        clubs.upgradeClub(1);
        clubs.upgradeClub(1);
        vm.stopPrank();
        uint256 item = 100;
        for (uint8 y; y < 16; ++y) {
            for (uint8 x; x < 16; ++x) {
                if (y == 4 && x < 2) continue;
                _design(item, 1, false);
                place(alice, 1, item++, x, y, 0);
            }
        }
        assertEq(clubs.pieceCount(1), 254);
        for (uint8 side; side < 2; ++side) {
            for (uint8 pos; pos < 16; ++pos) {
                if (side == 1 && pos == 4) continue;
                _design(item, 1, true);
                place(alice, 1, item++, pos, 0, side);
            }
        }
        assertEq(clubs.pieceCount(1), 285);
        assertEq(clubs.MAX_PIECES(), 285);
        for (uint256 id = 100; id < item; ++id) {
            assertTrue(clubs.hasDesign(1, id));
            assertEq(furniture.balanceOf(address(clubs), id), 1);
        }
        vm.expectRevert(OGClubClubs.AlreadyHasDesign.selector);
        place(alice, 1, 100, 0, 0, 0);
        _design(item, 1, true);
        vm.expectRevert(OGClubClubs.ClubFull.selector);
        place(alice, 1, item, 0, 0, 0);
        assertFalse(clubs.hasDesign(1, item));
        assertEq(furniture.balanceOf(address(clubs), item), 0);
    }
}
