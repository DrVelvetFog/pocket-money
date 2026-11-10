// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title Pocket Money vault (one per chain)
/// @notice Holds the owner's USDC and tops up one agent's float when Reactive says so.
/// The float cap is enforced here, on this chain, from the agent's real balance, so even a
/// buggy or compromised guard can never push the agent above `float`.
contract Vault is AbstractCallback {
    error NotOwner();
    error WrongAgent(address agent);

    event TopUp(uint64 indexed seq, uint256 requested, uint256 sent, uint256 agentBalance);
    event TopUpSkipped(uint64 indexed seq, bytes32 reason);
    event Frozen(bytes32 reason);
    event Unfrozen();
    /// @notice Watched by the guard on Reactive: a panic on any chain stops top-ups everywhere.
    event Panic(address indexed by);
    event FloatChanged(uint256 float);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    address public immutable owner;
    IERC20Min public immutable usdc;
    address public immutable agent;

    uint256 public float;
    uint64 public lastSeq;
    bool public frozen;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param callbackProxy_ Reactive callback proxy on this chain.
    /// @param guard_ The PocketMoney reactive contract allowed to send callbacks (immutable).
    constructor(
        IPayable callbackProxy_,
        address guard_,
        IERC20Min usdc_,
        address agent_,
        uint256 float_
    ) payable AbstractCallback(callbackProxy_, guard_) {
        owner = msg.sender;
        usdc = usdc_;
        agent = agent_;
        float = float_;
    }

    /// @notice Callback from the guard: replace what the agent just spent, up to the float.
    /// @dev First argument is overwritten by the proxy with the requesting reactive contract.
    function topUp(address guard_, address agent_, uint256 amount, uint64 seq)
        external
        onlyServiceProvider
        onlyCallbackSender(guard_)
    {
        if (agent_ != agent) revert WrongAgent(agent_);
        // Monotonic, not strictly sequential: replays and stale top-ups are dropped, but a
        // failed delivery (gap) can't wedge every later top-up.
        if (seq <= lastSeq) {
            emit TopUpSkipped(seq, "stale");
            return;
        }
        lastSeq = seq;
        if (frozen) {
            emit TopUpSkipped(seq, "frozen");
            return;
        }

        uint256 bal = usdc.balanceOf(agent);
        uint256 room = bal >= float ? 0 : float - bal;
        uint256 send = _min(_min(amount, room), usdc.balanceOf(address(this)));
        if (send > 0 && !usdc.transfer(agent, send)) revert TransferFailed();
        emit TopUp(seq, amount, send, bal + send);
    }

    /// @notice Callback from the guard: the agent paid someone off the list somewhere.
    function freeze(address guard_, bytes32 reason)
        external
        onlyServiceProvider
        onlyCallbackSender(guard_)
    {
        frozen = true;
        emit Frozen(reason);
    }

    // ---- owner ----

    function panic() external onlyOwner {
        frozen = true;
        emit Panic(msg.sender);
        emit Frozen("panic");
    }

    function unfreeze() external onlyOwner {
        frozen = false;
        emit Unfrozen();
    }

    function setFloat(uint256 float_) external onlyOwner {
        float = float_;
        emit FloatChanged(float_);
    }

    /// @notice Recover USDC (or move it to a replacement vault). token = 0 means native ETH.
    function withdraw(address token, address payable to, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert TransferFailed();
        } else if (!IERC20Min(token).transfer(to, amount)) {
            revert TransferFailed();
        }
        emit Withdrawn(token, to, amount);
    }

    /// @notice Anyone may settle this vault's callback debt from its own ETH balance.
    function coverDebt() external {
        _coverDebt();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
