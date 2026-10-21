// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @dev Independent cell-by-cell model, without the production bitmap or bit shifts.
library ClubLayoutModel {
    struct Placement {
        uint256 w;
        uint256 h;
        uint8 x;
        uint8 y;
        uint8 rot;
    }

    function valid(bool[100] memory occupied, Placement memory p) internal pure returns (bool) {
        if (p.rot > 3) return false;
        uint256 width = p.rot == 1 || p.rot == 3 ? p.h : p.w;
        uint256 height = p.rot == 1 || p.rot == 3 ? p.w : p.h;
        if (uint256(p.x) + width > 10 || uint256(p.y) + height > 10) return false;
        for (uint256 dx; dx < width; ++dx) {
            for (uint256 dy; dy < height; ++dy) {
                uint256 x = p.x + dx;
                uint256 y = p.y + dy;
                if ((y == 4 && (x == 0 || x == 1)) || occupied[x + 10 * y]) return false;
            }
        }
        return true;
    }

    function occupy(bool[100] memory occupied, Placement memory p) internal pure returns (bool[100] memory) {
        uint256 width = p.rot == 1 || p.rot == 3 ? p.h : p.w;
        uint256 height = p.rot == 1 || p.rot == 3 ? p.w : p.h;
        for (uint256 dx; dx < width; ++dx) {
            for (uint256 dy; dy < height; ++dy) {
                occupied[uint256(p.x) + dx + 10 * (uint256(p.y) + dy)] = true;
            }
        }
        return occupied;
    }
}

contract ClubsLayoutFuzzTest is ClubsTestBase {
    function testFuzz_RandomPlacementSequenceMatchesIndependentGridAndFailuresAreAtomic(bytes32 seed) public {
        bool[100] memory occupied;
        uint256 successes;
        for (uint256 i; i < 48; ++i) {
            uint256 random = uint256(keccak256(abi.encode(seed, i)));
            ClubLayoutModel.Placement memory p = ClubLayoutModel.Placement({
                w: 1 + random % 4,
                h: 1 + (random >> 8) % 4,
                x: uint8((random >> 16) % 12),
                y: uint8((random >> 24) % 12),
                rot: uint8((random >> 32) % 5)
            });
            uint256 item = i + 10;
            clubs.setFootprint(item, uint8(p.w), uint8(p.h), false);
            stock(alice, item, 1);
            bool expected = ClubLayoutModel.valid(occupied, p);
            bytes32 beforeLayout = keccak256(abi.encode(clubs.piecesOf(1)));
            vm.prank(alice);
            (bool ok,) = address(furniture)
                .call(
                    abi.encodeCall(
                        furniture.safeTransferFrom,
                        (alice, address(clubs), item, 1, abi.encode(uint256(1), p.x, p.y, p.rot))
                    )
                );
            assertEq(ok, expected, "placement differs from independent cell model");
            if (ok) {
                occupied = ClubLayoutModel.occupy(occupied, p);
                OGClubClubs.Piece memory piece = clubs.piecesOf(1)[successes++];
                assertEq(abi.encode(piece), abi.encode(OGClubClubs.Piece(item, p.x, p.y, p.rot, false)));
            } else {
                assertEq(keccak256(abi.encode(clubs.piecesOf(1))), beforeLayout);
            }
            assertEq(clubs.pieceCount(1), successes);
            assertEq(furniture.balanceOf(address(clubs), item), ok ? 1 : 0);
            assertEq(furniture.balanceOf(alice, item), ok ? 0 : 1);
            (,, bool set, bool locked,) = clubs.footprintOf(item);
            assertTrue(set);
            assertEq(locked, ok);
            // Verify the entire board after both successes and rejections.
            for (uint8 y; y < 10; ++y) {
                for (uint8 x; x < 10; ++x) {
                    assertEq(clubs.tileTaken(1, x, y), occupied[x + 10 * y]);
                }
            }
        }
        assertFalse(occupied[40]);
        assertFalse(occupied[41]);
    }
}

