// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MockSwarmPepe} from "../src/mocks/MockSwarmPepe.sol";
import {IDelegateRegistry} from "../src/interfaces/IDelegateRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {OGClubStaking} from "../src/OGClubStaking.sol";
import {OGClubRaffle} from "../src/OGClubRaffle.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {OGClubFurniture} from "../src/OGClubFurniture.sol";
import {OGClubFarmVault} from "../src/OGClubFarmVault.sol";
import {MockOG} from "../src/mocks/MockOG.sol";
import {ClubDeployment, DeployClubsSepolia, DeployClubsMainnet} from "../script/DeployClubs.s.sol";

contract ClubsConstructorFactory {
    function deploy(bytes memory code, bytes32 salt) external returns (address created) {
        assembly ("memory-safe") {
            created := create2(0, add(code, 32), mload(code), salt)
        }
        require(created != address(0), "constructor failed");
    }
}

contract ClubStackFactory {
    function deployAll(bytes[] memory codes, bytes32[] memory salts) external returns (address[] memory created) {
        require(codes.length == salts.length && codes.length <= 8);
        created = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address deployed;
            require(code.length <= 49_152);
            assembly ("memory-safe") { deployed := create2(0, add(code, 32), mload(code), salt) }
            require(deployed != address(0));
            created[i] = deployed;
        }
    }
}

