// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Pocket Money spend inbox
/// @notice Lets the guard on Reactive see spending on chains Reactive can't watch (Sui first).
/// A trusted attester watches the agent's payments there and reports each one here, once; the
/// guard subscribes to ForeignSpend and books it against the same household budget.
/// Trust assumption, stated plainly: the attester can report false spends (which only ever
/// tighten the budget or freeze the agent) or stay silent (which the float still bounds).
contract SpendInbox {
    error NotAttester();
    error AlreadyReported(bytes32 ref);
    error ZeroAttester();

    /// @param payee  the payee on the source chain (a Sui address is 32 bytes)
    /// @param source short label of the source chain, e.g. "sui:testnet"
    /// @param ref    the source chain's tx id (a Sui digest is 32 bytes)
    event ForeignSpend(address indexed agent, bytes32 indexed payee, uint256 amount, bytes32 source, bytes32 ref);

    address public immutable attester;
    mapping(bytes32 => bool) public reported;

    constructor(address attester_) {
        if (attester_ == address(0)) revert ZeroAttester();
        attester = attester_;
    }

    function report(address agent, bytes32 payee, uint256 amount, bytes32 source, bytes32 ref) external {
        if (msg.sender != attester) revert NotAttester();
        if (reported[ref]) revert AlreadyReported(ref);
        reported[ref] = true;
        emit ForeignSpend(agent, payee, amount, source, ref);
    }
}
