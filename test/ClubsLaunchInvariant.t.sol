// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {LaunchLayoutModel as Model} from "./helpers/LaunchLayoutModel.sol";
import {MockDelegateRegistry} from "./helpers/ClubLaunchMocks.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract ClubsLaunchFuzzTest is ClubsTestBase {
    Model.Board private board;
    uint256 private successes;

    struct Snapshot {
        bytes32 layout;
        uint256 held;
        uint256 owned;
        bool locked;
    }

    function testFuzz_LevelsWallsFloorShapesRotationsAndDuplicateDesigns(bytes32 seed) public {
        uint8 level = uint8(1 + uint256(seed) % 4);
        for (uint8 i = 1; i < level; ++i) {
            vm.prank(alice);
            clubs.upgradeClub(1);
        }
        for (uint8 item; item < 32; ++item) {
            uint256 random = uint256(keccak256(abi.encode(seed, item)));
            bool wall = item >= 16;
            clubs.setFootprint(100 + item, uint8(1 + random % 4), wall ? 1 : uint8(1 + (random >> 8) % 4), wall);
            stock(alice, 100 + item, 48);
        }
        for (uint256 i; i < 48; ++i) {
            if (i != 0 && i % 12 == 0 && level < 4) {
                vm.prank(alice);
                clubs.upgradeClub(1);
                ++level;
            }
            _attempt(uint256(keccak256(abi.encode(seed, "placement", i))), level);
        }
        for (uint8 y; y < 16; ++y) {
            for (uint8 x; x < 16; ++x) {
                if (Model.inside(level, x, y)) assertEq(clubs.tileTaken(1, x, y), board.floor[uint256(y) * 16 + x]);
            }
        }
        for (uint8 side; side < 2; ++side) {
            for (uint8 pos; pos < Model.length(level, side); ++pos) {
                assertEq(clubs.wallTaken(1, side, pos), board.walls[uint256(side) * 16 + pos]);
            }
        }
        assertFalse(board.floor[64]);
        assertFalse(board.floor[65]);
        assertFalse(board.walls[20]);
        for (uint8 item; item < 32; ++item) {
            assertEq(furniture.balanceOf(address(clubs), 100 + item), board.designs[item] ? 1 : 0);
        }
    }

    function _attempt(uint256 r, uint8 level) private {
        uint8 design = uint8(r % 32);
        uint256 item = 100 + design;
        (uint8 w, uint8 h,, bool locked, bool wall) = clubs.footprintOf(item);
        Model.Placement memory p = Model.Placement(
            w,
            h,
            wall,
            uint8((r >> 8) % 18),
            wall ? uint8((r >> 16) % 8 == 0 ? 1 : 0) : uint8((r >> 16) % 18),
            uint8((r >> 24) % (wall ? 3 : 5)),
            design
        );
        Snapshot memory before_ = Snapshot(
            keccak256(abi.encode(clubs.piecesOf(1))),
            furniture.balanceOf(address(clubs), item),
            furniture.balanceOf(alice, item),
            locked
        );
        bool expected = Model.valid(board, level, p);
        vm.prank(alice);
        (bool ok,) = address(furniture)
            .call(
                abi.encodeCall(
                    furniture.safeTransferFrom,
                    (alice, address(clubs), item, 1, abi.encode(uint256(1), p.x, p.y, p.rot))
                )
            );
        assertEq(ok, expected, "independent model disagrees");
        if (ok) {
            board = Model.occupy(board, p);
            ++successes;
            OGClubClubs.Piece memory piece = clubs.piecesOf(1)[successes - 1];
            assertEq(abi.encode(piece), abi.encode(OGClubClubs.Piece(item, p.x, p.y, p.rot, wall)));
        } else {
            assertEq(keccak256(abi.encode(clubs.piecesOf(1))), before_.layout);
            assertEq(furniture.balanceOf(address(clubs), item), before_.held);
            assertEq(furniture.balanceOf(alice, item), before_.owned);
            (,,, bool stillLocked,) = clubs.footprintOf(item);
            assertEq(stillLocked, before_.locked);
        }
        assertEq(clubs.hasDesign(1, item), board.designs[design]);
        assertEq(clubs.pieceCount(1), successes);
    }
}

