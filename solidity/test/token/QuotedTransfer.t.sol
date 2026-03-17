// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {TypeCasts} from "../../contracts/libs/TypeCasts.sol";
import {MockMailbox} from "../../contracts/mock/MockMailbox.sol";
import {ERC20Test} from "../../contracts/test/ERC20Test.sol";
import {TestPostDispatchHook} from "../../contracts/test/TestPostDispatchHook.sol";
import {InterchainGasPaymaster} from "../../contracts/hooks/igp/InterchainGasPaymaster.sol";
import {StorageGasOracle} from "../../contracts/hooks/igp/StorageGasOracle.sol";
import {IGasOracle} from "../../contracts/interfaces/IGasOracle.sol";
import {GasRouter} from "../../contracts/client/GasRouter.sol";

import {AbstractOffchainQuoter} from "../../contracts/libs/AbstractOffchainQuoter.sol";
import {OffchainQuotedFee} from "../../contracts/token/fees/OffchainQuotedFee.sol";
import {QuotedTransfer} from "../../contracts/token/QuotedTransfer.sol";
import {HypERC20} from "../../contracts/token/HypERC20.sol";
import {HypERC20Collateral} from "../../contracts/token/HypERC20Collateral.sol";
import {TokenRouter} from "../../contracts/token/libs/TokenRouter.sol";
import {Quote} from "../../contracts/interfaces/ITokenBridge.sol";

