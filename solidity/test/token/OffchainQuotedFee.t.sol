// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {OffchainQuotedFee} from "../../contracts/token/fees/OffchainQuotedFee.sol";
import {AbstractOffchainQuoter} from "../../contracts/libs/AbstractOffchainQuoter.sol";
import {Quote} from "../../contracts/interfaces/ITokenBridge.sol";

contract OffchainQuotedFeeTest is Test {
    OffchainQuotedFee quotedFee;

    uint256 signerPk = 0xA11CE;
    address signer;
    address constant FEE_TOKEN = address(0xFEE);

    uint32 constant DEST = 42;
    bytes32 constant RECIPIENT = bytes32(uint256(0xBEEF));
    uint256 constant AMOUNT = 1 ether;
    uint256 constant MAX_FEE = 0.01 ether;
    uint256 constant HALF_AMOUNT = 0.5 ether; // fee = maxFee at amount = 2 * halfAmount = 1 ether

    string[] urls;

    function setUp() public {
        signer = vm.addr(signerPk);
        urls.push("https://quoter.example.com/{data}");
        quotedFee = new OffchainQuotedFee(signer, FEE_TOKEN, signer, urls);
    }

    // ============ Helpers ============

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256("OffchainQuoter"),
                    keccak256("1"),
                    block.chainid,
                    address(quotedFee)
                )
            );
    }

    function _signQuote(
        AbstractOffchainQuoter.SignedQuote memory sq
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                quotedFee.SIGNED_QUOTE_TYPEHASH(),
                keccak256(sq.context),
                keccak256(sq.data),
                sq.issuedAt,
                sq.expiry,
                sq.salt,
                sq.submitter
            )
        );
        bytes32 digest = ECDSA.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _encodeFeeData(
        uint256 maxFee,
        uint256 halfAmount
    ) internal pure returns (bytes memory) {
        return abi.encode(maxFee, halfAmount);
    }

    function _computeFee(
        uint256 maxFee,
        uint256 halfAmount,
        uint256 amount
    ) internal pure returns (uint256) {
        uint256 uncapped = (amount * maxFee) / (2 * halfAmount);
        return uncapped > maxFee ? maxFee : uncapped;
    }

    function _quoteContext(
        uint32 dest,
        bytes32 recipient,
        uint256 amount
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                OffchainQuotedFee.quoteTransferRemote.selector,
                dest,
                recipient,
                amount
            );
    }

    function _submitTransient(
        uint32 dest,
        bytes32 recipient,
        uint256 amount,
        uint256 maxFee,
        uint256 halfAmount
    ) internal {
        uint48 now_ = uint48(block.timestamp);
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(dest, recipient, amount),
                data: _encodeFeeData(maxFee, halfAmount),
                issuedAt: now_,
                expiry: now_, // transient
                salt: bytes32(0),
                submitter: address(0)
            });
        quotedFee.submitQuote(sq, _signQuote(sq));
    }

    function _submitStanding(
        uint32 dest,
        bytes32 recipient,
        uint256 amount,
        uint256 maxFee,
        uint256 halfAmount,
        uint48 issuedAt,
        uint48 expiry
    ) internal {
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(dest, recipient, amount),
                data: _encodeFeeData(maxFee, halfAmount),
                issuedAt: issuedAt,
                expiry: expiry,
                salt: bytes32(0),
                submitter: address(0)
            });
        quotedFee.submitQuote(sq, _signQuote(sq));
    }

    // ============ Transient Quotes ============

    function test_transientQuote_returnsCorrectFee() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, MAX_FEE, HALF_AMOUNT);

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result.length, 1);
        assertEq(result[0].token, FEE_TOKEN);
        assertEq(result[0].amount, _computeFee(MAX_FEE, HALF_AMOUNT, AMOUNT));
    }

    function test_transientQuote_linearFee() public {
        uint256 maxFee = 0.1 ether;
        uint256 halfAmount = 5 ether;
        _submitTransient(DEST, RECIPIENT, AMOUNT, maxFee, halfAmount);

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        // min(0.1e18, 1e18 * 0.1e18 / (2 * 5e18)) = min(0.1e18, 0.01e18) = 0.01e18
        assertEq(result[0].amount, _computeFee(maxFee, halfAmount, AMOUNT));
    }

    function test_transientQuote_contextMismatch_fallsThrough() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, MAX_FEE, HALF_AMOUNT);

        // Different destination — no match, no standing quote → CCIP-Read
        vm.expectRevert();
        quotedFee.quoteTransferRemote(DEST + 1, RECIPIENT, AMOUNT);
    }

    function test_transientQuote_differentRecipient_fallsThrough() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, MAX_FEE, HALF_AMOUNT);

        vm.expectRevert();
        quotedFee.quoteTransferRemote(DEST, bytes32(uint256(0xDEAD)), AMOUNT);
    }

    function test_transientQuote_differentAmount_fallsThrough() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, MAX_FEE, HALF_AMOUNT);

        // Different amount — field mismatch
        vm.expectRevert();
        quotedFee.quoteTransferRemote(DEST, RECIPIENT, AMOUNT + 1);
    }

    function test_transientQuote_wildcardAmount() public {
        uint256 wildcardAmt = type(uint256).max;
        _submitTransient(DEST, RECIPIENT, wildcardAmt, MAX_FEE, HALF_AMOUNT);

        // Any amount should match
        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            42 ether
        );
        assertEq(result[0].amount, _computeFee(MAX_FEE, HALF_AMOUNT, 42 ether));
    }

    function test_transientQuote_zeroFee() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, 0, 0);

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, 0);
    }

    function test_standingQuote_zeroFee() public {
        uint48 now_ = uint48(block.timestamp);
        _submitStanding(DEST, RECIPIENT, AMOUNT, 0, 0, now_, now_ + 3600);

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, 0);
    }

    // ============ Standing Quotes ============

    function test_standingQuote_specificMatch() public {
        uint48 now_ = uint48(block.timestamp);
        _submitStanding(
            DEST,
            RECIPIENT,
            AMOUNT,
            MAX_FEE,
            HALF_AMOUNT,
            now_,
            now_ + 3600
        );

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result.length, 1);
        assertEq(result[0].amount, _computeFee(MAX_FEE, HALF_AMOUNT, AMOUNT));
    }

    function test_standingQuote_linearFee_scalesWithAmount() public {
        uint48 now_ = uint48(block.timestamp);
        uint256 maxFee = 1 ether;
        uint256 halfAmount = 50 ether;
        _submitStanding(
            DEST,
            RECIPIENT,
            AMOUNT,
            maxFee,
            halfAmount,
            now_,
            now_ + 3600
        );

        // 1 ether: min(1e18, 1e18 * 1e18 / (2 * 50e18)) = 0.01e18
        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, _computeFee(maxFee, halfAmount, AMOUNT));

        // 10 ether: min(1e18, 10e18 * 1e18 / (2 * 50e18)) = 0.1e18
        result = quotedFee.quoteTransferRemote(DEST, RECIPIENT, 10 ether);
        assertEq(result[0].amount, _computeFee(maxFee, halfAmount, 10 ether));
    }

    function test_standingQuote_destinationWildcard() public {
        uint48 now_ = uint48(block.timestamp);
        bytes32 wildcard = bytes32(type(uint256).max);
        _submitStanding(
            DEST,
            wildcard,
            AMOUNT,
            MAX_FEE,
            HALF_AMOUNT,
            now_,
            now_ + 3600
        );

        // Any recipient on this destination should match
        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, _computeFee(MAX_FEE, HALF_AMOUNT, AMOUNT));
    }

    function test_standingQuote_recipientWildcard() public {
        uint48 now_ = uint48(block.timestamp);
        uint32 wildcardDest = type(uint32).max;
        _submitStanding(
            wildcardDest,
            RECIPIENT,
            AMOUNT,
            MAX_FEE,
            HALF_AMOUNT,
            now_,
            now_ + 3600
        );

        // Any destination for this recipient should match
        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, _computeFee(MAX_FEE, HALF_AMOUNT, AMOUNT));
    }

    function test_standingQuote_expired_fallsThrough() public {
        uint48 now_ = uint48(block.timestamp);
        _submitStanding(
            DEST,
            RECIPIENT,
            AMOUNT,
            MAX_FEE,
            HALF_AMOUNT,
            now_,
            now_ + 1
        );

        // Warp past expiry
        vm.warp(now_ + 2);

        vm.expectRevert(); // CCIP-Read
        quotedFee.quoteTransferRemote(DEST, RECIPIENT, AMOUNT);
    }

    function test_standingQuote_staleQuote_reverts() public {
        uint48 now_ = uint48(block.timestamp);
        _submitStanding(
            DEST,
            RECIPIENT,
            AMOUNT,
            MAX_FEE,
            HALF_AMOUNT,
            now_,
            now_ + 3600
        );

        // Try to submit older quote
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(DEST, RECIPIENT, AMOUNT),
                data: _encodeFeeData(MAX_FEE + 1, HALF_AMOUNT),
                issuedAt: now_ - 1,
                expiry: now_ + 7200,
                salt: bytes32(0),
                submitter: address(0)
            });
        bytes memory sig = _signQuote(sq);
        vm.expectRevert(AbstractOffchainQuoter.StaleQuote.selector);
        quotedFee.submitQuote(sq, sig);
    }

    // ============ Resolution Priority ============

    function test_transientTakesPriorityOverStanding() public {
        uint48 now_ = uint48(block.timestamp);
        // Standing: high fee (maxFee=0.05, halfAmount=0.5 → fee at 1 ether = 0.05)
        // Transient: low fee (maxFee=0.01, halfAmount=0.5 → fee at 1 ether = 0.01)
        _submitStanding(
            DEST,
            RECIPIENT,
            AMOUNT,
            0.05 ether,
            HALF_AMOUNT,
            now_,
            now_ + 3600
        );
        _submitTransient(DEST, RECIPIENT, AMOUNT, 0.01 ether, HALF_AMOUNT);

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(
            result[0].amount,
            _computeFee(0.01 ether, HALF_AMOUNT, AMOUNT)
        );
    }

    function test_specificTakesPriorityOverWildcard() public {
        uint48 now_ = uint48(block.timestamp);

        bytes32 wildcard = bytes32(type(uint256).max);
        _submitStanding(
            DEST,
            wildcard,
            AMOUNT,
            0.05 ether,
            HALF_AMOUNT,
            now_,
            now_ + 3600
        );
        _submitStanding(
            DEST,
            RECIPIENT,
            AMOUNT,
            0.01 ether,
            HALF_AMOUNT,
            now_,
            now_ + 3600
        );

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(
            result[0].amount,
            _computeFee(0.01 ether, HALF_AMOUNT, AMOUNT)
        );
    }

    // ============ Signature Verification ============

    function test_invalidSigner_reverts() public {
        uint256 wrongPk = 0xBAD;
        uint48 now_ = uint48(block.timestamp);

        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(DEST, RECIPIENT, AMOUNT),
                data: _encodeFeeData(MAX_FEE, HALF_AMOUNT),
                issuedAt: now_,
                expiry: now_,
                salt: bytes32(0),
                submitter: address(0)
            });

        // Sign with wrong key
        bytes32 structHash = keccak256(
            abi.encode(
                quotedFee.SIGNED_QUOTE_TYPEHASH(),
                keccak256(sq.context),
                keccak256(sq.data),
                sq.issuedAt,
                sq.expiry,
                sq.salt,
                sq.submitter
            )
        );
        bytes32 digest = ECDSA.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);

        vm.expectRevert(AbstractOffchainQuoter.InvalidSigner.selector);
        quotedFee.submitQuote(sq, abi.encodePacked(r, s, v));
    }

    function test_expiredQuote_reverts() public {
        vm.warp(1000);
        uint48 past = uint48(block.timestamp) - 1;

        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(DEST, RECIPIENT, AMOUNT),
                data: _encodeFeeData(MAX_FEE, HALF_AMOUNT),
                issuedAt: past,
                expiry: past,
                salt: bytes32(0),
                submitter: address(0)
            });
        bytes memory sig = _signQuote(sq);

        vm.expectRevert(AbstractOffchainQuoter.QuoteExpired.selector);
        quotedFee.submitQuote(sq, sig);
    }

    // ============ Submitter Verification ============

    function test_submitter_restrictedToSpecificAddress() public {
        uint48 now_ = uint48(block.timestamp);
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(DEST, RECIPIENT, AMOUNT),
                data: _encodeFeeData(MAX_FEE, HALF_AMOUNT),
                issuedAt: now_,
                expiry: now_,
                salt: bytes32(0),
                submitter: address(this)
            });
        // Submitter matches msg.sender — should succeed
        quotedFee.submitQuote(sq, _signQuote(sq));
    }

    function test_submitter_wrongSender_reverts() public {
        uint48 now_ = uint48(block.timestamp);
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(DEST, RECIPIENT, AMOUNT),
                data: _encodeFeeData(MAX_FEE, HALF_AMOUNT),
                issuedAt: now_,
                expiry: now_,
                salt: bytes32(0),
                submitter: address(0xBEEF)
            });
        bytes memory sig = _signQuote(sq);
        vm.expectRevert(AbstractOffchainQuoter.InvalidSubmitter.selector);
        quotedFee.submitQuote(sq, sig);
    }

    function test_submitter_zeroIsUnrestricted() public {
        uint48 now_ = uint48(block.timestamp);
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(DEST, RECIPIENT, AMOUNT),
                data: _encodeFeeData(MAX_FEE, HALF_AMOUNT),
                issuedAt: now_,
                expiry: now_,
                salt: bytes32(0),
                submitter: address(0)
            });
        // Any sender can submit when submitter is address(0)
        vm.prank(address(0xDEAD));
        quotedFee.submitQuote(sq, _signQuote(sq));
    }

    // ============ CCIP-Read Fallback ============

    function test_noQuotes_revertsWithOffchainLookup() public {
        vm.expectRevert();
        quotedFee.quoteTransferRemote(DEST, RECIPIENT, AMOUNT);
    }
}