contract LaunchClubsHandler is Test {
    OGClubClubs public immutable clubs;
    OGClubFurniture public immutable furniture;
    MockOG public immutable token;
    MockSwarmPepe public immutable pepes;
    MockDelegateRegistry public immutable registry;
    address public immutable admin;
    address[3] public actors;
    mapping(uint256 => uint256) public mintCount;
    mapping(uint256 => uint8) public levels;
    mapping(uint256 => Model.Board) private _boards;
    mapping(uint256 => uint256) public held;
    uint256 public paid;
    uint256 public burned;
    uint256 public toVault;
    uint256 public successfulPlacements;
    uint256 public rejectedPlacements;

    constructor(OGClubClubs c, OGClubFurniture f, MockOG t, MockSwarmPepe p, MockDelegateRegistry d, address owner) {
        clubs = c;
        furniture = f;
        token = t;
        pepes = p;
        registry = d;
        admin = owner;
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string.concat("launch actor", vm.toString(i)));
        }
        for (uint256 i; i < 8; ++i) {
            pepes.mint(actors[i % 3], pepeId(i));
        }
    }

    function pepeId(uint256 i) public pure returns (uint256) {
        return i == 0 ? 0 : 700 + 31 * i;
    }

    function mint(uint8 pepeSeed, uint8 actorSeed) public {
        uint256 id = pepeId(pepeSeed % 8);
        address caller = actors[actorSeed % 3];
        uint256 cost = clubs.price();
        _fund(caller, cost);
        address holder = pepes.ownerOf(id);
        bool expected = clubs.saleOpen() && mintCount[id] == 0
            && (holder == caller || registry.checkDelegateForERC721(caller, holder, address(pepes), id, bytes32(0)));
        uint256 beforeBurn = token.balanceOf(clubs.BURN_ADDRESS());
        uint256 beforeVault = token.balanceOf(clubs.vault());
        vm.prank(caller);
        (bool ok,) = address(clubs).call(abi.encodeCall(clubs.mintClub, (id)));
        assertEq(ok, expected, "mint model");
        if (ok) {
            ++mintCount[id];
            assertEq(mintCount[id], 1);
            levels[id] = 1;
            _recordPayment(cost);
            assertEq(clubs.ownerOf(id), caller);
        } else {
            assertEq(token.balanceOf(clubs.BURN_ADDRESS()), beforeBurn);
            assertEq(token.balanceOf(clubs.vault()), beforeVault);
            assertEq(token.allowance(caller, address(clubs)), cost);
        }
    }

    function delegatePepe(uint8 pepeSeed, uint8 actorSeed, bool enabled) external {
        uint256 id = pepeId(pepeSeed % 8);
        vm.prank(pepes.ownerOf(id));
        registry.delegateERC721(actors[actorSeed % 3], address(pepes), id, bytes32(0), enabled);
    }

    function transferPepe(uint8 pepeSeed, uint8 actorSeed) external {
        uint256 id = pepeId(pepeSeed % 8);
        address holder = pepes.ownerOf(id);
        vm.prank(holder);
        pepes.transferFrom(holder, actors[actorSeed % 3], id);
    }

    function sale(bool open) external {
        vm.prank(admin);
        clubs.setSaleOpen(open);
    }

    function transferClub(uint8 clubSeed, uint8 actorSeed) external {
        if (clubs.totalSupply() == 0) return;
        uint256 id = clubs.tokenByIndex(clubSeed % clubs.totalSupply());
        address holder = clubs.ownerOf(id);
        bytes32 layout = keccak256(abi.encode(clubs.piecesOf(id)));
        vm.prank(holder);
        clubs.transferFrom(holder, actors[actorSeed % 3], id);
        assertEq(keccak256(abi.encode(clubs.piecesOf(id))), layout);
    }

    function approveClub(uint8 clubSeed, uint8 actorSeed, bool enabled, bool all) external {
        if (clubs.totalSupply() == 0) return;
        uint256 id = clubs.tokenByIndex(clubSeed % clubs.totalSupply());
        address holder = clubs.ownerOf(id);
        address spender = actors[actorSeed % 3];
        if (spender == holder) return;
        vm.prank(holder);
        if (all) clubs.setApprovalForAll(spender, enabled);
        else clubs.approve(enabled ? spender : address(0), id);
    }

    function upgrade(uint8 clubSeed, uint8 actorSeed, bool short) public {
        if (clubs.totalSupply() == 0) return;
        uint256 id = clubs.tokenByIndex(clubSeed % clubs.totalSupply());
        address caller = actors[actorSeed % 3];
        uint8 level = levels[id];
        uint256 cost = level == 1 ? 201 : level == 2 ? 403 : 807;
        _fund(caller, cost);
        if (short) {
            vm.prank(caller);
            token.approve(address(clubs), cost - 1);
        }
        uint256 beforeBurn = token.balanceOf(clubs.BURN_ADDRESS());
        uint256 beforeVault = token.balanceOf(clubs.vault());
        bytes32 layout = keccak256(abi.encode(clubs.piecesOf(id)));
        bool expected = level < 4 && _authorized(id, caller) && !short;
        vm.prank(caller);
        (bool ok,) = address(clubs).call(abi.encodeCall(clubs.upgradeClub, (id)));
        assertEq(ok, expected, "upgrade model");
        if (ok) {
            levels[id] = level + 1;
            _recordPayment(cost);
        } else {
            assertEq(token.balanceOf(clubs.BURN_ADDRESS()), beforeBurn);
            assertEq(token.balanceOf(clubs.vault()), beforeVault);
        }
        assertEq(clubs.levelOf(id), levels[id]);
        assertEq(keccak256(abi.encode(clubs.piecesOf(id))), layout);
    }

    function place(uint8 clubSeed, uint8 actorSeed, uint8 design, uint8 x, uint8 y, uint8 rot, bool furnitureOperator)
        public
    {
        if (clubs.totalSupply() == 0) return;
        uint256 id = clubs.tokenByIndex(clubSeed % clubs.totalSupply());
        design %= 32;
        uint256 item = 100 + design;
        address from = actors[actorSeed % 3];
        (uint8 w, uint8 h,, bool locked, bool wall) = clubs.footprintOf(item);
        Model.Placement memory p =
            Model.Placement(w, h, wall, x % 18, wall ? y % 2 : y % 18, rot % (wall ? 3 : 5), design);
        _place(id, from, item, p, locked, furnitureOperator);
    }

    function _place(uint256 id, address from, uint256 item, Model.Placement memory p, bool locked, bool useOperator)
        private
    {
        {
            uint256[] memory ids = new uint256[](1);
            ids[0] = item;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1;
            furniture.mintBatch(from, ids, amounts);
        }
        uint256 ownedBefore = furniture.balanceOf(from, item);
        bytes32 layout = keccak256(abi.encode(clubs.piecesOf(id)));
        bool expected = _authorized(id, from) && Model.valid(_boards[id], levels[id], p);
        address caller = from;
        if (useOperator) {
            caller = address(this);
            vm.prank(from);
            furniture.setApprovalForAll(caller, true);
        }
        bool ok = _send(from, caller, id, item, p);
        assertEq(ok, expected, "placement model");
        if (ok) {
            _boards[id] = Model.occupy(_boards[id], p);
            ++held[item];
            ++successfulPlacements;
        } else {
            ++rejectedPlacements;
            assertEq(keccak256(abi.encode(clubs.piecesOf(id))), layout);
            assertEq(furniture.balanceOf(from, item), ownedBefore);
            (,,, bool afterLock,) = clubs.footprintOf(item);
            assertEq(afterLock, locked);
        }
        assertEq(furniture.balanceOf(address(clubs), item), held[item]);
        assertEq(clubs.hasDesign(id, item), _boards[id].designs[p.design]);
    }

    function _send(address from, address caller, uint256 id, uint256 item, Model.Placement memory p)
        private
        returns (bool ok)
    {
        vm.prank(caller);
        (ok,) = address(furniture)
            .call(
                abi.encodeCall(
                    furniture.safeTransferFrom, (from, address(clubs), item, 1, abi.encode(id, p.x, p.y, p.rot))
                )
            );
    }

    function board(uint256 id) external view returns (Model.Board memory) {
        return _boards[id];
    }

    function _authorized(uint256 id, address account) private view returns (bool) {
        address holder = clubs.ownerOf(id);
        return account == holder || clubs.getApproved(id) == account || clubs.isApprovedForAll(holder, account);
    }

    function _fund(address caller, uint256 cost) private {
        token.mint(caller, cost);
        vm.prank(caller);
        token.approve(address(clubs), cost);
    }

    function _recordPayment(uint256 cost) private {
        paid += cost;
        burned += cost / 2;
        toVault += cost - cost / 2;
    }
}