contract ClubsDeploymentTest is Test {
    uint256 internal constant DEPLOYER_TEST_KEY = 0x12345; // Local test signer only; never a launch value.

    function _prices() internal pure returns (uint256[3] memory) {
        return [uint256(200_000e18), 400_000e18, 800_000e18];
    }
    address internal owner = makeAddr("club deployment owner");
    address internal royalty = makeAddr("club deployment royalty");

    function test_SepoliaScriptDeploysRealDependenciesConfiguresAndOpensSale() public {
        vm.chainId(11155111);
        DeployClubsSepolia script = new DeployClubsSepolia();
        (MockOG token, OGClubFurniture furniture, OGClubFarmVault vault, OGClubClubs clubs, MockSwarmPepe pepes) =
            script.deploy(owner, royalty, "[[0,1,1,0],[7,2,1,1],[99,4,4,0]]");
        assertEq(token.balanceOf(owner), token.INITIAL_SUPPLY());
        assertEq(furniture.owner(), owner);
        assertEq(vault.owner(), owner);
        assertEq(clubs.owner(), owner);
        assertEq(address(vault.token()), address(token));
        assertEq(address(clubs.token()), address(token));
        assertEq(clubs.vault(), address(vault));
        assertEq(address(clubs.furniture()), address(furniture));
        assertEq(clubs.price(), 100_000e18);
        assertTrue(clubs.saleOpen());
        _assertFootprint(clubs, 0, 1, 1, false);
        _assertFootprint(clubs, 7, 2, 1, true);
        _assertFootprint(clubs, 99, 4, 4, false);
        assertFalse(furniture.bootstrapped()); // Club scripts do not consume the raffle's first grant.
        (address receiver, uint256 amount) = clubs.royaltyInfo(1, 10_000);
        assertEq(receiver, royalty);
        assertEq(amount, 500);
        pepes.mint(owner, 42);
        assertEq(address(clubs.delegates()), script.DELEGATE_REGISTRY_V2());
        assertEq(address(clubs.pepes()), address(pepes));
        vm.startPrank(owner);
        token.approve(address(clubs), clubs.price());
        assertEq(clubs.mintClub(42), 42);
        vm.stopPrank();
        assertEq(token.balanceOf(address(vault)), 50_000e18);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), 50_000e18);
        assertEq(token.balanceOf(address(clubs)), 0);
    }

    function _config() private returns (DeployClubsMainnet.Config memory config) {
        MockOG token = new MockOG(owner);
        OGClubFarmVault vault = new OGClubFarmVault(token, owner);
        config = DeployClubsMainnet.Config({
            token: token,
            vault: address(vault),
            price: 123,
            furniture: IERC1155(makeAddr("existing furniture")),
            owner: owner,
            royaltyReceiver: royalty,
            pepes: IERC721(makeAddr("existing Swarm Pepe")),
            delegates: IDelegateRegistry(0x00000000000000447e69651d841bD8D104Bed493),
            upgradePrices: _prices()
        });
    }

    function test_MainnetScriptDeploysFromSeparateKeyWithContractOwnerAndLeavesSetupToOwner() public {
        vm.chainId(1);
        DeployClubsMainnet.Config memory config = _config();
        config.owner = address(new ClubsConstructorFactory()); // A contract has no EOA signing key.
        DeployClubsMainnet script = new DeployClubsMainnet();
        address deployer = vm.addr(DEPLOYER_TEST_KEY);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        OGClubClubs clubs = script.deploy(config, DEPLOYER_TEST_KEY, "[[7,2,1,1]]");
        assertEq(address(clubs), predicted);
        assertEq(address(clubs.token()), address(config.token));
        assertEq(clubs.vault(), config.vault);
        assertEq(clubs.price(), 123);
        assertEq(address(clubs.furniture()), address(config.furniture));
        assertEq(clubs.owner(), config.owner);
        assertEq(address(clubs.pepes()), address(config.pepes));
        assertEq(address(clubs.delegates()), address(config.delegates));
        assertEq(clubs.upgradePrice(1), 200_000e18);
        assertFalse(clubs.saleOpen());
        (,, bool set,,) = clubs.footprintOf(7);
        assertFalse(set); // Owner operations are printed, never broadcast as a Safe.
        vm.prank(config.owner);
        clubs.setFootprint(7, 2, 1, true);
        _assertFootprint(clubs, 7, 2, 1, true);
        vm.expectRevert(OGClubClubs.SaleClosed.selector);
        clubs.mintClub(1);
    }

    function test_MainnetScriptRejectsWrongVaultTokenBeforeDeploying() public {
        vm.chainId(1);
        DeployClubsMainnet.Config memory config = _config();
        MockOG other = new MockOG(owner);
        config.vault = address(new OGClubFarmVault(other, owner));
        DeployClubsMainnet script = new DeployClubsMainnet();
        address deployer = vm.addr(DEPLOYER_TEST_KEY);
        uint64 nonce = vm.getNonce(deployer);
        vm.expectRevert(ClubDeployment.WrongVaultToken.selector);
        script.deploy(config, DEPLOYER_TEST_KEY, "[]");
        assertEq(vm.getNonce(deployer), nonce);
        config.vault = makeAddr("missing vault");
        vm.expectRevert();
        script.deploy(config, DEPLOYER_TEST_KEY, "[]");
        assertEq(vm.getNonce(deployer), nonce);
    }

    function test_EmptyFootprintsAreExplicitlyUnconfiguredAndScriptsEnforceChain() public {
        vm.chainId(31337);
        DeployClubsSepolia script = new DeployClubsSepolia();
        (,,, OGClubClubs clubs,) = script.deploy(owner, royalty, "[]");
        (,, bool set, bool locked,) = clubs.footprintOf(7);
        assertFalse(set);
        assertFalse(locked);
        vm.chainId(1);
        vm.expectRevert(ClubDeployment.WrongChain.selector);
        script.deploy(owner, royalty, "[]");
        DeployClubsMainnet mainnet = new DeployClubsMainnet();
        vm.chainId(11155111);
        DeployClubsMainnet.Config memory config;
        vm.expectRevert(ClubDeployment.WrongChain.selector);
        mainnet.deploy(config, DEPLOYER_TEST_KEY, "[]");
    }

    function test_FootprintJSONValidatesBeforeDeploymentWithoutTruncation() public {
        DeployClubsSepolia script = new DeployClubsSepolia();
        string[12] memory invalid = [
            string("[[7,0,1,0]]"),
            "[[7,1,5,0]]",
            "[[7,256,1,0]]",
            "[[7,1]]",
            "[[7,1,1,2]]",
            "[[7,1,2,1]]",
            "[[7,1,1,0,0]]",
            "[[7,-1,1,0]]",
            "[[-1,1,1,0]]",
            "[[7,1.5,1,0]]",
            "[[true,1,1,0]]",
            "not JSON"
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert();
            script.parseFootprints(invalid[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(ClubDeployment.DuplicateFootprint.selector, uint256(7)));
        script.parseFootprints("[[7,1,1,0],[7,2,1,0]]");
        uint256[][] memory rows = script.parseFootprints(
            "[[115792089237316195423570985008687907853269984665640564039457584007913129639935,4,4,0]]"
        );
        assertEq(rows[0][0], type(uint256).max);
        assertEq(rows[0][1], 4);
    }

    function test_FactoryConstructorWorksOnEmptyChainWithExplicitOwnerAndBoundedRuntime() public {
        ClubsConstructorFactory factory = new ClubsConstructorFactory();
        address absentToken = makeAddr("absent token");
        address absentFurniture = makeAddr("absent furniture");
        address absentVault = makeAddr("absent vault");
        bytes memory code = abi.encodePacked(
            vm.getCode("OGClubClubs.sol:OGClubClubs"),
            abi.encode(
                absentToken,
                absentVault,
                100_000e18,
                absentFurniture,
                owner,
                royalty,
                makeAddr("absent Pepe"),
                address(0),
                _prices()[0],
                _prices()[1],
                _prices()[2]
            )
        );
        assertLe(code.length, 49_152);
        OGClubClubs clubs = OGClubClubs(factory.deploy(code, bytes32(uint256(1))));
        assertEq(clubs.owner(), owner);
        assertTrue(clubs.owner() != address(factory));
        assertFalse(clubs.saleOpen());
        assertEq(address(clubs.token()), absentToken);
        assertEq(address(clubs.furniture()), absentFurniture);
        _checkRuntime(address(clubs).code);
    }

    function test_PredictedSelfVaultIsRejected() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
        new OGClubClubs(
            IERC20(makeAddr("token")),
            predicted,
            1,
            IERC1155(makeAddr("furniture")),
            owner,
            royalty,
            IERC721(makeAddr("Pepe")),
            IDelegateRegistry(address(0)),
            _prices()[0],
            _prices()[1],
            _prices()[2]
        );
    }

    function test_SevenContractFactoryDeploymentInOneTransactionPreservesOwnersAndBootstrap() public {
        vm.chainId(11155111);
        ClubStackFactory factory = new ClubStackFactory();
        bytes[] memory codes = new bytes[](7);
        bytes32[] memory salts = new bytes32[](7);
        address[] memory predicted = new address[](7);
        string[7] memory artifacts = [
            string("MockOG.sol:MockOG"),
            "OGClubFurniture.sol:OGClubFurniture",
            "OGClubFarmVault.sol:OGClubFarmVault",
            "OGClubStaking.sol:OGClubStaking",
            "OGClubRaffle.sol:OGClubRaffle",
            "MockSwarmPepe.sol:MockSwarmPepe",
            "OGClubClubs.sol:OGClubClubs"
        ];
        for (uint256 i; i < 7; ++i) {
            salts[i] = bytes32(i + 1);
            bytes memory args;
            if (i == 0) {
                args = abi.encode(owner);
            } else if (i == 1) {
                args = abi.encode(owner, owner);
            } else if (i == 2) {
                args = abi.encode(predicted[0], owner);
            } else if (i == 3) {
                args = abi.encode(predicted[0], predicted[2], owner, uint256(1e18));
            } else if (i == 4) {
                args = abi.encode(predicted[3], predicted[1], owner, uint256(0));
            } else if (i == 6) {
                args = abi.encode(
                    predicted[0],
                    predicted[2],
                    uint256(100_000e18),
                    predicted[1],
                    owner,
                    owner,
                    predicted[5],
                    address(0x00000000000000447e69651d841bD8D104Bed493),
                    _prices()[0],
                    _prices()[1],
                    _prices()[2]
                );
            }
            codes[i] = abi.encodePacked(vm.getCode(artifacts[i]), args);
            predicted[i] = vm.computeCreate2Address(salts[i], keccak256(codes[i]), address(factory));
        }
        address[] memory created = factory.deployAll(codes, salts);
        for (uint256 i; i < 7; ++i) {
            assertEq(created[i], predicted[i]);
            _checkRuntime(created[i].code);
        }
        assertEq(MockOG(created[0]).balanceOf(owner), MockOG(created[0]).INITIAL_SUPPLY());
        assertEq(OGClubFurniture(created[1]).owner(), owner);
        assertEq(OGClubFarmVault(created[2]).owner(), owner);
        assertEq(OGClubStaking(created[3]).owner(), owner);
        assertEq(OGClubRaffle(created[4]).owner(), owner);
        assertEq(OGClubClubs(created[6]).owner(), owner);
        assertEq(address(OGClubClubs(created[6]).pepes()), created[5]);
        assertEq(address(OGClubClubs(created[6]).token()), created[0]);
        assertEq(OGClubClubs(created[6]).vault(), created[2]);
        assertFalse(OGClubClubs(created[6]).saleOpen());
        assertFalse(OGClubFurniture(created[1]).bootstrapped());
        assertFalse(OGClubStaking(created[3]).bootstrapped());
        vm.startPrank(owner);
        OGClubFurniture(created[1]).grantMinter(created[4]);
        OGClubStaking(created[3]).grantSpender(created[4]);
        vm.stopPrank();
        assertTrue(OGClubFurniture(created[1]).minters(created[4]));
        assertTrue(OGClubStaking(created[3]).spenders(created[4]));
    }

    function test_MockPepePublicMintIsSepoliaFixtureAndCannotRemint() public {
        MockSwarmPepe pepes = new MockSwarmPepe();
        vm.prank(makeAddr("any Pepe minter"));
        pepes.mint(owner, 0);
        assertEq(pepes.ownerOf(0), owner);
        vm.expectRevert();
        pepes.mint(royalty, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        pepes.mint(address(0), 1);
        _checkRuntime(address(pepes).code);
    }

    function _assertFootprint(OGClubClubs clubs, uint256 id, uint8 width, uint8 height, bool isWall) private view {
        (uint8 w, uint8 h, bool set, bool locked, bool wall) = clubs.footprintOf(id);
        assertEq(wall, isWall);
        assertEq(w, width);
        assertEq(h, height);
        assertTrue(set);
        assertFalse(locked);
    }

    function _checkRuntime(bytes memory code) private pure {
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xff) reachable = false;
        }
    }
}