contract ClubsHandler is Test {
    MockOG public immutable token;
    OGClubFurniture public immutable furniture;
    OGClubClubs public immutable clubs;
    address public immutable admin;
    address[3] public actors;
    uint256 public ghostPaid;
    uint256 public ghostPieces;
    mapping(uint256 => uint256) public piecesByItem;
    mapping(uint256 => bool[100]) private _occupied;

    constructor(MockOG token_, OGClubFurniture furniture_, OGClubClubs clubs_, address admin_) {
        token = token_;
        furniture = furniture_;
        clubs = clubs_;
        admin = admin_;
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string.concat("club actor ", vm.toString(i)));
        }
    }

    function mint(uint8 payerSeed, uint8 toSeed) external {
        if (clubs.totalSupply() >= 8) return;
        address payer = actors[payerSeed % 3];
        toSeed; // Minting delivers to the paying Pepe holder.
        uint256 cost = clubs.price();
        token.mint(payer, cost);
        uint256 expectedId = clubs.totalSupply() + 1;
        MockSwarmPepe pepes = MockSwarmPepe(address(clubs.pepes()));
        try pepes.ownerOf(expectedId) returns (address holder) {
            if (holder != payer) {
                vm.prank(holder);
                pepes.transferFrom(holder, payer, expectedId);
            }
        } catch {
            pepes.mint(payer, expectedId);
        }
        vm.startPrank(payer);
        token.approve(address(clubs), cost);
        if (!clubs.saleOpen()) {
            vm.expectRevert(OGClubClubs.SaleClosed.selector);
            clubs.mintClub(expectedId);
        } else {
            assertEq(clubs.mintClub(expectedId), expectedId);
            ghostPaid += cost;
        }
        vm.stopPrank();
        if (clubs.clubsMinted(expectedId)) _assertGrid(expectedId);
    }

    function place(uint8 clubSeed, uint8 fromSeed, uint8 itemSeed, uint8 xSeed, uint8 ySeed, uint8 rotSeed) external {
        if (clubs.totalSupply() == 0) return;
        uint256 clubId = 1 + clubSeed % clubs.totalSupply();
        address from = actors[fromSeed % 3];
        uint256 item = 1 + itemSeed % 4;
        (uint8 w, uint8 h,,,) = clubs.footprintOf(item);
        ClubLayoutModel.Placement memory p = ClubLayoutModel.Placement(w, h, xSeed % 12, ySeed % 12, rotSeed % 5);
        _place(clubId, from, item, p);
    }

    function _place(uint256 clubId, address from, uint256 item, ClubLayoutModel.Placement memory p) private {
        bool expected = clubs.ownerOf(clubId) == from && !clubs.hasDesign(clubId, item)
            && ClubLayoutModel.valid(_occupied[clubId], p);
        _stock(from, item);
        uint256 beforeCount = clubs.pieceCount(clubId);
        uint256 beforeBalance = furniture.balanceOf(address(clubs), item);
        bytes32 beforeLayout = keccak256(abi.encode(clubs.piecesOf(clubId)));
        vm.prank(from);
        (bool ok,) = address(furniture)
            .call(
                abi.encodeCall(
                    furniture.safeTransferFrom, (from, address(clubs), item, 1, abi.encode(clubId, p.x, p.y, p.rot))
                )
            );
        assertEq(ok, expected);
        if (ok) {
            _occupied[clubId] = ClubLayoutModel.occupy(_occupied[clubId], p);
            ++ghostPieces;
            ++piecesByItem[item];
            assertEq(clubs.pieceCount(clubId), beforeCount + 1);
        } else {
            assertEq(clubs.pieceCount(clubId), beforeCount);
            assertEq(furniture.balanceOf(address(clubs), item), beforeBalance);
            assertEq(keccak256(abi.encode(clubs.piecesOf(clubId))), beforeLayout);
        }
        // Check the affected club after every accepted or rejected placement.
        _assertGrid(clubId);
    }

    function transferClub(uint8 clubSeed, uint8 toSeed) external {
        if (clubs.totalSupply() == 0) return;
        uint256 clubId = 1 + clubSeed % clubs.totalSupply();
        address from = clubs.ownerOf(clubId);
        bytes32 layout = keccak256(abi.encode(clubs.piecesOf(clubId)));
        vm.prank(from);
        clubs.transferFrom(from, actors[toSeed % 3], clubId);
        assertEq(keccak256(abi.encode(clubs.piecesOf(clubId))), layout);
        _assertGrid(clubId);
    }

    function sale(bool open) external {
        vm.prank(admin);
        clubs.setSaleOpen(open);
    }

    function expectedTile(uint256 clubId, uint8 x, uint8 y) external view returns (bool) {
        return _occupied[clubId][uint256(x) + 10 * uint256(y)];
    }

    function expectedGrid(uint256 clubId) external view returns (bool[100] memory) {
        return _occupied[clubId];
    }

    function _assertGrid(uint256 clubId) private view {
        for (uint8 y; y < 10; ++y) {
            for (uint8 x; x < 10; ++x) {
                assertEq(clubs.tileTaken(clubId, x, y), _occupied[clubId][uint256(x) + 10 * y]);
            }
        }
    }

    function _stock(address to, uint256 item) private {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = item;
        amounts[0] = 1;
        furniture.mintBatch(to, ids, amounts);
    }
}

