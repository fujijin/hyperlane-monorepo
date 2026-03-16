// SPDX-License-Identifier: MIT OR Apache-2.0
pragma solidity >=0.8.0;

/*@@@@@@@       @@@@@@@@@
 @@@@@@@@@       @@@@@@@@@
  @@@@@@@@@       @@@@@@@@@
   @@@@@@@@@       @@@@@@@@@
    @@@@@@@@@@@@@@@@@@@@@@@@@
     @@@@@  HYPERLANE  @@@@@@@
    @@@@@@@@@@@@@@@@@@@@@@@@@
   @@@@@@@@@       @@@@@@@@@
  @@@@@@@@@       @@@@@@@@@
 @@@@@@@@@       @@@@@@@@@
@@@@@@@@@       @@@@@@@@*/

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title AbstractOffchainQuoter
 * @notice Mixin for offchain-signed fee quotes with EIP-712 verification.
 * @dev No storage of its own — safe to mix into upgradeable contracts.
 *      Concrete contracts define their own stored quote types and transient variables.
 */
abstract contract AbstractOffchainQuoter {
    // ============ Constants ============

    bytes32 public constant SIGNED_QUOTE_TYPEHASH =
        keccak256(
            "SignedQuote(bytes context,bytes32 data,uint48 issuedAt,uint48 expiry)"
        );

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 private constant _NAME_HASH = keccak256("OffchainQuoter");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    // ============ Structs ============

    struct SignedQuote {
        bytes context;
        bytes32 data;
        uint48 issuedAt;
        uint48 expiry; // == issuedAt means transient
    }

    // ============ Errors ============

    error QuoteExpired();
    error StaleQuote();
    error InvalidSigner();

    // ============ Events ============

    event QuoteSubmitted(
        bytes context,
        bytes32 data,
        uint48 issuedAt,
        uint48 expiry,
        bool isTransient
    );

    // ============ External ============

    function submitQuote(
        SignedQuote calldata sq,
        bytes calldata signature
    ) external {
        if (uint48(block.timestamp) > sq.expiry) revert QuoteExpired();
        _verifyQuoteSigner(sq, signature);

        bool isTransient = sq.expiry == sq.issuedAt;
        if (isTransient) {
            _storeTransient(sq);
        } else {
            _storeStanding(sq);
        }

        emit QuoteSubmitted(
            sq.context,
            sq.data,
            sq.issuedAt,
            sq.expiry,
            isTransient
        );
    }

    // ============ Internal: EIP-712 ============

    function _domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _EIP712_DOMAIN_TYPEHASH,
                    _NAME_HASH,
                    _VERSION_HASH,
                    block.chainid,
                    address(this)
                )
            );
    }

    function _verifyQuoteSigner(
        SignedQuote calldata sq,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNED_QUOTE_TYPEHASH,
                keccak256(sq.context),
                sq.data,
                sq.issuedAt,
                sq.expiry
            )
        );
        bytes32 digest = ECDSA.toTypedDataHash(_domainSeparator(), structHash);
        address signer = ECDSA.recover(digest, signature);
        if (signer != _quoteSigner()) revert InvalidSigner();
    }

    // ============ Abstract ============

    function _quoteSigner() internal view virtual returns (address);
    function _storeTransient(SignedQuote calldata sq) internal virtual;
    function _storeStanding(SignedQuote calldata sq) internal virtual;
}
