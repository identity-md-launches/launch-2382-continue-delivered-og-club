// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {ClubDeployment, DeployClubsSepolia, DeployClubsMainnet} from "../script/DeployClubs.s.sol";

/// @dev A vault-shaped contract whose token() is whatever it was told.
contract LyingVault {
    address public token;

    constructor(address token_) {
        token = token_;
    }
}

contract ClubsReviewDeployTest is Test {
    uint256 internal constant KEY = 0xA11CE; // local test signer only
    // The repository's script/club-footprints.json, inlined because tests have no filesystem permission.
    string internal constant CATALOGUE =
        "[[1,1,1,0],[2,2,1,0],[3,2,2,0],[4,4,4,0],[5,1,1,1],[6,2,1,1],[7,3,1,1],[8,4,1,1]]";
    address internal owner = makeAddr("review owner");

    function test_SepoliaScriptWiresPepesRealRegistryPricesAndWallFootprints() public {
        vm.chainId(11155111);
        DeployClubsSepolia script = new DeployClubsSepolia();
        (MockOG token,,, OGClubClubs clubs, MockSwarmPepe pepes) = script.deploy(owner, owner, CATALOGUE);
        assertEq(address(clubs.delegates()), 0x00000000000000447e69651d841bD8D104Bed493);
        assertEq(address(clubs.pepes()), address(pepes));
        assertEq(clubs.upgradePrice(1), 200_000e18);
        assertEq(clubs.upgradePrice(2), 400_000e18);
        assertEq(clubs.upgradePrice(3), 800_000e18);
        for (uint256 id = 1; id <= 8; ++id) {
            (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(id);
            assertTrue(set);
            assertFalse(locked);
            assertEq(wall, id >= 5);
            if (wall) {
                assertEq(w, id - 4);
                assertEq(h, 1);
            }
        }
        // The public mock pepe works end to end with the deployed clubs, including an upgrade.
        address user = makeAddr("sepolia user");
        pepes.mint(user, 7);
        token.mint(user, 300_000e18);
        vm.startPrank(user);
        token.approve(address(clubs), type(uint256).max);
        clubs.mintClub(7);
        clubs.upgradeClub(7);
        vm.stopPrank();
        assertEq(clubs.levelOf(7), 2);
        assertEq(token.balanceOf(user), 0);
        // Without registry code on this local chain a non-holder still cannot mint (the call fails closed).
        address stranger = makeAddr("stranger");
        pepes.mint(user, 8);
        vm.prank(stranger);
        vm.expectRevert();
        clubs.mintClub(8);
    }

    function _config(address vault, MockOG token) internal returns (DeployClubsMainnet.Config memory) {
        return DeployClubsMainnet.Config({
            token: token,
            vault: vault,
            price: 100_000e18,
            furniture: IERC1155(makeAddr("furniture")),
            owner: owner,
            royaltyReceiver: owner,
            pepes: IERC721(makeAddr("swarm pepes")),
            delegates: IDelegateRegistry(0x00000000000000447e69651d841bD8D104Bed493),
            upgradePrices: [uint256(200_000e18), 400_000e18, 800_000e18]
        });
    }

    function test_MainnetVaultCheckRejectsLookalikesAndAcceptsMatch() public {
        vm.chainId(1);
        DeployClubsMainnet script = new DeployClubsMainnet();
        MockOG og = new MockOG(owner);
        address deployer = vm.addr(KEY);
        uint64 nonce = vm.getNonce(deployer);
        // A vault for another token, and an EOA "vault", are rejected before any broadcast.
        DeployClubsMainnet.Config memory wrong = _config(address(new LyingVault(makeAddr("other token"))), og);
        DeployClubsMainnet.Config memory zero = _config(address(new LyingVault(address(0))), og);
        DeployClubsMainnet.Config memory eoa = _config(makeAddr("eoa vault"), og);
        vm.expectRevert(ClubDeployment.WrongVaultToken.selector);
        script.deploy(wrong, KEY, "[]");
        vm.expectRevert(ClubDeployment.WrongVaultToken.selector);
        script.deploy(zero, KEY, "[]");
        vm.expectRevert();
        script.deploy(eoa, KEY, "[]");
        assertEq(vm.getNonce(deployer), nonce);
        // Bad footprint JSON is also rejected before deploying.
        OGClubFarmVault realVault = new OGClubFarmVault(og, owner);
        DeployClubsMainnet.Config memory good = _config(address(realVault), og);
        vm.expectRevert(ClubDeployment.InvalidFootprintJSON.selector);
        script.deploy(good, KEY, "[[9,2,2,1]]");
        assertEq(vm.getNonce(deployer), nonce);
        // The matching vault deploys from the deployer key with OWNER as owner and the sale closed.
        OGClubClubs clubs = script.deploy(good, KEY, CATALOGUE);
        assertEq(vm.getNonce(deployer), nonce + 1);
        assertEq(clubs.owner(), owner);
        assertTrue(clubs.owner() != deployer);
        assertFalse(clubs.saleOpen());
        (,, bool set,,) = clubs.footprintOf(5);
        assertFalse(set);
        vm.prank(deployer);
        vm.expectRevert();
        clubs.setSaleOpen(true);
    }
}
