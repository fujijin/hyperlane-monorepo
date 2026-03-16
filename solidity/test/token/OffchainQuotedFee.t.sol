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
    uint256 constant FEE = 0.01 ether;

    string[] urls;

    function setUp() public {
        signer = vm.addr(signerPk);
        urls.push("https://quoter.example.com/{data}");
        quotedFee = new OffchainQuotedFee(signer, FEE_TOKEN, urls);
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
                sq.data,
                sq.issuedAt,
                sq.expiry
            )
        );
        bytes32 digest = ECDSA.toTypedDataHash(_domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
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
        uint256 fee
    ) internal {
        uint48 now_ = uint48(block.timestamp);
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(dest, recipient, amount),
                data: bytes32(fee),
                issuedAt: now_,
                expiry: now_ // transient
            });
        quotedFee.submitQuote(sq, _signQuote(sq));
    }

    function _submitStanding(
        uint32 dest,
        bytes32 recipient,
        uint256 amount,
        uint256 fee,
        uint48 issuedAt,
        uint48 expiry
    ) internal {
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(dest, recipient, amount),
                data: bytes32(fee),
                issuedAt: issuedAt,
                expiry: expiry
            });
        quotedFee.submitQuote(sq, _signQuote(sq));
    }

    // ============ Transient Quotes ============

    function test_transientQuote_returnsCorrectFee() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, FEE);

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result.length, 1);
        assertEq(result[0].token, FEE_TOKEN);
        assertEq(result[0].amount, FEE);
    }

    function test_transientQuote_contextMismatch_fallsThrough() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, FEE);

        // Different destination — context hash won't match, no standing quote → CCIP-Read
        vm.expectRevert();
        quotedFee.quoteTransferRemote(DEST + 1, RECIPIENT, AMOUNT);
    }

    function test_transientQuote_differentRecipient_fallsThrough() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, FEE);

        vm.expectRevert();
        quotedFee.quoteTransferRemote(DEST, bytes32(uint256(0xDEAD)), AMOUNT);
    }

    function test_transientQuote_differentAmount_fallsThrough() public {
        _submitTransient(DEST, RECIPIENT, AMOUNT, FEE);

        // Different amount changes msg.data → context hash mismatch
        vm.expectRevert();
        quotedFee.quoteTransferRemote(DEST, RECIPIENT, AMOUNT + 1);
    }

    // ============ Standing Quotes ============

    function test_standingQuote_specificMatch() public {
        uint48 now_ = uint48(block.timestamp);
        _submitStanding(DEST, RECIPIENT, AMOUNT, FEE, now_, now_ + 3600);

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result.length, 1);
        assertEq(result[0].amount, FEE);
    }

    function test_standingQuote_destinationWildcard() public {
        uint48 now_ = uint48(block.timestamp);
        bytes32 wildcard = bytes32(type(uint256).max);
        _submitStanding(DEST, wildcard, AMOUNT, FEE, now_, now_ + 3600);

        // Any recipient on this destination should match
        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, FEE);
    }

    function test_standingQuote_recipientWildcard() public {
        uint48 now_ = uint48(block.timestamp);
        uint32 wildcardDest = type(uint32).max;
        _submitStanding(
            wildcardDest,
            RECIPIENT,
            AMOUNT,
            FEE,
            now_,
            now_ + 3600
        );

        // Any destination for this recipient should match
        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, FEE);
    }

    function test_standingQuote_expired_fallsThrough() public {
        uint48 now_ = uint48(block.timestamp);
        _submitStanding(DEST, RECIPIENT, AMOUNT, FEE, now_, now_ + 1);

        // Warp past expiry
        vm.warp(now_ + 2);

        vm.expectRevert(); // CCIP-Read
        quotedFee.quoteTransferRemote(DEST, RECIPIENT, AMOUNT);
    }

    function test_standingQuote_staleQuote_reverts() public {
        uint48 now_ = uint48(block.timestamp);
        _submitStanding(DEST, RECIPIENT, AMOUNT, FEE, now_, now_ + 3600);

        // Try to submit older quote
        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(DEST, RECIPIENT, AMOUNT),
                data: bytes32(FEE + 1),
                issuedAt: now_ - 1,
                expiry: now_ + 7200
            });
        bytes memory sig = _signQuote(sq);
        vm.expectRevert(AbstractOffchainQuoter.StaleQuote.selector);
        quotedFee.submitQuote(sq, sig);
    }

    // ============ Resolution Priority ============

    function test_transientTakesPriorityOverStanding() public {
        uint48 now_ = uint48(block.timestamp);
        uint256 standingFee = 0.05 ether;
        uint256 transientFee = 0.01 ether;

        _submitStanding(
            DEST,
            RECIPIENT,
            AMOUNT,
            standingFee,
            now_,
            now_ + 3600
        );
        _submitTransient(DEST, RECIPIENT, AMOUNT, transientFee);

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, transientFee);
    }

    function test_specificTakesPriorityOverWildcard() public {
        uint48 now_ = uint48(block.timestamp);
        uint256 wildcardFee = 0.05 ether;
        uint256 specificFee = 0.01 ether;

        bytes32 wildcard = bytes32(type(uint256).max);
        _submitStanding(DEST, wildcard, AMOUNT, wildcardFee, now_, now_ + 3600);
        _submitStanding(
            DEST,
            RECIPIENT,
            AMOUNT,
            specificFee,
            now_,
            now_ + 3600
        );

        Quote[] memory result = quotedFee.quoteTransferRemote(
            DEST,
            RECIPIENT,
            AMOUNT
        );
        assertEq(result[0].amount, specificFee);
    }

    // ============ Signature Verification ============

    function test_invalidSigner_reverts() public {
        uint256 wrongPk = 0xBAD;
        uint48 now_ = uint48(block.timestamp);

        AbstractOffchainQuoter.SignedQuote memory sq = AbstractOffchainQuoter
            .SignedQuote({
                context: _quoteContext(DEST, RECIPIENT, AMOUNT),
                data: bytes32(FEE),
                issuedAt: now_,
                expiry: now_
            });

        // Sign with wrong key
        bytes32 structHash = keccak256(
            abi.encode(
                quotedFee.SIGNED_QUOTE_TYPEHASH(),
                keccak256(sq.context),
                sq.data,
                sq.issuedAt,
                sq.expiry
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
                data: bytes32(FEE),
                issuedAt: past,
                expiry: past
            });
        bytes memory sig = _signQuote(sq);

        vm.expectRevert(AbstractOffchainQuoter.QuoteExpired.selector);
        quotedFee.submitQuote(sq, sig);
    }

    // ============ CCIP-Read Fallback ============

    function test_noQuotes_revertsWithOffchainLookup() public {
        vm.expectRevert();
        quotedFee.quoteTransferRemote(DEST, RECIPIENT, AMOUNT);
    }
}
