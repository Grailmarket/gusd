// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Mock imports
import {GrailDollarMock} from "../mocks/GrailDollarMock.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {OFTComposerMock} from "../mocks/OFTComposerMock.sol";

// OApp imports
import {
    IOAppOptionsType3, EnforcedOptionParam
} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

// OFT imports
import {IOFT, SendParam, OFTReceipt} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import {OFTMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";

// OZ imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Forge imports
import "forge-std/console.sol";

// Library imports
import {Currency} from "../../contracts/libraries/Currency.sol";

// DevTools imports
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

contract GrailDollarTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint256 public constant MAX_INT = 2 ** 256 - 1;

    uint32 private aEid = 1;
    uint32 private bEid = 2;

    ERC20Mock private USDC;
    ERC20Mock private USDT;

    GrailDollarMock private aGUSD;
    GrailDollarMock private bGUSD;

    address private userA = makeAddr("userA");
    address private userB = makeAddr("userB");
    uint256 private initialBalance = 100 * 10 ** 6;

    address private minterA = makeAddr("minterA");
    address private minterB = makeAddr("minterB");

    event SetProtocolFee(uint16 newFee);
    event Mint(address indexed account, uint256 amount);
    event Redeem(address indexed account, uint256 amount);
    event CreditedTo(address indexed account, uint256 amount);
    event DebitedFrom(address indexed account, uint256 amount);
    event CollectFee(address indexed collector, address indexed recipient, uint256 amount);

    error InvalidAmount();
    error PeerExist();
    error FeeTooLarge(uint16 fee);
    error InsufficientLiquidity();
    error OnlyMinterAllowed();
    error CannotRecoverCurrency();
    error ERC20TransferFromFailed();
    error AmountExceedsAccruedFee();
    error OwnableUnauthorizedAccount(address owner);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        USDC = new ERC20Mock("USDC", "USDC", 6);
        USDT = new ERC20Mock("Tether", "USDT", 18);

        aGUSD = GrailDollarMock(
            _deployOApp(
                type(GrailDollarMock).creationCode,
                abi.encode(address(USDC), minterA, address(endpoints[aEid]), address(this))
            )
        );

        bGUSD = GrailDollarMock(
            _deployOApp(
                type(GrailDollarMock).creationCode,
                abi.encode(address(USDT), minterB, address(endpoints[bEid]), address(this))
            )
        );

        // config and wire the ofts
        address[] memory ofts = new address[](2);
        ofts[0] = address(aGUSD);
        ofts[1] = address(bGUSD);
        this.wireOApps(ofts);

        // mint tokens
        // aGUSD.mint(userA, initialBalance);
        // bGUSD.mint(userB, initialBalance);
    }

    function test_constructor() public view {
        assertEq(aGUSD.owner(), address(this));
        assertEq(bGUSD.owner(), address(this));

        assertEq(aGUSD.token(), address(aGUSD));
        assertEq(bGUSD.token(), address(bGUSD));

        assertEq(aGUSD.minter(), minterA);
        assertEq(bGUSD.minter(), minterB);

        assertEq(Currency.unwrap(aGUSD.currency()), address(USDC));
        assertEq(Currency.unwrap(bGUSD.currency()), address(USDT));

        assertEq(aGUSD.gusdConversionRate(), 100);
        assertEq(bGUSD.gusdConversionRate(), 100);

        assertEq(aGUSD.protocolFeeBps(), 300);
        assertEq(bGUSD.protocolFeeBps(), 300);

        assertEq(aGUSD.currencyConversionRate(), 1);
        assertEq(bGUSD.currencyConversionRate(), 10 ** 12);
    }

    function test_send_oft() public {
        uint256 tokensToSend = 10 * 10 ** 6;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam =
            SendParam(bEid, addressToBytes32(userB), tokensToSend, tokensToSend, options, "", "");
        MessagingFee memory fee = aGUSD.quoteSend(sendParam, false);

        aGUSD.mint(userA, initialBalance);
        bGUSD.mint(userB, initialBalance);
        assertEq(aGUSD.balanceOf(userA), initialBalance);
        assertEq(bGUSD.balanceOf(userB), initialBalance);

        vm.prank(userA);
        aGUSD.send{value: fee.nativeFee}(sendParam, fee, payable(address(this)));
        verifyPackets(bEid, addressToBytes32(address(bGUSD)));

        assertEq(aGUSD.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(bGUSD.balanceOf(userB), initialBalance + tokensToSend);
    }

    function test_send_oft_compose_msg() public {
        uint256 tokensToSend = 15 * 10 ** 6;

        OFTComposerMock composer = new OFTComposerMock();

        bytes memory options =
            OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0).addExecutorLzComposeOption(0, 500000, 0);
        bytes memory composeMsg = hex"1234";
        SendParam memory sendParam =
            SendParam(bEid, addressToBytes32(address(composer)), tokensToSend, tokensToSend, options, composeMsg, "");
        MessagingFee memory fee = aGUSD.quoteSend(sendParam, false);

        aGUSD.mint(userA, initialBalance);
        bGUSD.mint(userB, initialBalance);
        assertEq(aGUSD.balanceOf(userA), initialBalance);
        assertEq(bGUSD.balanceOf(address(composer)), 0);

        vm.prank(userA);
        (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) =
            aGUSD.send{value: fee.nativeFee}(sendParam, fee, payable(address(this)));
        verifyPackets(bEid, addressToBytes32(address(bGUSD)));

        // lzCompose params
        uint32 dstEid_ = bEid;
        address from_ = address(bGUSD);
        bytes memory options_ = options;
        bytes32 guid_ = msgReceipt.guid;
        address to_ = address(composer);
        bytes memory composerMsg_ = OFTComposeMsgCodec.encode(
            msgReceipt.nonce, aEid, oftReceipt.amountReceivedLD, abi.encodePacked(addressToBytes32(userA), composeMsg)
        );
        this.lzCompose(dstEid_, from_, options_, guid_, to_, composerMsg_);

        assertEq(aGUSD.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(bGUSD.balanceOf(address(composer)), tokensToSend);

        assertEq(composer.from(), from_);
        assertEq(composer.guid(), guid_);
        assertEq(composer.message(), composerMsg_);
        assertEq(composer.executor(), address(this));
        assertEq(composer.extraData(), composerMsg_); // default to setting the extraData to the message as well to test
    }

    function test_mint_with_USDC_succeeds() public {
        uint256 lotAmount = 1_000 * 10 ** 6;
        uint256 mintingPrice = 10 * 10 ** 6;
        uint256 protocolFee = mintingPrice * 300 / 10_000;
        USDC.mint(userA, 100 * 10 ** 6);
        uint256 balanceBefore = USDC.balanceOf(userA);
        // uint256 mintPrice = 10
        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        vm.expectEmit();
        emit Mint(userA, lotAmount);
        aGUSD.mint();
        vm.stopPrank();

        assertEq(USDC.balanceOf(userA), balanceBefore - (mintingPrice + protocolFee));
        assertEq(aGUSD.balanceOf(userA), lotAmount);
        assertEq(aGUSD.protocolFeesAccrued(), protocolFee);
    }

    function test_mint_with_USDT_succeeds() public {
        uint256 lotAmount = 1_000 * 10 ** 6;
        uint256 mintingPrice = 10 * 10 ** 18;
        uint256 protocolFee = mintingPrice * 300 / 10_000;
        USDT.mint(userA, 100 * 10 ** 18);
        uint256 balanceBefore = USDT.balanceOf(userA);

        vm.startPrank(userA);
        USDT.approve(address(bGUSD), MAX_INT);

        vm.expectEmit();
        emit Mint(userA, lotAmount);
        bGUSD.mint();
        vm.stopPrank();

        assertEq(USDT.balanceOf(userA), balanceBefore - (mintingPrice + protocolFee));
        assertEq(bGUSD.balanceOf(userA), lotAmount);
        assertEq(bGUSD.protocolFeesAccrued(), protocolFee);
    }

    function test_mint_reverts_if_insufficient_user_balance() public {
        USDC.mint(userA, 9 * 10 ** 6);
        uint256 balanceBefore = USDC.balanceOf(userA);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        vm.expectRevert(ERC20TransferFromFailed.selector);
        aGUSD.mint();
        vm.stopPrank();

        assertEq(USDC.balanceOf(userA), balanceBefore);
        assertEq(aGUSD.balanceOf(userA), 0);
    }

    function test_mint_reverts_if_no_approval_granted() public {
        USDC.mint(userA, 100 * 10 ** 6);
        uint256 balanceBefore = USDC.balanceOf(userA);

        vm.startPrank(userA);
        vm.expectRevert(ERC20TransferFromFailed.selector);
        aGUSD.mint();
        vm.stopPrank();

        assertEq(USDC.balanceOf(userA), balanceBefore);
        assertEq(aGUSD.balanceOf(userA), 0);
    }

    function test_redeem_with_USDC_succeeds() public {
        uint256 LIQUIDITY = 1_000 * 10 ** 6;
        uint256 REDEEM_GUSD_AMOUNT = 25_000 * 10 ** 6;
        uint256 USDC_REDEEMED = 250 * 10 ** 6;

        USDC.mint(address(aGUSD), LIQUIDITY);
        aGUSD.mint(userA, REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(userA), 0);

        vm.prank(userA);
        vm.expectEmit();
        emit Redeem(userA, REDEEM_GUSD_AMOUNT);
        aGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(address(aGUSD)), LIQUIDITY - USDC_REDEEMED);
        assertEq(USDC.balanceOf(userA), USDC_REDEEMED);
    }

    function test_redeem_reverts_when_amount_zero() public {
        uint256 LIQUIDITY = 1_000 * 10 ** 6;
        uint256 REDEEM_GUSD_AMOUNT = 0;

        USDC.mint(address(aGUSD), LIQUIDITY);

        vm.prank(userA);
        vm.expectRevert(InvalidAmount.selector);
        aGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(address(aGUSD)), LIQUIDITY);
        assertEq(USDC.balanceOf(userA), 0);
    }

    function test_redeem_reverts_when_amount_less_than_conversion_rate() public {
        uint256 LIQUIDITY = 1_000 * 10 ** 6;
        uint256 REDEEM_GUSD_AMOUNT = 10;

        USDC.mint(address(aGUSD), LIQUIDITY);

        vm.prank(userA);
        vm.expectRevert(InvalidAmount.selector);
        aGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(address(aGUSD)), LIQUIDITY);
        assertEq(USDC.balanceOf(userA), 0);
    }

    function test_redeem_reverts_when_insufficient_liquidity() public {
        uint256 LIQUIDITY = 100 * 10 ** 6;
        uint256 REDEEM_GUSD_AMOUNT = 25_000 * 10 ** 6;

        USDC.mint(address(aGUSD), LIQUIDITY);

        vm.prank(userA);
        vm.expectRevert(InsufficientLiquidity.selector);
        aGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(address(aGUSD)), LIQUIDITY);
        assertEq(USDC.balanceOf(userA), 0);
    }

    function test_redeem_reverts_when_user_has_insufficient_balance() public {
        uint256 LIQUIDITY = 1_000 * 10 ** 6;
        uint256 REDEEM_GUSD_AMOUNT = 25_000 * 10 ** 6;

        USDC.mint(address(aGUSD), LIQUIDITY);

        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(ERC20InsufficientBalance.selector, userA, 0, REDEEM_GUSD_AMOUNT));
        aGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(address(aGUSD)), LIQUIDITY);
        assertEq(USDC.balanceOf(userA), 0);
    }

    function test_redeem_with_USDT_succeeds() public {
        uint256 LIQUIDITY = 1_000 * 10 ** 18;
        uint256 REDEEM_GUSD_AMOUNT = 25_000 * 10 ** 6;
        uint256 USDT_REDEEMED = 250 * 10 ** 18;

        USDT.mint(address(bGUSD), LIQUIDITY);
        bGUSD.mint(userA, REDEEM_GUSD_AMOUNT);

        assertEq(USDT.balanceOf(userA), 0);

        vm.prank(userA);
        vm.expectEmit();
        emit Redeem(userA, REDEEM_GUSD_AMOUNT);
        bGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDT.balanceOf(address(bGUSD)), LIQUIDITY - USDT_REDEEMED);
        assertEq(USDT.balanceOf(userA), USDT_REDEEMED);
    }

    function test_creditTo_succeeds() public {
        uint256 amount = 100 * 10 ** 6;

        vm.prank(minterA);
        vm.expectEmit();
        emit CreditedTo(userA, amount);
        aGUSD.creditTo(userA, amount);

        assertEq(aGUSD.balanceOf(userA), amount);
    }

    function test_creditTo_reverts_when_caller_not_minter() public {
        uint256 amount = 100 * 10 ** 6;

        vm.prank(userB);
        vm.expectRevert(OnlyMinterAllowed.selector);
        aGUSD.creditTo(userA, amount);

        assertEq(aGUSD.balanceOf(userA), 0);
    }

    function test_debitFrom_succeeds() public {
        uint256 amount = 100 * 10 ** 6;
        aGUSD.mint(userA, amount);
        uint256 balanceBefore = aGUSD.balanceOf(userA);

        vm.prank(minterA);
        vm.expectEmit();
        emit DebitedFrom(userA, amount);
        aGUSD.debitFrom(userA, amount);

        assertEq(aGUSD.balanceOf(userA), balanceBefore - amount);
    }

    function test_debitFrom_reverts_when_caller_not_minter() public {
        uint256 amount = 100 * 10 ** 6;

        vm.prank(userB);
        vm.expectRevert(OnlyMinterAllowed.selector);
        aGUSD.debitFrom(userA, amount);

        assertEq(aGUSD.balanceOf(userA), 0);
    }

    function test_recoverToken_specific_amount_succeeds() public {
        uint256 lostAmount = 100 * 10 ** 18;
        uint256 recoveredAmount = 90 * 10 ** 18;
        USDT.mint(userA, lostAmount);

        vm.prank(userA);
        USDT.transfer(address(aGUSD), lostAmount);

        assertEq(USDT.balanceOf(address(aGUSD)), lostAmount);

        uint256 balanceOfUserB = USDT.balanceOf(userB);
        vm.prank(aGUSD.owner()); // not necessary
        aGUSD.recoverToken(Currency.wrap(address(USDT)), userB, recoveredAmount);

        assertEq(USDT.balanceOf(userB), balanceOfUserB + recoveredAmount);
    }

    function test_recoverToken_all_balance_succeeds() public {
        uint256 amount = 100 * 10 ** 18;
        USDT.mint(userA, amount);

        vm.prank(userA);
        USDT.transfer(address(aGUSD), amount);

        assertEq(USDT.balanceOf(address(aGUSD)), amount);

        uint256 balanceOfUserB = USDT.balanceOf(userB);
        vm.prank(aGUSD.owner()); // not necessary
        aGUSD.recoverToken(Currency.wrap(address(USDT)), userB, 0);

        assertEq(USDT.balanceOf(userB), balanceOfUserB + amount);
    }

    function test_recoverToken_reverts_when_caller_not_authorized() public {
        uint256 amount = 100 * 10 ** 18;
        USDT.mint(userA, amount);

        vm.prank(userA);
        USDT.transfer(address(aGUSD), amount);

        assertEq(USDT.balanceOf(address(aGUSD)), amount);

        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, userA)); // Unauthorized error
        vm.prank(userA);
        aGUSD.recoverToken(Currency.wrap(address(USDT)), userB, 0);

        assertEq(USDT.balanceOf(userB), 0);
    }

    function test_collectProtocolFees_succeeds() public {
        uint256 numOfMints = 5;
        uint256 mintingPrice = 10 * 10 ** 6;
        uint256 protocolFee = mintingPrice * 300 / 10_000;
        USDC.mint(userA, 1000 * 10 ** 6);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        for (uint256 i = 0; i < numOfMints; i++) {
            aGUSD.mint();
        }

        vm.stopPrank();

        uint256 amount = protocolFee * 3;
        uint256 userBBalanceBefore = USDC.balanceOf(userB);
        uint256 accruedFee = protocolFee * numOfMints;

        assertEq(aGUSD.protocolFeesAccrued(), accruedFee);
        vm.prank(aGUSD.owner());
        vm.expectEmit();
        emit CollectFee(aGUSD.owner(), userB, amount);
        aGUSD.collectProtocolFee(userB, amount);

        assertEq(USDC.balanceOf(userB), userBBalanceBefore + amount);
        assertEq(aGUSD.protocolFeesAccrued(), accruedFee - amount);
    }

    function test_collectProtocolFees_reverts_when_amount_exceeds_accrued_fee() public {
        uint256 numOfMints = 5;
        uint256 mintingPrice = 10 * 10 ** 6;
        uint256 protocolFee = mintingPrice * 300 / 10_000;
        USDC.mint(userA, 1000 * 10 ** 6);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        for (uint256 i = 0; i < numOfMints; i++) {
            aGUSD.mint();
        }

        vm.stopPrank();

        uint256 amount = protocolFee * 30;
        uint256 userBBalanceBefore = USDC.balanceOf(userB);
        uint256 accruedFee = protocolFee * numOfMints;

        assertEq(aGUSD.protocolFeesAccrued(), accruedFee);
        vm.prank(aGUSD.owner()); // not necessary
        vm.expectRevert(AmountExceedsAccruedFee.selector);
        aGUSD.collectProtocolFee(userB, amount);

        assertEq(USDC.balanceOf(userB), userBBalanceBefore);
        assertEq(aGUSD.protocolFeesAccrued(), accruedFee);
    }

    function test_collectProtocolFees_reverts_when_caller_not_owner() public {
        uint256 numOfMints = 5;
        uint256 mintingPrice = 10 * 10 ** 6;
        uint256 protocolFee = mintingPrice * 300 / 10_000;
        USDC.mint(userA, 1000 * 10 ** 6);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        for (uint256 i = 0; i < numOfMints; i++) {
            aGUSD.mint();
        }

        vm.stopPrank();

        uint256 amount = protocolFee * 3;
        uint256 userBBalanceBefore = USDC.balanceOf(userB);
        uint256 accruedFee = protocolFee * numOfMints;

        assertEq(aGUSD.protocolFeesAccrued(), accruedFee);
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, userA));
        aGUSD.collectProtocolFee(userB, amount);

        assertEq(USDC.balanceOf(userB), userBBalanceBefore);
        assertEq(aGUSD.protocolFeesAccrued(), accruedFee);
    }

    function test_setProtocolFee_succeeds() public {
        assertEq(aGUSD.protocolFeeBps(), 300);

        vm.expectEmit();
        emit SetProtocolFee(500);
        aGUSD.setProtocolFee(500);

        assertEq(aGUSD.protocolFeeBps(), 500);
    }

    function test_setProtocolFee_reverts_when_fee_exceeds_max_allowed() public {
        assertEq(aGUSD.protocolFeeBps(), 300);
        uint16 fee = 1_500;

        vm.expectRevert(abi.encodeWithSelector(FeeTooLarge.selector, fee));
        aGUSD.setProtocolFee(fee);

        assertEq(aGUSD.protocolFeeBps(), 300);
    }

    function test_setProtocolFee_reverts_when_caller_not_owner() public {
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, userA));
        aGUSD.setProtocolFee(500);

        assertEq(aGUSD.protocolFeeBps(), 300);
    }
}
