// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Mock imports
import {GUSDMock} from "../mocks/GUSDMock.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IGUSD} from "../../contracts/interfaces/IGUSD.sol";

// OApp imports
import {
    IOAppOptionsType3, EnforcedOptionParam
} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MessagingFee, Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

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

    GUSDMock private aGUSD;
    GUSDMock private bGUSD;

    address private userA = makeAddr("userA");
    address private userB = makeAddr("userB");
    address private owner = makeAddr("owner");
    uint256 private initialBalance = 100 * 10 ** 6;

    address private minterA = makeAddr("minterA");
    address private minterB = makeAddr("minterB");

    error ERC20TransferFromFailed();
    error OwnableUnauthorizedAccount(address owner);
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);

    function setUp() public virtual override {
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);
        vm.deal(owner, 1000 ether);

        super.setUp();
        setUpEndpoints(6, LibraryType.UltraLightNode);

        USDC = new ERC20Mock("USDC", "USDC", 6);
        USDT = new ERC20Mock("Tether", "USDT", 18);

        aGUSD = GUSDMock(
            _deployOApp(
                type(GUSDMock).creationCode,
                abi.encode(owner, Currency.wrap(address(USDC)), minterA, aEid, address(endpoints[aEid]))
            )
        );

        bGUSD = GUSDMock(
            _deployOApp(
                type(GUSDMock).creationCode,
                abi.encode(owner, Currency.wrap(address(USDT)), minterB, aEid, address(endpoints[bEid]))
            )
        );

        aGUSD.addPeer(bEid, addressToBytes32(address(bGUSD)));
        bGUSD.addPeer(aEid, addressToBytes32(address(aGUSD)));
        vm.deal(address(aGUSD), 1000 ether);
    }

    function test_constructor() public view {
        assertEq(aGUSD.owner(), owner);
        assertEq(bGUSD.owner(), owner);

        assertEq(aGUSD.minter(), minterA);
        assertEq(bGUSD.minter(), minterB);

        assertEq(Currency.unwrap(aGUSD.currency()), address(USDC));
        assertEq(Currency.unwrap(bGUSD.currency()), address(USDT));

        assertEq(aGUSD.GUSD_CONVERSION_RATE(), 100);
        assertEq(bGUSD.GUSD_CONVERSION_RATE(), 100);

        assertEq(aGUSD.mintFeeBps(), 300);
        assertEq(bGUSD.mintFeeBps(), 300);

        assertEq(aGUSD.mintPrice(), 10e6);
        assertEq(bGUSD.mintPrice(), 10e18);

        assertEq(aGUSD.governanceEid(), 1);
        assertEq(bGUSD.governanceEid(), 1);

        assertEq(aGUSD.decimalConversionRate(), 1);
        assertEq(bGUSD.decimalConversionRate(), 10 ** 12);

        assertEq(address(aGUSD.endpoint()), address(endpoints[aEid]));
        assertEq(address(bGUSD.endpoint()), address(endpoints[bEid]));
    }

    function bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    function test_send_oft() public {
        uint256 tokensToSend = 10 * 10 ** 6;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        IGUSD.SendParam memory sendParam = IGUSD.SendParam(bEid, addressToBytes32(userB), tokensToSend, options);
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

    function test_mint_with_USDC_succeeds() public {
        uint256 lotAmount = 1_000 * 10 ** 6;
        uint256 mintingPrice = 10 * 10 ** 6;
        uint256 mintFee = mintingPrice * 300 / 10_000;
        USDC.mint(userA, 100 * 10 ** 6);
        uint256 balanceBefore = USDC.balanceOf(userA);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        vm.expectEmit();
        emit IGUSD.Mint(userA, lotAmount, 1, mintingPrice + mintFee);
        aGUSD.mint(1);
        vm.stopPrank();

        assertEq(USDC.balanceOf(userA), balanceBefore - (mintingPrice + mintFee));
        assertEq(aGUSD.balanceOf(userA), lotAmount);
        assertEq(aGUSD.mintFeesAccrued(), mintFee);
    }

    function test_mint_with_USDT_succeeds() public {
        uint256 lotAmount = 1_000 * 10 ** 6;
        uint256 mintingPrice = 10 * 10 ** 18;
        uint256 mintFee = mintingPrice * 300 / 10_000;
        USDT.mint(userA, 100 * 10 ** 18);
        uint256 balanceBefore = USDT.balanceOf(userA);

        vm.startPrank(userA);
        USDT.approve(address(bGUSD), MAX_INT);

        vm.expectEmit();
        emit IGUSD.Mint(userA, lotAmount, 1, mintingPrice + mintFee);
        bGUSD.mint(1);
        vm.stopPrank();

        assertEq(USDT.balanceOf(userA), balanceBefore - (mintingPrice + mintFee));
        assertEq(bGUSD.balanceOf(userA), lotAmount);
        assertEq(bGUSD.mintFeesAccrued(), mintFee);
    }

    function test_mint_reverts_if_insufficient_user_balance() public {
        USDC.mint(userA, 9 * 10 ** 6);
        uint256 balanceBefore = USDC.balanceOf(userA);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        vm.expectRevert(ERC20TransferFromFailed.selector);
        aGUSD.mint(1);
        vm.stopPrank();

        assertEq(USDC.balanceOf(userA), balanceBefore);
        assertEq(aGUSD.balanceOf(userA), 0);
    }

    function test_mint_reverts_if_no_approval_granted() public {
        USDC.mint(userA, 100 * 10 ** 6);
        uint256 balanceBefore = USDC.balanceOf(userA);

        vm.prank(userA);
        vm.expectRevert(ERC20TransferFromFailed.selector);
        aGUSD.mint(1);

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
        emit IGUSD.Redeem(userA, REDEEM_GUSD_AMOUNT, USDC_REDEEMED);
        aGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(address(aGUSD)), LIQUIDITY - USDC_REDEEMED);
        assertEq(USDC.balanceOf(userA), USDC_REDEEMED);
    }

    function test_redeem_reverts_when_amount_zero() public {
        uint256 LIQUIDITY = 1_000 * 10 ** 6;
        uint256 REDEEM_GUSD_AMOUNT = 0;

        USDC.mint(address(aGUSD), LIQUIDITY);

        vm.prank(userA);
        vm.expectRevert(IGUSD.InvalidAmount.selector);
        aGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(address(aGUSD)), LIQUIDITY);
        assertEq(USDC.balanceOf(userA), 0);
    }

    function test_redeem_reverts_when_amount_less_than_conversion_rate() public {
        uint256 LIQUIDITY = 1_000 * 10 ** 6;
        uint256 REDEEM_GUSD_AMOUNT = 10;

        USDC.mint(address(aGUSD), LIQUIDITY);

        vm.prank(userA);
        vm.expectRevert(IGUSD.InvalidAmount.selector);
        aGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDC.balanceOf(address(aGUSD)), LIQUIDITY);
        assertEq(USDC.balanceOf(userA), 0);
    }

    function test_redeem_reverts_when_insufficient_liquidity() public {
        uint256 LIQUIDITY = 100 * 10 ** 6;
        uint256 REDEEM_GUSD_AMOUNT = 25_000 * 10 ** 6;

        USDC.mint(address(aGUSD), LIQUIDITY);

        vm.prank(userA);
        vm.expectRevert(IGUSD.InsufficientLiquidity.selector);
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
        emit IGUSD.Redeem(userA, REDEEM_GUSD_AMOUNT, USDT_REDEEMED);
        bGUSD.redeem(REDEEM_GUSD_AMOUNT);

        assertEq(USDT.balanceOf(address(bGUSD)), LIQUIDITY - USDT_REDEEMED);
        assertEq(USDT.balanceOf(userA), USDT_REDEEMED);
    }

    function test_credit_succeeds() public {
        uint256 amount = 100 * 10 ** 6;

        vm.prank(minterA);
        vm.expectEmit();
        emit IGUSD.Credit(userA, amount);
        aGUSD.credit(userA, amount);

        assertEq(aGUSD.balanceOf(userA), amount);
    }

    function test_credit_reverts_when_caller_not_minter() public {
        uint256 amount = 100 * 10 ** 6;

        vm.prank(userB);
        vm.expectRevert(IGUSD.OnlyMinterAllowed.selector);
        aGUSD.credit(userA, amount);

        assertEq(aGUSD.balanceOf(userA), 0);
    }

    function test_debit_succeeds() public {
        uint256 amount = 100 * 10 ** 6;
        aGUSD.mint(userA, amount);
        uint256 balanceBefore = aGUSD.balanceOf(userA);

        vm.prank(minterA);
        vm.expectEmit();
        emit IGUSD.Debit(userA, amount);
        aGUSD.debit(userA, amount);

        assertEq(aGUSD.balanceOf(userA), balanceBefore - amount);
    }

    function test_debit_reverts_when_caller_not_minter() public {
        uint256 amount = 100 * 10 ** 6;

        vm.prank(userB);
        vm.expectRevert(IGUSD.OnlyMinterAllowed.selector);
        aGUSD.debit(userA, amount);

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

    function test_collectMintFees_succeeds() public {
        uint256 numOfMints = 5;
        uint256 mintingPrice = 10 * 10 ** 6;
        uint256 mintFee = mintingPrice * 300 / 10_000;
        USDC.mint(userA, 1000 * 10 ** 6);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        for (uint256 i = 0; i < numOfMints; i++) {
            aGUSD.mint(1);
        }

        vm.stopPrank();

        uint256 amount = mintFee * 3;
        uint256 userBBalanceBefore = USDC.balanceOf(userB);
        uint256 accruedFee = mintFee * numOfMints;

        assertEq(aGUSD.mintFeesAccrued(), accruedFee);

        vm.expectEmit();
        emit IGUSD.CollectMintFee(aGUSD.owner(), userB, amount);
        vm.prank(owner);
        aGUSD.collectMintFee(userB, amount);

        assertEq(USDC.balanceOf(userB), userBBalanceBefore + amount);
        assertEq(aGUSD.mintFeesAccrued(), accruedFee - amount);
    }

    function test_collectMintFees_reverts_when_amount_exceeds_accrued_fee() public {
        uint256 numOfMints = 5;
        uint256 mintingPrice = 10 * 10 ** 6;
        uint256 mintFee = mintingPrice * 300 / 10_000;
        USDC.mint(userA, 1000 * 10 ** 6);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        for (uint256 i = 0; i < numOfMints; i++) {
            aGUSD.mint(1);
        }

        vm.stopPrank();

        uint256 amount = mintFee * 30;
        uint256 userBBalanceBefore = USDC.balanceOf(userB);
        uint256 accruedFee = mintFee * numOfMints;

        assertEq(aGUSD.mintFeesAccrued(), accruedFee);
        vm.prank(aGUSD.owner()); // not necessary
        vm.expectRevert(IGUSD.AmountExceedsAccruedFee.selector);
        aGUSD.collectMintFee(userB, amount);

        assertEq(USDC.balanceOf(userB), userBBalanceBefore);
        assertEq(aGUSD.mintFeesAccrued(), accruedFee);
    }

    function test_collectMintFees_reverts_when_caller_not_owner() public {
        uint256 numOfMints = 5;
        uint256 mintingPrice = 10 * 10 ** 6;
        uint256 mintFee = mintingPrice * 300 / 10_000;
        USDC.mint(userA, 1000 * 10 ** 6);

        vm.startPrank(userA);
        USDC.approve(address(aGUSD), MAX_INT);

        for (uint256 i = 0; i < numOfMints; i++) {
            aGUSD.mint(1);
        }

        vm.stopPrank();

        uint256 amount = mintFee * 3;
        uint256 userBBalanceBefore = USDC.balanceOf(userB);
        uint256 accruedFee = mintFee * numOfMints;

        assertEq(aGUSD.mintFeesAccrued(), accruedFee);
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, userA));
        aGUSD.collectMintFee(userB, amount);

        assertEq(USDC.balanceOf(userB), userBBalanceBefore);
        assertEq(aGUSD.mintFeesAccrued(), accruedFee);
    }

    function test_setMintFee_succeeds() public {
        assertEq(aGUSD.mintFeeBps(), 300);

        vm.prank(owner);
        vm.expectEmit();
        emit IGUSD.SetMintFee(500);
        aGUSD.setMintFee(500);

        assertEq(aGUSD.mintFeeBps(), 500);
    }

    function test_setMintFee_reverts_when_fee_exceeds_max_allowed() public {
        assertEq(aGUSD.mintFeeBps(), 300);
        uint16 fee = 1_500;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IGUSD.FeeTooLarge.selector, fee));
        aGUSD.setMintFee(fee);

        assertEq(aGUSD.mintFeeBps(), 300);
    }

    function test_setMintFee_reverts_when_caller_not_owner() public {
        vm.prank(userA);
        vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, userA));
        aGUSD.setMintFee(500);

        assertEq(aGUSD.mintFeeBps(), 300);
    }

    function test_addPeers_succeeds() public {
        IGUSD.PeerConfig[] memory configs = new IGUSD.PeerConfig[](4);
        configs[0].eid = 3;
        configs[1].eid = 4;
        configs[2].eid = 5;
        configs[3].eid = 6;
        GUSDMock[] memory gusds = new GUSDMock[](4);

        for (uint256 i = 0; i < configs.length; i++) {
            gusds[i] = GUSDMock(
                _deployOApp(
                    type(GUSDMock).creationCode,
                    abi.encode(owner, Currency.wrap(address(USDT)), minterB, aEid, address(endpoints[configs[i].eid]))
                )
            );

            configs[i].peer = addressToBytes32(address(gusds[i]));
        }

        assertEq(aGUSD.isPeer(configs[0].eid, configs[0].peer), false);
        assertEq(aGUSD.isPeer(configs[1].eid, configs[1].peer), false);
        assertEq(aGUSD.isPeer(configs[2].eid, configs[2].peer), false);
        assertEq(aGUSD.isPeer(configs[3].eid, configs[3].peer), false);

        bytes memory _options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        MessagingFee memory _fee = aGUSD.quoteAddPeers(configs, _options);
        vm.prank(owner);
        aGUSD.addPeers{value: _fee.nativeFee}(configs, _options);

        for (uint256 i = 0; i < configs.length; i++) {
            verifyPackets(configs[i].eid, configs[i].peer);
        }

        assertEq(aGUSD.isPeer(configs[0].eid, configs[0].peer), true);
        assertEq(aGUSD.isPeer(configs[1].eid, configs[1].peer), true);
        assertEq(aGUSD.isPeer(configs[2].eid, configs[2].peer), true);
        assertEq(aGUSD.isPeer(configs[3].eid, configs[3].peer), true);

        for (uint256 i = 0; i < configs.length; i++) {
            assertEq(gusds[i].isPeer(aEid, addressToBytes32(address(aGUSD))), true);
            for (uint256 j = 0; j < configs.length; j++) {
                assertEq(gusds[i].isPeer(configs[j].eid, configs[j].peer), true);
            }
        }
    }
}
