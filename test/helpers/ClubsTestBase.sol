// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {OGClubClubs} from "../../src/OGClubClubs.sol";
import {OGClubFurniture} from "../../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../../src/OGClubFarmVault.sol";
import {MockSwarmPepe} from "../../src/mocks/MockSwarmPepe.sol";
import {IDelegateRegistry} from "../../src/interfaces/IDelegateRegistry.sol";
import {MockOG} from "../../src/mocks/MockOG.sol";

abstract contract ClubsTestBase is Test {
    uint256 internal constant PRICE = 100_000e18 + 1;
    MockSwarmPepe internal pepes;
    IDelegateRegistry internal delegates;

    function _upgradePrices() internal pure returns (uint256[3] memory) {
        return [uint256(200_000e18 + 1), 400_000e18 + 3, 800_000e18 + 7];
    }
    MockOG internal token;
    OGClubFurniture internal furniture;
    OGClubFarmVault internal vault;
    OGClubClubs internal clubs;
    address internal alice = makeAddr("club alice");
    address internal bob = makeAddr("club bob");
    address internal operator = makeAddr("club operator");
    address internal royalty = makeAddr("club royalty");

    function setUp() public virtual {
        pepes = new MockSwarmPepe();
        token = new MockOG(address(this));
        furniture = new OGClubFurniture(address(this), royalty);
        vault = new OGClubFarmVault(token, address(this));
        clubs = new OGClubClubs(
            token,
            address(vault),
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
        furniture.grantMinter(address(this));
        clubs.setSaleOpen(true);
        clubs.setFootprint(1, 1, 1, false);
        clubs.setFootprint(2, 2, 1, false);
        clubs.setFootprint(3, 2, 2, false);
        clubs.setFootprint(4, 4, 4, false);
        fund(alice, 100 * PRICE);
        fund(bob, 100 * PRICE);
        stock(alice, 1, 200);
        stock(alice, 2, 200);
        stock(alice, 3, 200);
        stock(alice, 4, 200);
        stock(bob, 1, 200);
        pepes.mint(alice, 1);
        pepes.mint(bob, 2);
        pepes.mint(alice, 3);
        vm.prank(alice);
        clubs.mintClub(1);
    }

    function fund(address who, uint256 amount) internal {
        token.mint(who, amount);
        vm.prank(who);
        token.approve(address(clubs), amount);
    }

    function stock(address who, uint256 id, uint256 amount) internal {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = amount;
        furniture.mintBatch(who, ids, amounts);
    }

    function place(address from, uint256 clubId, uint256 item, uint8 x, uint8 y, uint8 rot) internal {
        vm.prank(from);
        furniture.safeTransferFrom(from, address(clubs), item, 1, abi.encode(clubId, x, y, rot));
    }
}
