// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {OGClubRaffle} from "../src/OGClubRaffle.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {HeaderBuilder} from "./helpers/HeaderBuilder.sol";

/// @notice Reproductions of the imported audit; existing contracts must remain unchanged.
contract ImportedAuditTest is Test {
    MockSwarmPepe internal pepes;
    IDelegateRegistry internal delegates;

    function _upgradePrices() internal pure returns (uint256[3] memory) {
        return [uint256(200_000e18 + 1), 400_000e18 + 3, 800_000e18 + 7];
    }
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubFarmVault internal vault;
    OGClubStaking internal staking;
    OGClubRaffle internal raffle;
    address internal alice = makeAddr("audit alice");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        pepes = new MockSwarmPepe();
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), address(this));
        vault = new OGClubFarmVault(token, address(this));
        staking = new OGClubStaking(token, address(vault), address(this), 1e18);
        raffle = new OGClubRaffle(staking, furniture, address(this), 0);
    }

    function test_Audit2fa7888_RaffleNeedsFirstGrantsWrongTargetConsumesBootstrap() public {
        _stake(alice, 10e18);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.pointsOf(alice), 10e18);
        uint256 id = _create();
        vm.expectRevert(OGClubStaking.NotSpender.selector);
        vm.prank(alice);
        raffle.enter(id, 0, 1);
        assertEq(staking.pointsOf(alice), 10e18);
        staking.grantSpender(address(this));
        staking.grantSpender(address(raffle));
        furniture.grantMinter(address(this));
        furniture.grantMinter(address(raffle));
        uint256 activatesAt = block.timestamp + 7 days;
        assertFalse(staking.spenders(address(raffle)));
        assertFalse(furniture.minters(address(raffle)));
        assertEq(staking.pendingSpenders(address(raffle)), activatesAt);
        assertEq(furniture.pendingMinters(address(raffle)), activatesAt);
        vm.expectRevert(
            abi.encodeWithSelector(OGClubStaking.SpenderDelayNotElapsed.selector, address(raffle), activatesAt)
        );
        staking.activateSpender(address(raffle));
        vm.expectRevert(
            abi.encodeWithSelector(OGClubFurniture.MinterDelayNotElapsed.selector, address(raffle), activatesAt)
        );
        furniture.activateMinter(address(raffle));
        vm.warp(activatesAt);
        staking.activateSpender(address(raffle));
        furniture.activateMinter(address(raffle));
        id = _create();
        vm.prank(alice);
        raffle.enter(id, 0, 1);
        assertTrue(staking.spenders(address(raffle)));
        assertTrue(furniture.minters(address(raffle)));
    }

    function test_Audit1ecd3a7_AnyoneCanMintTestnetStakeAndBuyClubs() public {
        _stake(alice, 1e30);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.pointsOf(alice), 1e30);
        OGClubClubs clubs = new OGClubClubs(
            token,
            address(vault),
            100_000e18,
            IERC1155(address(furniture)),
            address(this),
            address(this),
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        clubs.setSaleOpen(true);
        pepes.mint(alice, 1);
        vm.startPrank(alice);
        token.mint(alice, clubs.price());
        token.approve(address(clubs), clubs.price());
        clubs.mintClub(1);
        vm.stopPrank();
        assertEq(clubs.ownerOf(1), alice);
        assertEq(token.balanceOf(address(vault)), 50_000e18);
        assertFalse(furniture.minters(address(clubs)));
        assertFalse(staking.spenders(address(clubs)));
    }

    function test_Audit07e7433_TargetExpiresAndCanBeReplacedButDrawnSeedIsFinal() public {
        uint256 id = _create();
        vm.warp(block.timestamp + 1 days);
        raffle.commitDraw(id);
        (,, uint64 firstTarget,,,,) = raffle.raffles(id);
        assertEq(firstTarget, 1003);
        vm.roll(firstTarget + 256);
        vm.expectRevert(OGClubRaffle.TargetStillLive.selector);
        raffle.commitDraw(id);
        vm.roll(firstTarget + 257);
        vm.expectRevert(OGClubRaffle.TargetUnavailable.selector);
        raffle.draw(id, "");
        raffle.commitDraw(id);
        (,, uint64 secondTarget,,,,) = raffle.raffles(id);
        assertEq(secondTarget, 1263);
        assertTrue(secondTarget != firstTarget);
        bytes32 seed = keccak256("replacement target seed");
        bytes memory header = HeaderBuilder.header(secondTarget, seed, 9);
        vm.roll(secondTarget + 1);
        vm.setBlockhash(secondTarget, keccak256(header));
        raffle.draw(id, header);
        (,,,,, bool drawn, bytes32 recorded) = raffle.raffles(id);
        assertTrue(drawn);
        assertEq(recorded, seed);
        vm.roll(secondTarget + 257);
        vm.expectRevert(OGClubRaffle.AlreadyDrawn.selector);
        raffle.commitDraw(id);
    }

    function test_Audit9dcac50_ClubsNowWorkWithoutRaffleBootstrapRoles() public {
        OGClubClubs clubs = new OGClubClubs(
            token,
            address(vault),
            100_000e18,
            IERC1155(address(furniture)),
            address(this),
            address(this),
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        clubs.setSaleOpen(true);
        pepes.mint(alice, 1);
        vm.startPrank(alice);
        token.mint(alice, 100_000e18);
        token.approve(address(clubs), 100_000e18);
        clubs.mintClub(1);
        vm.stopPrank();
        assertFalse(furniture.bootstrapped());
        assertFalse(staking.bootstrapped());
        assertEq(clubs.ownerOf(1), alice);
        assertEq(clubs.pieceCount(1), 0);
        assertEq(token.balanceOf(address(clubs)), 0);
    }

    function _stake(address who, uint256 amount) private {
        vm.startPrank(who);
        token.mint(who, amount);
        token.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _create() private returns (uint256) {
        OGClubRaffle.PoolInput[] memory pools = new OGClubRaffle.PoolInput[](1);
        OGClubRaffle.Prize[] memory prizes = new OGClubRaffle.Prize[](1);
        prizes[0] = OGClubRaffle.Prize(7, 1);
        pools[0] = OGClubRaffle.PoolInput(0, 1e18, 0, prizes);
        return raffle.createRaffle(block.timestamp, block.timestamp + 1 days, pools);
    }
}
