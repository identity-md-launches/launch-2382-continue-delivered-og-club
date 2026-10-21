// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClubsTestBase} from "./helpers/ClubsTestBase.sol";
import {TestToken, NoReturnToken} from "./helpers/TokenMocks.sol";
import {OGClubClubs} from "../src/OGClubClubs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors, IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Exercises the second payment leg independently and mutations of already-paid recipients.
contract ClubReceiptToken is ERC20 {
    address public recipient;
    uint8 public mode;

    constructor() ERC20("Receipt test", "RCT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(address recipient_, uint8 mode_) external {
        recipient = recipient_;
        mode = mode_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        super.transferFrom(from, to, amount);
        if (to == recipient) {
            if (mode == 0) _burn(to, 1); // Short recipient credit, but full payer debit.
            if (mode == 1) _mint(to, 1); // Excess recipient credit.
            if (mode == 2) _burn(0x000000000000000000000000000000000000dEaD, 1); // Disturb the first leg.
            if (mode == 3) _burn(to, amount + 1); // Recipient's balance decreases overall.
        }
        return true;
    }
}

contract ClubMintReceiver is IERC721Receiver {
    OGClubClubs public immutable clubs;
    uint256 public receivedId;
    bytes public reentryError;
    bool public reentered;
    bool public propagate;

    constructor(OGClubClubs clubs_) {
        clubs = clubs_;
    }

    function mint(uint256 pepeId, bool propagate_) external {
        propagate = propagate_;
        clubs.token().approve(address(clubs), 2 * clubs.price());
        clubs.mintClub(pepeId);
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        if (msg.sender != address(clubs)) return this.onERC721Received.selector;
        receivedId = id;
        if (propagate) clubs.mintClub(id + 1);
        (reentered, reentryError) = address(clubs).call(abi.encodeCall(clubs.mintClub, (id + 1)));
        return this.onERC721Received.selector;
    }
}

