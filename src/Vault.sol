// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Circle CCTP v2 TokenMessenger (only the call we use).
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/// @title Pocket Money vault (one per chain)
/// @notice Holds the owner's USDC and, on the guard's word:
///  - tops up each agent's float (capped here by the agent's real balance, so even a buggy guard
///    can never push an agent above its float),
///  - keeps a local mirror of each agent's cross-chain budget, so any x402 facilitator on this
///    chain can call canSpend() BEFORE settling and refuse an over-budget payment,
///  - sends liquidity to a sibling vault over Circle CCTP, but only to peers the owner approved
///    and only up to an owner-set cap, so a compromised guard can't drain it.
contract Vault is AbstractCallback {
    error NotOwner();

    struct Budget {
        uint256 allowance;
        uint256 spent;
        uint256 dayEnds;
    }

    event TopUp(address indexed agent, uint64 indexed seq, uint256 requested, uint256 sent, uint256 agentBalance);
    event TopUpSkipped(address indexed agent, uint64 indexed seq, bytes32 reason);
    event BudgetSynced(address indexed agent, uint64 indexed version, uint256 agentLeft, uint256 householdLeft);
    event Frozen(bytes32 reason);
    event AgentFrozen(address indexed agent, bytes32 reason);
    event Unfrozen(address indexed agent); // agent = 0 means the whole vault
    /// @notice Watched by the guard on Reactive: a panic on any chain stops top-ups everywhere.
    event Panic(address indexed by);
    event FloatSet(address indexed agent, uint256 float);
    event PeerSet(uint32 indexed domain, bytes32 vault);
    event RebalanceCapSet(uint256 cap);
    event RebalanceSent(uint32 indexed destDomain, bytes32 indexed destVault, uint256 amount);
    event RebalanceDeclined(uint32 indexed destDomain, uint256 amount, bytes32 reason);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Migrated(address indexed to, uint256 usdc, uint256 eth);

    uint32 internal constant FAST_FINALITY = 1000;

    address public immutable owner;
    IERC20Min public immutable usdc;
    ITokenMessengerV2 public immutable tokenMessenger;

    mapping(address => uint256) public floatOf;
    mapping(address => bool) public agentFrozen;
    uint64 public lastSeq;
    bool public frozen;

    mapping(address => Budget) public budgetOf;
    uint256 public ceiling;
    uint256 public householdSpent;
    uint64 public syncVersion;
    uint256 public syncedAt;

    mapping(uint32 => bytes32) public peerOf;
    uint256 public rebalanceCap;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyGuard(address guard_) {
        _onlyServiceProvider();
        _onlyCallbackSender(guard_);
        _;
    }

    /// @param callbackProxy_ Reactive callback proxy on this chain.
    /// @param guard_ The PocketMoney reactive contract allowed to send callbacks (immutable).
    /// @param tokenMessenger_ Circle CCTP v2 TokenMessenger on this chain (0 disables rebalancing).
    constructor(IPayable callbackProxy_, address guard_, IERC20Min usdc_, ITokenMessengerV2 tokenMessenger_)
        payable
        AbstractCallback(callbackProxy_, guard_)
    {
        owner = msg.sender;
        usdc = usdc_;
        tokenMessenger = tokenMessenger_;
    }

    // ---- read side: for x402 facilitators and the dashboard ----

    /// @notice What this agent may still spend today across every chain, per the latest mirror.
    function spendLeft(address agent) public view returns (uint256) {
        Budget memory b = budgetOf[agent];
        if (block.timestamp >= b.dayEnds) return _min(b.allowance, ceiling); // a new day has begun
        return _min(_left(b.allowance, b.spent), _left(ceiling, householdSpent));
    }

    /// @notice Check before settling: would this payment be within the agent's cross-chain budget?
    function canSpend(address agent, uint256 amount) external view returns (bool ok, uint256 left, bytes32 reason) {
        left = spendLeft(agent);
        if (floatOf[agent] == 0) return (false, left, "unknown agent");
        if (frozen) return (false, left, "frozen");
        if (agentFrozen[agent]) return (false, left, "agent frozen");
        if (amount > left) return (false, left, "over budget");
        return (true, left, "");
    }

    // ---- callbacks from the guard (first argument is injected by the proxy) ----

    /// @notice Replace what an agent just spent, up to its float.
    function topUp(address guard_, address agent, uint256 amount, uint64 seq) external onlyGuard(guard_) {
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

    /// @notice Mirror of one agent's cross-chain budget. Older versions are ignored.
    function syncBudget(
        address guard_,
        address agent,
        uint256 allowance,
        uint256 agentSpent,
        uint256 ceiling_,
        uint256 householdSpent_,
        uint256 dayEnds,
        uint64 version
    ) external onlyGuard(guard_) {
        if (version <= syncVersion) return;
        syncVersion = version;
        syncedAt = block.timestamp;
        budgetOf[agent] = Budget(allowance, agentSpent, dayEnds);
        ceiling = ceiling_;
        householdSpent = householdSpent_;
        emit BudgetSynced(agent, version, _left(allowance, agentSpent), _left(ceiling_, householdSpent_));
    }

    /// @notice One agent paid someone off the list somewhere: stop topping it up here.
    function freezeAgent(address guard_, address agent, bytes32 reason) external onlyGuard(guard_) {
        agentFrozen[agent] = true;
        emit AgentFrozen(agent, reason);
    }

    /// @notice A panic somewhere: stop topping anyone up here.
    function freeze(address guard_, bytes32 reason) external onlyGuard(guard_) {
        frozen = true;
        emit Frozen(reason);
    }

    /// @notice Send liquidity to a sibling vault over CCTP, within the owner's limits.
    function rebalance(address guard_, uint32 destDomain, uint256 amount, uint256 maxFee) external onlyGuard(guard_) {
        bytes32 dest = peerOf[destDomain];
        bytes32 why;
        if (address(tokenMessenger) == address(0)) why = "no cctp";
        else if (dest == 0) why = "not a peer";
        else if (frozen) why = "frozen";
        else if (amount > rebalanceCap) why = "over cap";
        else if (amount > usdc.balanceOf(address(this))) why = "short";
        if (why != 0) {
            emit RebalanceDeclined(destDomain, amount, why);
            return;
        }
        usdc.approve(address(tokenMessenger), amount);
        // destinationCaller 0: anyone may relay Circle's attestation and complete the mint.
        tokenMessenger.depositForBurn(amount, destDomain, dest, address(usdc), bytes32(0), maxFee, FAST_FINALITY);
        emit RebalanceSent(destDomain, dest, amount);
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

    /// @notice Approve a sibling vault (by CCTP domain) as a rebalancing destination.
    function setPeer(uint32 domain, address vault) external onlyOwner {
        peerOf[domain] = bytes32(uint256(uint160(vault)));
        emit PeerSet(domain, peerOf[domain]);
    }

    function setRebalanceCap(uint256 cap) external onlyOwner {
        rebalanceCap = cap;
        emit RebalanceCapSet(cap);
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

    function _left(uint256 cap, uint256 used) private pure returns (uint256) {
        return used >= cap ? 0 : cap - used;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