contract QuotedTransferTest is Test {
    using TypeCasts for address;

    uint32 constant ORIGIN = 11;
    uint32 constant DESTINATION = 12;
    uint256 constant SCALE = 1;
    uint8 constant DECIMALS = 18;
    uint256 constant TOTAL_SUPPLY = 1_000_000e18;
    uint256 constant TRANSFER_AMT = 100e18;
    uint256 constant FEE = 0.01 ether;
    uint256 constant GAS_LIMIT = 50_000;
    uint96 constant GAS_OVERHEAD = 10_000;
    uint128 constant TOKEN_EXCHANGE_RATE = 1e10;
    uint128 constant GAS_PRICE = 10;
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);
    address constant PROXY_ADMIN = address(0x37);

    uint256 signerPk = 0xA11CE;
    address signer;
    string[] urls;

    ERC20Test primaryToken;
    HypERC20Collateral localToken;
    HypERC20 remoteToken;
    MockMailbox localMailbox;
    MockMailbox remoteMailbox;
    TestPostDispatchHook noopHook;
    InterchainGasPaymaster igp;
    StorageGasOracle gasOracle;
    OffchainQuotedFee quotedFee;
    QuotedTransfer quotedTransfer;

    bytes4 constant IGP_QUOTE_CONTEXT_SELECTOR =
        bytes4(keccak256("quoteGasPayment(address,uint32,uint256)"));

    function setUp() public {
        signer = vm.addr(signerPk);
        urls.push("https://quoter.example.com/{data}");

        // Mailboxes
        localMailbox = new MockMailbox(ORIGIN);
        remoteMailbox = new MockMailbox(DESTINATION);
        localMailbox.addRemoteMailbox(DESTINATION, remoteMailbox);
        remoteMailbox.addRemoteMailbox(ORIGIN, localMailbox);

        noopHook = new TestPostDispatchHook();
        localMailbox.setDefaultHook(address(noopHook));
        localMailbox.setRequiredHook(address(noopHook));
        remoteMailbox.setDefaultHook(address(noopHook));
        remoteMailbox.setRequiredHook(address(noopHook));

        // Tokens
        primaryToken = new ERC20Test("Test", "TST", TOTAL_SUPPLY, DECIMALS);

        // IGP with offchain quoting
        igp = new InterchainGasPaymaster();
        igp.initialize(address(this), address(this));
        igp.setOffchainQuoteSigner(signer);

        gasOracle = new StorageGasOracle();
        StorageGasOracle.RemoteGasDataConfig[]
            memory configs = new StorageGasOracle.RemoteGasDataConfig[](1);
        configs[0] = StorageGasOracle.RemoteGasDataConfig({
            remoteDomain: DESTINATION,
            tokenExchangeRate: TOKEN_EXCHANGE_RATE,
            gasPrice: GAS_PRICE
        });
        gasOracle.setRemoteGasDataConfigs(configs);

        // Configure native gas oracle (required before token oracles)
        InterchainGasPaymaster.GasParam[]
            memory gasParams = new InterchainGasPaymaster.GasParam[](1);
        gasParams[0] = InterchainGasPaymaster.GasParam({
            remoteDomain: DESTINATION,
            config: InterchainGasPaymaster.DomainGasConfig({
                gasOracle: gasOracle,
                gasOverhead: GAS_OVERHEAD
            })
        });
        igp.setDestinationGasConfigs(gasParams);

        // Configure ERC20 token gas oracle
        InterchainGasPaymaster.TokenGasOracleConfig[]
            memory tokenConfigs = new InterchainGasPaymaster.TokenGasOracleConfig[](
                1
            );
        tokenConfigs[0] = InterchainGasPaymaster.TokenGasOracleConfig({
            feeToken: address(primaryToken),
            remoteDomain: DESTINATION,
            gasOracle: gasOracle
        });
        igp.setTokenGasOracles(tokenConfigs);

        // Remote token (behind proxy)
        HypERC20 remoteImpl = new HypERC20(
            DECIMALS,
            SCALE,
            SCALE,
            address(remoteMailbox)
        );
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(remoteImpl),
            PROXY_ADMIN,
            abi.encodeWithSelector(
                HypERC20.initialize.selector,
                TOTAL_SUPPLY,
                "Test",
                "TST",
                address(noopHook),
                address(0),
                address(this)
            )
        );
        remoteToken = HypERC20(address(proxy));

        // Local collateral token
        localToken = new HypERC20Collateral(
            address(primaryToken),
            SCALE,
            SCALE,
            address(localMailbox)
        );
        localToken.initialize(address(noopHook), address(0), address(this));

        // Fee contract (warp route fee)
        quotedFee = new OffchainQuotedFee(
            signer,
            address(primaryToken),
            signer,
            urls
        );
        localToken.setFeeRecipient(address(quotedFee));

        // Enroll routers
        localToken.enrollRemoteRouter(
            DESTINATION,
            address(remoteToken).addressToBytes32()
        );
        remoteToken.enrollRemoteRouter(
            ORIGIN,
            address(localToken).addressToBytes32()
        );

        // Set destination gas
        GasRouter.GasRouterConfig[]
            memory gasRouterConfigs = new GasRouter.GasRouterConfig[](1);
        gasRouterConfigs[0] = GasRouter.GasRouterConfig({
            domain: DESTINATION,
            gas: GAS_LIMIT
        });
        localToken.setDestinationGas(gasRouterConfigs);

        // Fund ALICE and collateral pool
        primaryToken.transfer(ALICE, 1000e18);
        primaryToken.transfer(address(localToken), 1000e18);

        // Deploy wrapper
        quotedTransfer = new QuotedTransfer();
    }

    // ============ Helpers ============

    function _domainSeparator(
        address verifier
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256("OffchainQuoter"),
                    keccak256("1"),
                    block.chainid,
                    verifier
                )
            );
    }

    function _signQuote(
        address verifier,
        AbstractOffchainQuoter.SignedQuote memory sq
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                quotedFee.SIGNED_QUOTE_TYPEHASH(),
                keccak256(sq.context),
                sq.data,
                sq.issuedAt,
                sq.expiry
            )
        );
        bytes32 digest = ECDSA.toTypedDataHash(
            _domainSeparator(verifier),
            structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _feeQuoteContext() internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                OffchainQuotedFee.quoteTransferRemote.selector,
                DESTINATION,
                BOB.addressToBytes32(),
                TRANSFER_AMT
            );
    }

    function _buildFeeQuote()
        internal
        view
        returns (QuotedTransfer.QuoteSubmission memory)
    {
        return _buildFeeQuote(true);
    }

    function _buildFeeQuote(
        bool transient_
    ) internal view returns (QuotedTransfer.QuoteSubmission memory) {
        uint48 now_ = uint48(block.timestamp);
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _feeQuoteContext(),
                data: bytes32(FEE),
                issuedAt: now_,
                expiry: transient_ ? now_ : now_ + 3600
            });
        return
            QuotedTransfer.QuoteSubmission({
                quoter: address(quotedFee),
                quote: sq,
                signature: _signQuote(address(quotedFee), sq)
            });
    }

    /// @dev IGP context: quoteGasPayment(feeToken, destination, sender)
    ///      where sender = warp route (it calls hook.quoteDispatch)
    function _igpQuoteContext() internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                IGP_QUOTE_CONTEXT_SELECTOR,
                address(primaryToken), // feeToken = token() when feeHook is set
                DESTINATION,
                address(localToken) // msg.sender in quoteGasPayment = warp route
            );
    }

    function _packGasData(
        uint128 exchangeRate,
        uint128 gasPrice
    ) internal pure returns (bytes32) {
        return bytes32((uint256(exchangeRate) << 128) | uint256(gasPrice));
    }

    function _buildIgpQuote()
        internal
        view
        returns (QuotedTransfer.QuoteSubmission memory)
    {
        return _buildIgpQuote(true);
    }

    function _buildIgpQuote(
        bool transient_
    ) internal view returns (QuotedTransfer.QuoteSubmission memory) {
        uint48 now_ = uint48(block.timestamp);
        // Standing context encodes (dest, sender) after selector;
        // transient context encodes (feeToken, dest, sender)
        bytes memory context = transient_
            ? _igpQuoteContext()
            : abi.encodeWithSelector(
                IGP_QUOTE_CONTEXT_SELECTOR,
                DESTINATION,
                address(localToken)
            );
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: context,
                data: _packGasData(TOKEN_EXCHANGE_RATE, GAS_PRICE),
                issuedAt: now_,
                expiry: transient_ ? now_ : now_ + 3600
            });
        return
            QuotedTransfer.QuoteSubmission({
                quoter: address(igp),
                quote: sq,
                signature: _signQuote(address(igp), sq)
            });
    }

    function _computeIgpFee() internal view returns (uint256) {
        uint256 totalGas = igp.destinationGasLimit(DESTINATION, GAS_LIMIT);
        return
            igp.quoteGasPayment(address(primaryToken), DESTINATION, totalGas);
    }

    // ============ Tests: Fee Quote Only (native gas) ============

    function test_transferRemote_withTransientFeeQuote() public {
        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](1);
        quotes[0] = _buildFeeQuote();

        uint256 totalTokens = TRANSFER_AMT + FEE;

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - totalTokens);
        assertEq(primaryToken.balanceOf(address(quotedFee)), FEE);
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    function test_transferRemote_noQuotes_reverts() public {
        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](0);

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), TRANSFER_AMT);
        vm.expectRevert();
        quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();
    }

    function test_transferRemote_refundsExcessTokens() public {
        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](1);
        quotes[0] = _buildFeeQuote();

        uint256 excess = 10e18;
        uint256 totalApproval = TRANSFER_AMT + FEE + excess;

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalApproval);
        quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - TRANSFER_AMT - FEE);
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    function test_transferRemote_withStandingQuote() public {
        uint48 now_ = uint48(block.timestamp);
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _feeQuoteContext(),
                data: bytes32(FEE),
                issuedAt: now_,
                expiry: now_ + 3600
            });
        quotedFee.submitQuote(sq, _signQuote(address(quotedFee), sq));

        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](0);

        uint256 totalTokens = TRANSFER_AMT + FEE;
        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    // ============ Tests: IGP + Fee Quote (ERC20 gas) ============

    function test_transferRemote_withIgpAndFeeQuotes() public {
        // Enable ERC20 gas payments: set IGP as both hook and feeHook
        localToken.setFeeHook(address(igp));
        localToken.setHook(address(igp));

        // Compute expected IGP fee from oracle (before submitting offchain quote)
        uint256 igpFee = _computeIgpFee();
        assertGt(igpFee, 0, "IGP fee should be > 0");

        // Build both quotes
        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](2);
        quotes[0] = _buildIgpQuote();
        quotes[1] = _buildFeeQuote();

        uint256 totalTokens = TRANSFER_AMT + FEE + igpFee;

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));

        // ALICE spent exactly transfer + fee + igp
        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - totalTokens);

        // Fee went to quotedFee contract
        assertEq(primaryToken.balanceOf(address(quotedFee)), FEE);

        // IGP received gas fee
        assertEq(primaryToken.balanceOf(address(igp)), igpFee);

        // Nothing stuck in wrapper
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    function test_transferRemote_withIgpQuoteOnly_noFeeRecipient() public {
        // Remove fee recipient, use IGP only
        localToken.setFeeRecipient(address(0));
        localToken.setFeeHook(address(igp));
        localToken.setHook(address(igp));

        uint256 igpFee = _computeIgpFee();

        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](1);
        quotes[0] = _buildIgpQuote();

        uint256 totalTokens = TRANSFER_AMT + igpFee;

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - totalTokens);
        assertEq(primaryToken.balanceOf(address(igp)), igpFee);
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    function test_transferRemote_withFeeQuoteOnly_nativeGas() public {
        // feeRecipient set in setUp, no feeHook — gas paid in native via noopHook
        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](1);
        quotes[0] = _buildFeeQuote();

        uint256 totalTokens = TRANSFER_AMT + FEE;

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - totalTokens);
        assertEq(primaryToken.balanceOf(address(quotedFee)), FEE);
        assertEq(primaryToken.balanceOf(address(igp)), 0);
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    // ============ Tests: quoteTransferRemote ============

    function test_quoteTransferRemote_withFeeQuote() public {
        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](1);
        quotes[0] = _buildFeeQuote();

        Quote[] memory result = quotedTransfer.quoteTransferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );

        // [0] = gas fee (native, 0 from noopHook)
        assertEq(result[0].token, address(0));
        assertEq(result[0].amount, 0);
        // [1] = bridge amount + protocol fee
        assertEq(result[1].token, address(primaryToken));
        assertEq(result[1].amount, TRANSFER_AMT + FEE);
    }

    function test_quoteTransferRemote_withIgpAndFeeQuotes() public {
        localToken.setFeeHook(address(igp));
        localToken.setHook(address(igp));

        uint256 igpFee = _computeIgpFee();

        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](2);
        quotes[0] = _buildIgpQuote();
        quotes[1] = _buildFeeQuote();

        Quote[] memory result = quotedTransfer.quoteTransferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );

        // [0] = IGP gas fee in ERC20
        assertEq(result[0].token, address(primaryToken));
        assertEq(result[0].amount, igpFee);
        // [1] = bridge amount + protocol fee
        assertEq(result[1].token, address(primaryToken));
        assertEq(result[1].amount, TRANSFER_AMT + FEE);
    }

    // ============ Tests: Standing Quotes ============

    function test_transferRemote_withStandingFeeQuote() public {
        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](1);
        quotes[0] = _buildFeeQuote(false);

        uint256 totalTokens = TRANSFER_AMT + FEE;

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - totalTokens);
        assertEq(primaryToken.balanceOf(address(quotedFee)), FEE);
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    function test_transferRemote_withStandingIgpQuote() public {
        localToken.setFeeRecipient(address(0));
        localToken.setFeeHook(address(igp));
        localToken.setHook(address(igp));

        uint256 igpFee = _computeIgpFee();

        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](1);
        quotes[0] = _buildIgpQuote(false);

        uint256 totalTokens = TRANSFER_AMT + igpFee;

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - totalTokens);
        assertEq(primaryToken.balanceOf(address(igp)), igpFee);
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    function test_transferRemote_withStandingIgpAndFeeQuotes() public {
        localToken.setFeeHook(address(igp));
        localToken.setHook(address(igp));

        uint256 igpFee = _computeIgpFee();

        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](2);
        quotes[0] = _buildIgpQuote(false);
        quotes[1] = _buildFeeQuote(false);

        uint256 totalTokens = TRANSFER_AMT + FEE + igpFee;

        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - totalTokens);
        assertEq(primaryToken.balanceOf(address(quotedFee)), FEE);
        assertEq(primaryToken.balanceOf(address(igp)), igpFee);
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }

    function test_transferRemote_standingFeeQuote_transientIgpQuote() public {
        localToken.setFeeHook(address(igp));
        localToken.setHook(address(igp));

        // Standing fee quote via wrapper first tx
        QuotedTransfer.QuoteSubmission[]
            memory standingQuotes = new QuotedTransfer.QuoteSubmission[](1);
        standingQuotes[0] = _buildFeeQuote(false);
        quotedTransfer.quoteTransferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            standingQuotes
        );

        uint256 igpFee = _computeIgpFee();

        // Transfer with only transient IGP quote — standing fee resolves
        QuotedTransfer.QuoteSubmission[]
            memory quotes = new QuotedTransfer.QuoteSubmission[](1);
        quotes[0] = _buildIgpQuote(true);

        uint256 totalTokens = TRANSFER_AMT + FEE + igpFee;
        vm.startPrank(ALICE);
        primaryToken.approve(address(quotedTransfer), totalTokens);
        bytes32 messageId = quotedTransfer.transferRemote(
            address(localToken),
            DESTINATION,
            BOB.addressToBytes32(),
            TRANSFER_AMT,
            quotes
        );
        vm.stopPrank();

        assertTrue(messageId != bytes32(0));
        assertEq(primaryToken.balanceOf(ALICE), 1000e18 - totalTokens);
        assertEq(primaryToken.balanceOf(address(quotedFee)), FEE);
        assertEq(primaryToken.balanceOf(address(igp)), igpFee);
        assertEq(primaryToken.balanceOf(address(quotedTransfer)), 0);
    }
}