contract ClubsMintTest is ClubsTestBase {
    event ClubMinted(
        uint256 indexed id, address indexed to, address indexed payer, uint256 burned, uint256 toVault, uint256 pepeId
    );

    function test_IdentityInterfacesAndEmptyClub() public view {
        assertEq(clubs.name(), "OG Club Clubs");
        assertEq(clubs.symbol(), "OGCLUBS");
        assertEq(address(clubs.token()), address(token));
        assertEq(clubs.vault(), address(vault));
        assertEq(clubs.price(), PRICE);
        assertEq(address(clubs.furniture()), address(furniture));
        assertEq(clubs.BURN_ADDRESS(), 0x000000000000000000000000000000000000dEaD);
        assertEq(clubs.piecesOf(1).length, 0);
        assertEq(clubs.pieceCount(1), 0);
        assertFalse(clubs.tileTaken(1, 0, 4));
        assertFalse(clubs.tileTaken(1, 1, 4));
        assertTrue(clubs.supportsInterface(0x01ffc9a7)); // ERC165
        assertTrue(clubs.supportsInterface(0x80ac58cd)); // ERC721
        assertTrue(clubs.supportsInterface(0x5b5e139f)); // Metadata
        assertTrue(clubs.supportsInterface(0x780e9d63)); // Enumerable
        assertTrue(clubs.supportsInterface(0x2a55205a)); // Royalty
        assertTrue(clubs.supportsInterface(0x49064906)); // Metadata updates (not type(IERC4906).interfaceId)
        assertTrue(clubs.supportsInterface(0x4e2312e0)); // ERC1155Receiver
        assertFalse(clubs.supportsInterface(0xffffffff));
        assertFalse(clubs.supportsInterface(0xd9b67a26)); // Not an ERC1155 token
    }

    function test_ExactOddSplitMintEventsAndEnumerationThroughTransfers() public {
        uint256 beforeBob = token.balanceOf(bob);
        vm.expectEmit(true, true, true, true, address(clubs));
        emit ClubMinted(2, bob, bob, PRICE / 2, PRICE - PRICE / 2, 2);
        vm.prank(bob);
        assertEq(clubs.mintClub(2), 2);
        vm.prank(alice);
        assertEq(clubs.mintClub(3), 3);
        assertEq(token.balanceOf(bob), beforeBob - PRICE);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), 3 * (PRICE / 2));
        assertEq(token.balanceOf(address(vault)), 3 * (PRICE - PRICE / 2));
        assertEq(token.balanceOf(address(clubs)), 0);
        assertEq(clubs.totalSupply(), 3);
        vm.prank(bob);
        clubs.transferFrom(bob, alice, 2);
        assertEq(clubs.balanceOf(alice), 3);
        assertEq(clubs.balanceOf(bob), 0);
        assertEq(clubs.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(clubs.tokenOfOwnerByIndex(alice, 1), 3);
        assertEq(clubs.tokenOfOwnerByIndex(alice, 2), 2);
        for (uint256 i; i < 3; ++i) {
            assertEq(clubs.tokenByIndex(i), i + 1);
        }
    }

    function test_ClosedSaleAndNonHolder() public {
        clubs.setSaleOpen(false);
        vm.expectRevert(OGClubClubs.SaleClosed.selector);
        vm.prank(alice);
        clubs.mintClub(3);
        clubs.setSaleOpen(true);
        vm.expectRevert(OGClubClubs.NotPepeHolder.selector);
        vm.prank(alice);
        clubs.mintClub(2);
        assertEq(clubs.totalSupply(), 1);
        assertEq(token.balanceOf(address(clubs)), 0);
    }

    function test_ShortApprovalRollsBackFirstLeg() public {
        vm.prank(alice);
        token.approve(address(clubs), PRICE - 1);
        uint256 beforeBalance = token.balanceOf(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(clubs),
                PRICE - 1 - PRICE / 2,
                PRICE - PRICE / 2
            )
        );
        vm.prank(alice);
        clubs.mintClub(3);
        assertEq(token.balanceOf(alice), beforeBalance);
        assertEq(token.allowance(alice, address(clubs)), PRICE - 1);
        _assertOnlyInitialMint();
    }

    function test_ShortBalanceRollsBackFirstLeg() public {
        address short = makeAddr("short balance");
        fund(short, PRICE - 1);
        pepes.mint(short, 4);
        vm.prank(short);
        token.approve(address(clubs), PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, short, PRICE - 1 - PRICE / 2, PRICE - PRICE / 2
            )
        );
        vm.prank(short);
        clubs.mintClub(4);
        assertEq(token.balanceOf(short), PRICE - 1);
        _assertOnlyInitialMint();
    }

    function test_NonReceiverRollsBackPaymentAndPepeEligibility() public {
        vm.prank(alice);
        pepes.transferFrom(alice, address(furniture), 3);
        fund(address(furniture), PRICE);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(furniture)));
        vm.prank(address(furniture));
        clubs.mintClub(3);
        assertEq(token.balanceOf(address(furniture)), PRICE);
        assertEq(token.allowance(address(furniture), address(clubs)), PRICE);
        assertFalse(clubs.clubsMinted(3));
        _assertOnlyInitialMint();
        vm.prank(address(furniture));
        pepes.transferFrom(address(furniture), alice, 3);
        vm.prank(alice);
        assertEq(clubs.mintClub(3), 3);
    }

    function test_ReceiverCannotDoubleMintAndMayRejectAtomically() public {
        ClubMintReceiver receiver = new ClubMintReceiver(clubs);
        token.mint(address(receiver), 3 * PRICE);
        pepes.mint(address(receiver), 4);
        pepes.mint(address(receiver), 5);
        receiver.mint(4, false);
        assertFalse(receiver.reentered());
        assertEq(receiver.reentryError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(receiver.receivedId(), 4);
        assertEq(clubs.balanceOf(address(receiver)), 1);
        assertEq(clubs.totalSupply(), 2);
        assertEq(token.balanceOf(address(receiver)), 2 * PRICE);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        receiver.mint(5, true);
        assertEq(clubs.totalSupply(), 2);
        assertEq(token.balanceOf(address(receiver)), 2 * PRICE);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), 2 * (PRICE / 2));
    }

    function test_TaxedTokensAndFalseReturnsRevertAtomically() public {
        TestToken taxed = new TestToken(18);
        OGClubClubs target = new OGClubClubs(
            taxed,
            address(vault),
            10_001,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        target.setSaleOpen(true);
        taxed.mint(alice, 100_000);
        vm.prank(alice);
        taxed.approve(address(target), 100_000);
        for (uint256 senderFee; senderFee < 2; ++senderFee) {
            taxed.configureFee(100, senderFee != 0);
            vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
            vm.prank(alice);
            target.mintClub(1);
            assertEq(taxed.balanceOf(alice), 100_000);
            assertEq(taxed.balanceOf(target.BURN_ADDRESS()), 0);
            assertEq(taxed.balanceOf(address(vault)), 0);
            assertEq(taxed.allowance(alice, address(target)), 100_000);
            assertEq(target.totalSupply(), 0);
        }
        taxed.configureFalse(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(taxed)));
        vm.prank(alice);
        target.mintClub(1);
        assertEq(target.totalSupply(), 0);
    }

    function test_ZeroBurnAtPriceOneAndNoReturnToken() public {
        NoReturnToken noReturn = new NoReturnToken();
        OGClubClubs target = new OGClubClubs(
            IERC20(address(noReturn)),
            address(vault),
            1,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        target.setSaleOpen(true);
        noReturn.mint(alice, 1);
        vm.startPrank(alice);
        noReturn.approve(address(target), 1);
        assertEq(target.mintClub(1), 1);
        vm.stopPrank();
        assertEq(noReturn.balanceOf(target.BURN_ADDRESS()), 0);
        assertEq(noReturn.balanceOf(address(vault)), 1);
        assertEq(noReturn.balanceOf(address(target)), 0);
    }

    function test_TokenCallbackCannotReenterMintOrUpgrade() public {
        TestToken callback = new TestToken(18);
        OGClubClubs target = new OGClubClubs(
            callback,
            address(vault),
            10,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        target.setSaleOpen(true);
        callback.mint(alice, 20);
        vm.prank(alice);
        callback.approve(address(target), 20);
        callback.configureCallback(address(target), abi.encodeCall(target.mintClub, (1)));
        vm.prank(alice);
        target.mintClub(1);
        assertFalse(callback.callbackSucceeded());
        callback.configureCallback(address(target), abi.encodeCall(target.upgradeClub, (1)));
        vm.prank(alice);
        target.mintClub(3);
        assertFalse(callback.callbackSucceeded());
        assertEq(target.totalSupply(), 2);
    }

    function test_SecondRecipientAndFinalFirstRecipientBalancesMustBothMatch() public {
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
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        target.setSaleOpen(true);
        adversary.mint(alice, 1000);
        adversary.mint(address(vault), 100);
        adversary.mint(target.BURN_ADDRESS(), 100);
        vm.prank(alice);
        adversary.approve(address(target), 1000);
        for (uint8 mode; mode < 4; ++mode) {
            adversary.configure(address(vault), mode);
            vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
            vm.prank(alice);
            target.mintClub(1);
            assertEq(adversary.balanceOf(alice), 1000);
            assertEq(adversary.balanceOf(address(vault)), 100);
            assertEq(adversary.balanceOf(target.BURN_ADDRESS()), 100);
            assertEq(adversary.balanceOf(address(target)), 0);
            assertEq(adversary.allowance(alice, address(target)), 1000);
            assertEq(target.totalSupply(), 0);
        }
    }

    function test_BurnSinkCannotAlsoBeVaultAndPayerCannotPayItself() public {
        address burnSink = clubs.BURN_ADDRESS();
        vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
        new OGClubClubs(
            token,
            burnSink,
            10,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        OGClubClubs target = new OGClubClubs(
            token,
            alice,
            10,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        target.setSaleOpen(true);
        vm.prank(alice);
        token.approve(address(target), 10);
        vm.expectRevert(OGClubClubs.UnexpectedTokenDebit.selector);
        vm.prank(alice);
        target.mintClub(1);
        _assertOnlyInitialMint();
    }

    function testFuzz_PaymentConservation(uint128 priceSeed, uint8 mintSeed) public {
        uint256 price = bound(priceSeed, 1, type(uint128).max);
        uint256 mints = bound(mintSeed, 1, 20);
        OGClubClubs target = new OGClubClubs(
            token,
            address(vault),
            price,
            IERC1155(address(furniture)),
            address(this),
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        target.setSaleOpen(true);
        token.mint(alice, price * mints);
        uint256 burnBefore = token.balanceOf(target.BURN_ADDRESS());
        uint256 vaultBefore = token.balanceOf(address(vault));
        vm.startPrank(alice);
        token.approve(address(target), price * mints);
        for (uint256 i; i < mints; ++i) {
            pepes.mint(alice, i + 100);
            assertEq(target.mintClub(i + 100), i + 100);
        }
        vm.stopPrank();
        uint256 burned = token.balanceOf(target.BURN_ADDRESS()) - burnBefore;
        uint256 toVault = token.balanceOf(address(vault)) - vaultBefore;
        assertEq(burned, price / 2 * mints);
        assertEq(toVault, (price - price / 2) * mints);
        assertEq(burned + toVault, price * mints);
        assertEq(token.balanceOf(address(target)), 0);
    }

    function _assertOnlyInitialMint() private view {
        assertEq(clubs.totalSupply(), 1);
        assertEq(token.balanceOf(clubs.BURN_ADDRESS()), PRICE / 2);
        assertEq(token.balanceOf(address(vault)), PRICE - PRICE / 2);
        assertEq(token.balanceOf(address(clubs)), 0);
    }
}

contract ClubsAdminTest is ClubsTestBase {
    event BatchMetadataUpdate(uint256 fromTokenId, uint256 toTokenId);

    function test_MetadataFreezeIsPermanentButPlacementsContinue() public {
        assertEq(clubs.tokenURI(1), "1.json");
        vm.expectEmit(false, false, false, true, address(clubs));
        emit BatchMetadataUpdate(0, type(uint256).max);
        clubs.setBaseURI("ipfs://clubs/");
        assertEq(clubs.tokenURI(1), "ipfs://clubs/1.json");
        vm.expectEmit(false, false, false, true, address(clubs));
        emit BatchMetadataUpdate(0, type(uint256).max);
        clubs.freezeMetadata();
        assertTrue(clubs.metadataFrozen());
        vm.expectRevert(OGClubClubs.MetadataFrozen.selector);
        clubs.setBaseURI("replacement/");
        vm.expectRevert(OGClubClubs.MetadataFrozen.selector);
        clubs.freezeMetadata();
        place(alice, 1, 1, 0, 0, 0);
        assertEq(clubs.pieceCount(1), 1);
        vm.prank(alice);
        clubs.mintClub(3);
        assertEq(clubs.tokenURI(3), "ipfs://clubs/3.json");
    }

    function test_MissingTokensRevertInAllClubViews() public {
        for (uint256 id; id < 3; id += 2) {
            vm.expectRevert(OGClubClubs.NonexistentToken.selector);
            clubs.tokenURI(id);
            vm.expectRevert(OGClubClubs.NonexistentToken.selector);
            clubs.piecesOf(id);
            vm.expectRevert(OGClubClubs.NonexistentToken.selector);
            clubs.pieceCount(id);
            vm.expectRevert(OGClubClubs.NonexistentToken.selector);
            clubs.tileTaken(id, 0, 0);
        }
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.tileTaken(1, 10, 0);
        vm.expectRevert(OGClubClubs.OutOfRoom.selector);
        clubs.tileTaken(1, 0, 255);
    }

    function test_RoyaltyBoundsAndReceiver() public {
        (address receiver, uint256 amount) = clubs.royaltyInfo(1, 10_000);
        assertEq(receiver, royalty);
        assertEq(amount, 500);
        clubs.setRoyalty(bob, 1000);
        (receiver, amount) = clubs.royaltyInfo(1, 101);
        assertEq(receiver, bob);
        assertEq(amount, 10);
        vm.expectRevert(OGClubClubs.RoyaltyTooHigh.selector);
        clubs.setRoyalty(bob, 1001);
        vm.expectRevert(OGClubClubs.ZeroAddress.selector);
        clubs.setRoyalty(address(0), 500);
        clubs.setRoyalty(bob, 0);
        (, amount) = clubs.royaltyInfo(1, 10_000);
        assertEq(amount, 0);
    }

    function test_AllAdminFunctionsRequireOwner() public {
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(clubs.setSaleOpen, (false));
        calls[1] = abi.encodeCall(clubs.setFootprint, (1, 4, 4, false));
        calls[2] = abi.encodeCall(clubs.setBaseURI, ("x"));
        calls[3] = abi.encodeCall(clubs.freezeMetadata, ());
        calls[4] = abi.encodeCall(clubs.setRoyalty, (alice, 0));
        calls[5] = abi.encodeCall(clubs.transferOwnership, (alice));
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok, bytes memory reason) = address(clubs).call(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        }
    }

    function test_TwoStepOwnershipRetainsAllPermanentState() public {
        clubs.freezeMetadata();
        place(alice, 1, 1, 0, 0, 0);
        clubs.transferOwnership(bob);
        assertEq(clubs.owner(), address(this));
        assertEq(clubs.pendingOwner(), bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        clubs.acceptOwnership();
        vm.prank(bob);
        clubs.acceptOwnership();
        assertEq(clubs.owner(), bob);
        assertEq(clubs.pendingOwner(), address(0));
        vm.expectRevert(OGClubClubs.MetadataFrozen.selector);
        vm.prank(bob);
        clubs.setBaseURI("changed/");
        vm.expectRevert(OGClubClubs.FootprintLocked.selector);
        vm.prank(bob);
        clubs.setFootprint(1, 2, 2, false);
        vm.prank(bob);
        clubs.setSaleOpen(false);
        assertFalse(clubs.saleOpen());
        assertEq(clubs.pieceCount(1), 1);
    }

    function test_OwnerCannotMintFreeSeizeBurnOrWithdraw() public {
        vm.expectRevert();
        clubs.mintClub(2);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(this), 1));
        clubs.transferFrom(alice, bob, 1);
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[1] = abi.encodeWithSignature("mint(address,uint256)", bob, 2);
        calls[2] = abi.encodeWithSignature("withdraw()");
        calls[3] = abi.encodeWithSignature("setPrice(uint256)", 1);
        calls[4] = abi.encodeWithSignature("setVault(address)", bob);
        calls[5] = abi.encodeWithSignature("setToken(address)", bob);
        calls[6] = abi.encodeWithSignature("setFurniture(address)", bob);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(clubs).call(calls[i]);
            assertFalse(ok);
        }
        (bool acceptsETH,) = address(clubs).call{value: 1}("");
        assertFalse(acceptsETH);
        assertEq(clubs.ownerOf(1), alice);
        assertEq(clubs.totalSupply(), 1);
    }

    function test_ConstructorRejectsEveryZeroValueAndStartsClosed() public {
        for (uint256 i; i < 6; ++i) {
            vm.expectRevert(i == 2 ? OGClubClubs.ZeroPrice.selector : OGClubClubs.ZeroAddress.selector);
            new OGClubClubs(
                i == 0 ? IERC20(address(0)) : token,
                i == 1 ? address(0) : address(vault),
                i == 2 ? 0 : PRICE,
                i == 3 ? IERC1155(address(0)) : IERC1155(address(furniture)),
                i == 4 ? address(0) : address(this),
                i == 5 ? address(0) : royalty,
                pepes,
                delegates,
                _upgradePrices()[0],
                _upgradePrices()[1],
                _upgradePrices()[2]
            );
        }
        OGClubClubs fresh = new OGClubClubs(
            token,
            address(vault),
            PRICE,
            IERC1155(address(furniture)),
            bob,
            royalty,
            pepes,
            delegates,
            _upgradePrices()[0],
            _upgradePrices()[1],
            _upgradePrices()[2]
        );
        assertFalse(fresh.saleOpen());
        assertEq(fresh.owner(), bob);
        assertEq(fresh.totalSupply(), 0);
    }
}