contract ClubsLaunchInvariantTest is Test {
    MockOG internal token;
    MockSwarmPepe internal pepes;
    OGClubFurniture internal furniture;
    OGClubClubs internal clubs;
    LaunchClubsHandler internal handler;

    function setUp() public {
        token = new MockOG(address(this));
        pepes = new MockSwarmPepe();
        furniture = new OGClubFurniture(address(this), address(this));
        OGClubFarmVault vault = new OGClubFarmVault(token, address(this));
        MockDelegateRegistry registry = new MockDelegateRegistry();
        clubs = new OGClubClubs(
            token,
            address(vault),
            101,
            IERC1155(address(furniture)),
            address(this),
            address(this),
            pepes,
            registry,
            uint256(201),
            403,
            807
        );
        for (uint8 item; item < 32; ++item) {
            clubs.setFootprint(100 + item, 1 + item % 4, item >= 16 ? 1 : 1 + (item / 4) % 4, item >= 16);
        }
        clubs.setSaleOpen(true);
        handler = new LaunchClubsHandler(clubs, furniture, token, pepes, registry, address(this));
        furniture.grantMinter(address(handler));
        handler.mint(0, 0);
        handler.mint(1, 1);
        handler.mint(2, 2);
        handler.upgrade(1, 1, false);
        handler.upgrade(2, 2, false);
        handler.upgrade(2, 2, false);
        handler.upgrade(2, 2, false);
        handler.place(0, 0, 0, 0, 0, 0, false);
        handler.place(1, 1, 16, 0, 0, 0, false);
        handler.place(2, 2, 17, 5, 0, 1, true);
        handler.place(2, 2, 0, 15, 15, 0, false);
        handler.place(0, 0, 0, 1, 0, 0, false); // Duplicate: nonvacuous rejected-state path.
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.upgrade.selector;
        selectors[2] = handler.place.selector;
        selectors[3] = handler.transferClub.selector;
        selectors[4] = handler.transferPepe.selector;
        selectors[5] = handler.delegatePepe.selector;
        selectors[6] = handler.approveClub.selector;
        selectors[7] = handler.sale.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_EveryClubIsAPepeMintedExactlyOnceAndAllPaymentsConserved() public view {
        uint256 supply;
        uint256 expectedPaid;
        for (uint256 i; i < 8; ++i) {
            uint256 id = handler.pepeId(i);
            uint256 count = handler.mintCount(id);
            assertLe(count, 1);
            assertEq(clubs.clubsMinted(id), count == 1);
            if (count == 0) continue;
            ++supply;
            assertTrue(pepes.ownerOf(id) != address(0));
            assertEq(clubs.levelOf(id), handler.levels(id));
            expectedPaid += 101;
            if (handler.levels(id) >= 2) expectedPaid += 201;
            if (handler.levels(id) >= 3) expectedPaid += 403;
            if (handler.levels(id) == 4) expectedPaid += 807;
        }
        assertEq(clubs.totalSupply(), supply);
        assertEq(token.balanceOf(address(clubs)), 0);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), handler.burned());
        assertEq(token.balanceOf(clubs.vault()), handler.toVault());
        assertEq(handler.paid(), handler.burned() + handler.toVault());
        assertEq(handler.paid(), expectedPaid);
        for (uint256 i; i < clubs.totalSupply(); ++i) {
            assertEq(handler.mintCount(clubs.tokenByIndex(i)), 1);
        }
    }

    function invariant_AllLayoutsMatchIndependentModelCustodyAndUniqueDesigns() public view {
        uint256[32] memory counts;
        for (uint256 i; i < clubs.totalSupply(); ++i) {
            uint256 id = clubs.tokenByIndex(i);
            uint8 level = handler.levels(id);
            OGClubClubs.Piece[] memory pieces = clubs.piecesOf(id);
            Model.Board memory rebuilt;
            for (uint256 j; j < pieces.length; ++j) {
                OGClubClubs.Piece memory piece = pieces[j];
                (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(piece.furnitureId);
                assertTrue(set && locked);
                assertEq(wall, piece.wall);
                uint8 design = uint8(piece.furnitureId - 100);
                Model.Placement memory p = Model.Placement(w, h, wall, piece.x, piece.y, piece.rot, design);
                assertTrue(Model.valid(rebuilt, level, p), "invalid geometry or duplicate design");
                rebuilt = Model.occupy(rebuilt, p);
                ++counts[design];
            }
            assertEq(abi.encode(rebuilt), abi.encode(handler.board(id)));
            assertEq(clubs.pieceCount(id), pieces.length);
            assertLe(pieces.length, 285);
        }
        for (uint256 item; item < 32; ++item) {
            assertEq(furniture.balanceOf(address(clubs), 100 + item), counts[item]);
            assertEq(handler.held(100 + item), counts[item]);
        }
        assertGt(handler.successfulPlacements(), 0);
        assertGt(handler.rejectedPlacements(), 0);
    }

    /// @dev Check every occupancy/design view once per campaign; the layout oracle runs after every action.
    function afterInvariant() external view {
        for (uint256 i; i < clubs.totalSupply(); ++i) {
            uint256 id = clubs.tokenByIndex(i);
            uint8 level = handler.levels(id);
            Model.Board memory rebuilt = handler.board(id);
            for (uint8 y; y < 16; ++y) {
                for (uint8 x; x < 16; ++x) {
                    if (Model.inside(level, x, y)) {
                        assertEq(clubs.tileTaken(id, x, y), rebuilt.floor[uint256(y) * 16 + x]);
                    }
                }
            }
            for (uint8 side; side < 2; ++side) {
                for (uint8 pos; pos < Model.length(level, side); ++pos) {
                    assertEq(clubs.wallTaken(id, side, pos), rebuilt.walls[uint256(side) * 16 + pos]);
                }
            }
            for (uint8 design; design < 32; ++design) {
                assertEq(clubs.hasDesign(id, 100 + design), rebuilt.designs[design]);
            }
        }
    }
}
