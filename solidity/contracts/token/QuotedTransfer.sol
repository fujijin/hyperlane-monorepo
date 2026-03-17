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

import {AbstractOffchainQuoter} from "../libs/AbstractOffchainQuoter.sol";
import {ITokenBridge, Quote} from "../interfaces/ITokenBridge.sol";
import {PackageVersioned} from "../PackageVersioned.sol";
import {TokenRouter} from "./libs/TokenRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title QuotedTransfer
 * @notice Atomically submits offchain-signed quotes and calls transferRemote.
 * @dev Stateless helper — submits transient quotes then forwards the
 *      transferRemote call so the warp route resolves fees in the same tx.
 *
 *      For ERC20 warp routes the caller must approve this contract for
 *      the total token amount (bridge amount + fees). Excess is refunded.
 */
contract QuotedTransfer is PackageVersioned {
    using SafeERC20 for IERC20;
    using Address for address payable;

    struct QuoteSubmission {
        address quoter;
        AbstractOffchainQuoter.SignedQuote quote;
        bytes signature;
    }

    /**
     * @notice Submit quotes and transfer tokens in a single transaction.
     * @param _warpRoute The warp route to call transferRemote on.
     * @param _destination The destination domain.
     * @param _recipient The recipient address on the destination chain.
     * @param _amount The token amount to bridge.
     * @param _quotes Signed quotes to submit before transferring.
     * @return messageId The dispatched message ID.
     */
    function transferRemote(
        address _warpRoute,
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount,
        QuoteSubmission[] calldata _quotes
    ) external payable returns (bytes32 messageId) {
        // 1. Submit all quotes (sets transient state on quoters)
        for (uint256 i; i < _quotes.length; ++i) {
            AbstractOffchainQuoter(_quotes[i].quoter).submitQuote(
                _quotes[i].quote,
                _quotes[i].signature
            );
        }

        // 2. Pull ERC20 tokens from caller if needed
        address token = TokenRouter(payable(_warpRoute)).token();
        if (token != address(0)) {
            uint256 allowance = IERC20(token).allowance(
                msg.sender,
                address(this)
            );
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                allowance
            );
            if (IERC20(token).allowance(address(this), _warpRoute) == 0)
                IERC20(token).forceApprove(_warpRoute, type(uint256).max);
        }

        // 3. Execute transfer
        messageId = ITokenBridge(_warpRoute).transferRemote{value: msg.value}(
            _destination,
            _recipient,
            _amount
        );

        // 4. Refund excess tokens and native value
        if (token != address(0)) {
            uint256 remaining = IERC20(token).balanceOf(address(this));
            if (remaining > 0)
                IERC20(token).safeTransfer(msg.sender, remaining);
        }
        if (address(this).balance > 0)
            payable(msg.sender).sendValue(address(this).balance);
    }

    /**
     * @notice Submit quotes then query the warp route's fee breakdown.
     * @dev Not a view — writes transient state. Call via eth_call to simulate.
     * @param _warpRoute The warp route to quote.
     * @param _destination The destination domain.
     * @param _recipient The recipient address on the destination chain.
     * @param _amount The token amount to bridge.
     * @param _quotes Signed quotes to submit before quoting.
     * @return quotes The warp route's fee breakdown (gas, fee, bridge amount).
     */
    function quoteTransferRemote(
        address _warpRoute,
        uint32 _destination,
        bytes32 _recipient,
        uint256 _amount,
        QuoteSubmission[] calldata _quotes
    ) external returns (Quote[] memory quotes) {
        for (uint256 i; i < _quotes.length; ++i) {
            AbstractOffchainQuoter(_quotes[i].quoter).submitQuote(
                _quotes[i].quote,
                _quotes[i].signature
            );
        }
        return
            TokenRouter(payable(_warpRoute)).quoteTransferRemote(
                _destination,
                _recipient,
                _amount
            );
    }

    receive() external payable {}
}
