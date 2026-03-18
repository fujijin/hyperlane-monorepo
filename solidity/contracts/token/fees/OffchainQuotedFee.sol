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
 *      Quote data: abi.encode(uint256 maxFee, uint256 halfAmount).
 *      Fee = min(maxFee, amount * maxFee / (2 * halfAmount)).
 *      Same formula as LinearFee. data == empty = no quote.
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
    uint256 constant WILDCARD_AMOUNT = type(uint256).max;

    // ============ Immutables ============

    address public immutable feeToken;
    address public immutable beneficiary;

    // ============ Structs ============

    struct StoredQuote {
        uint256 maxFee;
        uint256 halfAmount;
        uint48 issuedAt;
        uint48 expiry;
    }

    // ============ Storage ============

    mapping(uint32 => mapping(bytes32 => StoredQuote)) public quotes;
    string[] internal _urls;

    // ============ Transient Storage ============

    uint256 private transient quotedMaxFee;
    uint256 private transient quotedHalfAmount;
    uint32 private transient quotedDestination;
    bytes32 private transient quotedRecipient;
    uint256 private transient quotedAmount;

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
        _addQuoteSigner(_quoteSigner);
        feeToken = _feeToken;
        beneficiary = _beneficiary;
        _urls = __urls;
    }

    // ============ ITokenFee ============

    /// @inheritdoc ITokenFee
    function quoteTransferRemote(
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount
    ) external view override returns (Quote[] memory) {
        // 1. Transient — match individual context fields
        uint256 fee;
        if (
            quotedMaxFee != 0 &&
            (quotedDestination == WILDCARD_DEST ||
                quotedDestination == _destination) &&
            (quotedRecipient == WILDCARD_RECIPIENT ||
                quotedRecipient == _recipient) &&
            (quotedAmount == WILDCARD_AMOUNT || quotedAmount == _amount)
        )
            return
                _singleQuote(
                    _computeFee(quotedMaxFee, quotedHalfAmount, _amount)
                );

        // 2. Specific: destination + recipient
        fee = _resolveStored(quotes[_destination][_recipient], _amount);
        if (fee != 0) return _singleQuote(fee);

        // 3. Destination-only
        fee = _resolveStored(quotes[_destination][WILDCARD_RECIPIENT], _amount);
        if (fee != 0) return _singleQuote(fee);

        // 4. Recipient-only
        fee = _resolveStored(quotes[WILDCARD_DEST][_recipient], _amount);
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

    function _singleQuote(
        uint256 fee
    ) internal view returns (Quote[] memory result) {
        result = new Quote[](1);
        result[0] = Quote(feeToken, fee);
    }

    function _storeTransient(SignedQuote calldata sq) internal override {
        (quotedMaxFee, quotedHalfAmount) = abi.decode(
            sq.data,
            (uint256, uint256)
        );
        (quotedDestination, quotedRecipient, quotedAmount) = abi.decode(
            sq.context[4:],
            (uint32, bytes32, uint256)
        );
    }

    function _resolveStored(
        StoredQuote storage sq,
        uint256 amount
    ) internal view returns (uint256) {
        if (sq.expiry > 0 && uint48(block.timestamp) <= sq.expiry) {
            return _computeFee(sq.maxFee, sq.halfAmount, amount);
        }
        return 0;
    }

    /// @dev Same formula as LinearFee: min(maxFee, amount * maxFee / (2 * halfAmount))
    function _computeFee(
        uint256 maxFee_,
        uint256 halfAmount_,
        uint256 amount
    ) internal pure returns (uint256) {
        uint256 uncapped = (amount * maxFee_) / (2 * halfAmount_);
        return uncapped > maxFee_ ? maxFee_ : uncapped;
    }

    function _storeStanding(SignedQuote calldata sq) internal override {
        (uint32 dest, bytes32 recipient, ) = abi.decode(
            sq.context[4:],
            (uint32, bytes32, uint256)
        );
        StoredQuote storage existing = quotes[dest][recipient];
        if (sq.issuedAt <= existing.issuedAt) revert StaleQuote();
        (uint256 maxFee_, uint256 halfAmount_) = abi.decode(
            sq.data,
            (uint256, uint256)
        );
        quotes[dest][recipient] = StoredQuote(
            maxFee_,
            halfAmount_,
            sq.issuedAt,
            sq.expiry
        );
    }
}
