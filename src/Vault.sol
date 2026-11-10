// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title Pocket Money vault (one per chain)
/// @notice Holds the owner's USDC and tops up each agent's float when the guard on Reactive asks.
/// The float cap is enforced here, on this chain, from the agent's real balance, so even a
/// buggy or compromised guard can never push an agent above its float.
contract Vault is AbstractCallback {
    error NotOwner();

    event TopUp(address indexed agent, uint64 indexed seq, uint256 requested, uint256 sent, uint256 agentBalance);
    event TopUpSkipped(address indexed agent, uint64 indexed seq, bytes32 reason);
    event Frozen(bytes32 reason);
    event AgentFrozen(address indexed agent, bytes32 reason);
    event Unfrozen(address indexed agent); // agent = 0 means the whole vault
    /// @notice Watched by the guard on Reactive: a panic on any chain stops top-ups everywhere.
    event Panic(address indexed by);
    event FloatSet(address indexed agent, uint256 float);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Migrated(address indexed to, uint256 usdc, uint256 eth);

    address public immutable owner;
    IERC20Min public immutable usdc;

    mapping(address => uint256) public floatOf;
    mapping(address => bool) public agentFrozen;
    uint64 public lastSeq;
    bool public frozen;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param callbackProxy_ Reactive callback proxy on this chain.
    /// @param guard_ The PocketMoney reactive contract allowed to send callbacks (immutable).
    constructor(IPayable callbackProxy_, address guard_, IERC20Min usdc_)
        payable
        AbstractCallback(callbackProxy_, guard_)
    {
        owner = msg.sender;
        usdc = usdc_;
    }

    // ---- callbacks from the guard (first argument is injected by the proxy) ----

    /// @notice Replace what an agent just spent, up to its float.
    function topUp(address guard_, address agent, uint256 amount, uint64 seq)
        external
        onlyServiceProvider
        onlyCallbackSender(guard_)
    {
        // Monotonic, not strictly sequential: replays and stale top-ups are dropped, but a
        // failed delivery (gap) can't wedge every later top-up.
        bytes32 skip;
        if (seq <= lastSeq) skip = "stale";
        else lastSeq = seq;
        uint256 float = floatOf[agent];
        if (skip == 0 && float == 0) skip = "unknown agent";
        if (skip == 0 && frozen) skip = "frozen";
        if (skip == 0 && agentFrozen[agent]) skip = "agent frozen";
        if (skip != 0) {
            emit TopUpSkipped(agent, seq, skip);
            return;
        }

        uint256 bal = usdc.balanceOf(agent);
        uint256 room = bal >= float ? 0 : float - bal;
        uint256 send = _min(_min(amount, room), usdc.balanceOf(address(this)));
        if (send > 0 && !usdc.transfer(agent, send)) revert TransferFailed();
        emit TopUp(agent, seq, amount, send, bal + send);
    }

    /// @notice One agent paid someone off the list somewhere: stop topping it up here.
    function freezeAgent(address guard_, address agent, bytes32 reason)
        external
        onlyServiceProvider
        onlyCallbackSender(guard_)
    {
        agentFrozen[agent] = true;
        emit AgentFrozen(agent, reason);
    }

    /// @notice A panic somewhere: stop topping anyone up here.
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
        emit Unfrozen(address(0));
    }

    function unfreezeAgent(address agent) external onlyOwner {
        agentFrozen[agent] = false;
        emit Unfrozen(agent);
    }

    function setFloat(address agent, uint256 float) external onlyOwner {
        floatOf[agent] = float;
        emit FloatSet(agent, float);
    }

    /// @notice Recover funds. token = 0 means native ETH.
    function withdraw(address token, address payable to, uint256 amount) external onlyOwner {
        _send(token, to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Hand everything to a replacement vault and stop. Logged, so a mid-run fix is
    /// visible on-chain rather than a silent restart.
    function migrate(address payable to) external onlyOwner {
        frozen = true;
        uint256 u = usdc.balanceOf(address(this));
        uint256 e = address(this).balance;
        _send(address(usdc), to, u);
        _send(address(0), to, e);
        emit Migrated(to, u, e);
    }

    /// @notice Anyone may settle this vault's callback debt from its own ETH balance.
    function coverDebt() external {
        _coverDebt();
    }

    function _send(address token, address payable to, uint256 amount) private {
        if (amount == 0) return;
        if (token == address(0)) {
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert TransferFailed();
        } else if (!IERC20Min(token).transfer(to, amount)) {
            revert TransferFailed();
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
