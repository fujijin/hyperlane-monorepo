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

import {AbstractOffchainQuoter} from "../../libs/AbstractOffchainQuoter.sol";
import {ITokenFee, Quote} from "../../interfaces/ITokenBridge.sol";
import {PackageVersioned} from "../../PackageVersioned.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title OffchainQuotedFee
 * @notice ITokenFee implementation backed by offchain-signed quotes.
 * @dev Set as `feeRecipient` on a warp route. Returns signed fee quotes
 *      via multi-level resolution: transient → (destination, recipient) →
 *      (destination, *) → (*, recipient) → CCIP-Read.
 *
 *      Quote data: bytes32(uint256(fee)). 0 = no quote.
 */
contract OffchainQuotedFee is
    AbstractOffchainQuoter,
    ITokenFee,
    PackageVersioned
{
    using SafeERC20 for IERC20;
    using Address for address payable;

    // ============ Constants ============

    uint32 constant WILDCARD_DEST = type(uint32).max;
    bytes32 constant WILDCARD_RECIPIENT = bytes32(type(uint256).max);

    // ============ Immutables ============

    address public immutable quoteSigner;
    address public immutable feeToken;
    address public immutable beneficiary;

    // ============ Structs ============

    struct StoredQuote {
        bytes32 data;
        uint48 issuedAt;
        uint48 expiry;
    }

    // ============ Storage ============

    mapping(uint32 => mapping(bytes32 => StoredQuote)) public quotes;
    string[] internal _urls;

    // ============ Transient Storage ============

    uint256 private transient _transientFee;
    bytes32 private transient _transientContextHash;

    // ============ Errors ============

    /// @dev https://eips.ethereum.org/EIPS/eip-3668
    error OffchainLookup(
        address sender,
        string[] urls,
        bytes callData,
        bytes4 callbackFunction,
        bytes extraData
    );

    // ============ Constructor ============

    constructor(
        address _quoteSigner,
        address _feeToken,
        address _beneficiary,
        string[] memory __urls
    ) {
        quoteSigner = _quoteSigner;
        feeToken = _feeToken;
        beneficiary = _beneficiary;
        _urls = __urls;
    }

    // ============ ITokenFee ============

    /// @inheritdoc ITokenFee
    function quoteTransferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 /*_amount*/
    ) external view override returns (Quote[] memory) {
        // 1. Transient — only if context hash matches current call
        uint256 fee = _transientFee;
        if (fee != 0 && _transientContextHash == keccak256(msg.data))
            return _singleQuote(fee);

        // 2. Specific: destination + recipient
        fee = uint256(_resolveStored(quotes[_destination][_recipient]));
        if (fee != 0) return _singleQuote(fee);

        // 3. Destination-only
        fee = uint256(_resolveStored(quotes[_destination][WILDCARD_RECIPIENT]));
        if (fee != 0) return _singleQuote(fee);

        // 4. Recipient-only
        fee = uint256(_resolveStored(quotes[WILDCARD_DEST][_recipient]));
        if (fee != 0) return _singleQuote(fee);

        // 5. CCIP-Read
        revert OffchainLookup(
            address(this),
            _urls,
            msg.data,
            this.submitQuote.selector,
            ""
        );
    }

    // ============ Fee Collection ============

    function claim() external {
        if (feeToken == address(0)) {
            payable(beneficiary).sendValue(address(this).balance);
        } else {
            IERC20(feeToken).safeTransfer(
                beneficiary,
                IERC20(feeToken).balanceOf(address(this))
            );
        }
    }

    receive() external payable {}

    // ============ View ============

    function urls() external view returns (string[] memory) {
        return _urls;
    }

    // ============ Internal ============

    function _quoteSigner() internal view override returns (address) {
        return quoteSigner;
    }

    function _singleQuote(
        uint256 fee
    ) internal view returns (Quote[] memory result) {
        result = new Quote[](1);
        result[0] = Quote(feeToken, fee);
    }

    function _storeTransient(SignedQuote calldata sq) internal override {
        _transientFee = uint256(sq.data);
        _transientContextHash = keccak256(sq.context);
    }

    function _resolveStored(
        StoredQuote storage sq
    ) internal view returns (bytes32) {
        if (sq.expiry > 0 && uint48(block.timestamp) <= sq.expiry) {
            return sq.data;
        }
        return bytes32(0);
    }

    function _storeStanding(SignedQuote calldata sq) internal override {
        (uint32 dest, bytes32 recipient, ) = abi.decode(
            sq.context[4:],
            (uint32, bytes32, uint256)
        );
        StoredQuote storage existing = quotes[dest][recipient];
        if (sq.issuedAt <= existing.issuedAt) revert StaleQuote();
        quotes[dest][recipient] = StoredQuote(sq.data, sq.issuedAt, sq.expiry);
    }
}