contract ClubsInvariantTest is Test {
    MockSwarmPepe internal pepes;
    IDelegateRegistry internal delegates;

    function _upgradePrices() internal pure returns (uint256[3] memory) {
        return [uint256(200_000e18 + 1), 400_000e18 + 3, 800_000e18 + 7];
    }
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubFarmVault internal vault;
    OGClubClubs internal clubs;
    ClubsHandler internal handler;
    uint256 internal constant PRICE = 100_000e18 + 1;

    function setUp() public {
        pepes = new MockSwarmPepe();
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), address(this));
        vault = new OGClubFarmVault(token, address(this));
        clubs = new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            address(this),
            address(this),
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        clubs.setFootprint(1, 1, 1, false);
        clubs.setFootprint(2, 2, 1, false);
        clubs.setFootprint(3, 2, 2, false);
        clubs.setFootprint(4, 4, 3, false);
        clubs.setSaleOpen(true);
        handler = new ClubsHandler(token, furniture, clubs, address(this));
        furniture.grantMinter(address(handler));
        handler.mint(0, 0);
        handler.place(0, 0, 0, 0, 0, 0);
        handler.transferClub(0, 1);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.place.selector;
        selectors[2] = handler.transferClub.selector;
        selectors[3] = handler.sale.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_PaymentsNeverRemainInClubsAndSplitExactly() public view {
        assertEq(token.balanceOf(address(clubs)), 0);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), PRICE / 2 * clubs.totalSupply());
        assertEq(token.balanceOf(address(vault)), (PRICE - PRICE / 2) * clubs.totalSupply());
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()) + token.balanceOf(address(vault)), handler.ghostPaid());
        assertEq(handler.ghostPaid(), PRICE * clubs.totalSupply());
    }

    function invariant_EveryHeldFurniturePieceHasExactlyOnePermanentLayoutEntry() public view {
        uint256 pieceSum;
        uint256[] memory perItem = new uint256[](5);
        for (uint256 clubId = 1; clubId <= clubs.totalSupply(); ++clubId) {
            OGClubClubs.Piece[] memory pieces = clubs.piecesOf(clubId);
            pieceSum += pieces.length;
            assertEq(clubs.pieceCount(clubId), pieces.length);
            assertLe(pieces.length, 98);
            bool[100] memory reconstructed;
            for (uint256 i; i < pieces.length; ++i) {
                OGClubClubs.Piece memory piece = pieces[i];
                (uint8 w, uint8 h, bool set, bool locked,) = clubs.footprintOf(piece.furnitureId);
                assertTrue(set && locked);
                ClubLayoutModel.Placement memory p = ClubLayoutModel.Placement(w, h, piece.x, piece.y, piece.rot);
                assertTrue(ClubLayoutModel.valid(reconstructed, p), "overlap, door or bounds violation");
                reconstructed = ClubLayoutModel.occupy(reconstructed, p);
                ++perItem[piece.furnitureId];
            }
            assertEq(abi.encode(reconstructed), abi.encode(handler.expectedGrid(clubId)));
        }
        uint256 held;
        for (uint256 item = 1; item <= 4; ++item) {
            uint256 balance = furniture.balanceOf(address(clubs), item);
            assertEq(balance, perItem[item]);
            assertEq(balance, handler.piecesByItem(item));
            held += balance;
        }
        assertEq(pieceSum, held);
        assertEq(pieceSum, handler.ghostPieces());
        assertGt(pieceSum, 0);
    }

    /// @dev Full view sweep at the end; handlers also check each affected club after every mutation.
    function afterInvariant() external view {
        for (uint256 clubId = 1; clubId <= clubs.totalSupply(); ++clubId) {
            bool[100] memory expected = handler.expectedGrid(clubId);
            for (uint8 y; y < 10; ++y) {
                for (uint8 x; x < 10; ++x) {
                    assertEq(clubs.tileTaken(clubId, x, y), expected[uint256(x) + 10 * y]);
                }
            }
        }
    }
}
