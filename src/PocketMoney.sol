// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title Pocket Money guard (lives on Reactive Network)
/// @notice House rules for a household of AI agents, across every chain they spend on.
///  - Each agent has a daily allowance; the household shares one daily ceiling.
///  - Every USDC payment an agent makes on any watched chain is booked here, chained into a
///    receipt hash, and the paying chain's vault tops the agent's float back up.
///  - Every vault keeps a mirror of each agent's remaining budget, pushed from here after each
///    booking, so x402 facilitators can refuse an over-budget payment before it settles.
///  - Spending on chains Reactive can't watch (Sui) arrives through a SpendInbox and counts the same.
///  - Paying anyone off the approved list freezes that agent on every chain; a panic on any chain
///    freezes everything.
///  - Each vault's USDC is tracked from its transfers; when one runs low, the fullest sibling
///    sends it liquidity over Circle CCTP.
contract PocketMoney is AbstractReactive {
    error NotOwner();
    error UnknownAgent(address agent);

    uint256 internal constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 internal constant PANIC_TOPIC = uint256(keccak256("Panic(address)"));
    uint256 internal constant RAISE_TOPIC = uint256(keccak256("RaiseApproved(address,uint256,address)"));
    uint256 internal constant FOREIGN_TOPIC = uint256(keccak256("ForeignSpend(address,bytes32,uint256,bytes32,bytes32)"));
    uint256 internal constant SYNC_TOPIC = uint256(keccak256("SyncRequested(address)"));
    /// @dev Cron10000 (~3h) from the system's legacy cron emitter, per dev.reactive.network.
    uint256 internal constant CRON_TOPIC =
        0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    address internal constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    /// @dev Callbacks bill gas used, not the limit, so a generous default costs nothing. Each
    /// destination's proxy withholds its own overhead first (150k on Ethereum Sepolia, 80k on
    /// Base and Unichain Sepolia), and a top-up there needs ~182k more, so 400k was too tight.
    uint64 internal constant DEFAULT_CALLBACK_GAS = 1_000_000;

    struct Chain {
        address usdc;
        address vault;
        uint32 domain; // Circle CCTP domain
    }

    struct Agent {
        bool known;
        bool quarantined;
        uint256 allowance;
        uint256 spentToday;
        uint256 toppedUpToday;
    }

    event Spent(
        address indexed agent,
        uint256 indexed chainId,
        bytes32 indexed payee,
        uint256 amount,
        uint256 txHash,
        uint256 receiptIndex,
        bytes32 receiptHead
    );
    event TopUpRequested(address indexed agent, uint256 indexed chainId, uint64 seq, uint256 amount);
    event Quarantined(address indexed agent, uint256 indexed chainId, bytes32 payee, uint256 txHash);
    event PanicSeen(uint256 indexed chainId, address indexed by, uint256 txHash);
    event Synced(address indexed agent, uint64 indexed version, uint256 agentLeft, uint256 householdLeft);
    /// @notice Emitted by the owner's calls; the guard subscribes to itself so the sync happens
    /// inside react(), the path where callbacks are guaranteed to be delivered.
    event SyncRequested(address indexed agent); // agent = 0 means everyone
    event VaultBalance(uint256 indexed chainId, uint256 balance);
    event RebalanceRequested(uint256 indexed fromChain, uint256 indexed toChain, uint256 amount);
    event RebalanceLanded(uint256 indexed chainId, uint256 amount);
    event RebalanceSkipped(uint256 indexed chainId, bytes32 reason);
    event Statement(
        uint256 indexed day, uint256 spent, uint256 toppedUp, uint256 receiptCount, bytes32 receiptHead
    );
    event AgentStatement(uint256 indexed day, address indexed agent, uint256 spent, uint256 toppedUp);
    event ChainAdded(uint256 indexed chainId, address usdc, address vault, uint32 domain);
    event InboxAdded(uint256 indexed chainId, address inbox);
    event AgentSet(address indexed agent, uint256 allowance);
    event PayeeSet(bytes32 indexed payee, bool approved);
    event CeilingSet(uint256 ceiling);
    event RaiseGranted(address indexed agent, uint256 indexed chainId, uint256 amount, uint256 txHash);
    event RebalancePolicySet(uint256 lowWater, uint256 target, uint256 maxFee);
    event CronSet(bool on);
    event CallbackGasSet(uint256 indexed chainId, uint64 gasLimit);
    event Resumed(address indexed agent); // agent = 0 means the household-wide panic

    address public immutable owner;

    uint256 public ceiling;
    uint256 public day;
    uint256 public dayStart;
    uint256 public spentToday;
    uint256 public toppedUpToday;
    bool public panicked;

    bytes32 public receiptHead;
    uint256 public receiptCount;
    uint64 public syncVersion;

    mapping(address => Agent) public agents;
    address[] public agentList;
    /// @dev Payees are bytes32 so a Sui address (32 bytes) and an EVM address share one list.
    mapping(bytes32 => bool) public approvedPayee;
    mapping(uint256 => Chain) public chains;
    uint256[] public chainIds;
    mapping(uint256 => uint64) public seqOf;
    mapping(uint256 => uint64) public rebalanceSeqOf;
    mapping(uint256 => uint64) public callbackGasOf;
    mapping(uint256 => address) public inboxOf;
    /// @dev One-day raises the owner approves from any chain; cleared at the daily rollover.
    mapping(address => uint256) public extraToday;
    uint256 public householdExtraToday;

    mapping(uint256 => uint256) public vaultBalanceOf;
    mapping(uint256 => bool) public rebalancing;
    uint256 public lowWater;
    uint256 public targetLevel;
    uint256 public maxRebalanceFee;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 ceiling_) payable {
        owner = msg.sender;
        ceiling = ceiling_;
        dayStart = block.timestamp;
        SYSTEM.subscribe(block.chainid, address(this), SYNC_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    // ---- reactive entry point ----

    function react(LogRecord calldata log_) external onlySystem {
        _roll();
        uint256 t = log_.topic0;
        if (t == TRANSFER_TOPIC) _onTransfer(log_);
        else if (t == FOREIGN_TOPIC) _onForeign(log_);
        else if (t == PANIC_TOPIC) _onPanic(log_);
        else if (t == RAISE_TOPIC) _onRaise(log_);
        else if (t == SYNC_TOPIC && log_.contractAddress == address(this)) _onSyncRequest(address(uint160(log_.topic1)));
        // CRON_TOPIC needs nothing beyond _roll(). Unknown logs fall through at no extra cost.
    }

    function _onTransfer(LogRecord calldata log_) internal {
        uint256 id = log_.chainId;
        Chain memory c = chains[id];
        if (c.usdc == address(0) || log_.contractAddress != c.usdc) return;
        address from = address(uint160(log_.topic1));
        address to = address(uint160(log_.topic2));
        uint256 amount = abi.decode(log_.data, (uint256));

        if (to == c.vault) _vaultIn(id, from, amount);
        if (from == c.vault) _vaultOut(id, amount);
        if (agents[from].known) {
            if (_book(from, id, bytes32(uint256(uint160(to))), amount, log_.txHash, log_.logIndex)) {
                _topUp(from, id, c.vault, amount);
            }
            _sync(from);
        }
    }

    function _onForeign(LogRecord calldata log_) internal {
        if (log_.contractAddress != inboxOf[log_.chainId] || log_.contractAddress == address(0)) return;
        address agent = address(uint160(log_.topic1));
        if (!agents[agent].known) return;
        (uint256 amount,, bytes32 ref) = abi.decode(log_.data, (uint256, bytes32, bytes32));
        // No vault on the foreign chain, so there's nothing to top up: book, maybe freeze, mirror.
        _book(agent, log_.chainId, bytes32(log_.topic2), amount, uint256(ref), 0);
        _sync(agent);
    }

    /// @dev Books a payment; returns true when it may be topped up.
    function _book(address agentAddr, uint256 chainId, bytes32 payee, uint256 amount, uint256 txHash, uint256 logIndex)
        internal
        returns (bool)
    {
        Agent storage a = agents[agentAddr];
        a.spentToday += amount;
        spentToday += amount;
        receiptHead = keccak256(abi.encode(receiptHead, chainId, txHash, logIndex, agentAddr, payee, amount));
        emit Spent(agentAddr, chainId, payee, amount, txHash, receiptCount++, receiptHead);

        if (!approvedPayee[payee]) {
            if (!a.quarantined) {
                a.quarantined = true;
                emit Quarantined(agentAddr, chainId, payee, txHash);
                _toAllVaults(
                    abi.encodeWithSignature(
                        "freezeAgent(address,address,bytes32)", address(0), agentAddr, bytes32("unknown payee")
                    )
                );
            }
            return false;
        }
        return !(a.quarantined || panicked);
    }

    function _topUp(address agentAddr, uint256 chainId, address vault, uint256 amount) internal {
        Agent storage a = agents[agentAddr];
        uint256 refill =
            _min(_min(amount, _left(_allowanceOf(agentAddr), a.toppedUpToday)), _left(_ceiling(), toppedUpToday));
        if (refill == 0) return;
        a.toppedUpToday += refill;
        toppedUpToday += refill;
        uint64 seq = ++seqOf[chainId];
        emit TopUpRequested(agentAddr, chainId, seq, refill);
        _callback(
            chainId,
            vault,
            abi.encodeWithSignature("topUp(address,address,uint256,uint64)", address(0), agentAddr, refill, seq)
        );
    }

    /// @dev Push one agent's budget to every vault (newer versions win there). Same field order as
    /// Vault.Mirror.
    function _sync(address agentAddr) internal {
        Agent storage a = agents[agentAddr];
        uint64 v = ++syncVersion;
        uint256 extra = extraToday[agentAddr];
        emit Synced(agentAddr, v, _left(a.allowance + extra, a.spentToday), _left(_ceiling(), spentToday));
        _toAllVaults(
            abi.encodeWithSignature(
                "syncBudget(address,address,(uint256,uint256,uint256,uint256,uint256,uint256,uint256),uint64)",
                address(0),
                agentAddr,
                a.allowance,
                extra,
                a.spentToday,
                ceiling,
                householdExtraToday,
                spentToday,
                dayStart + 1 days,
                v
            )
        );
    }

    function _onSyncRequest(address agentAddr) internal {
        if (agentAddr != address(0)) {
            if (agents[agentAddr].known) _sync(agentAddr);
            return;
        }
        for (uint256 i; i < agentList.length; ++i) _sync(agentList[i]);
    }

    function _onPanic(LogRecord calldata log_) internal {
        if (log_.contractAddress != chains[log_.chainId].vault) return;
        if (panicked) return;
        panicked = true;
        emit PanicSeen(log_.chainId, address(uint160(log_.topic1)), log_.txHash);
        _toAllVaults(abi.encodeWithSignature("freeze(address,bytes32)", address(0), bytes32("panic")));
    }

    /// @dev The owner approved a one-day raise on some chain's vault: lift that agent's allowance
    /// and the household ceiling for today, and re-sync every mirror so facilitators see it.
    function _onRaise(LogRecord calldata log_) internal {
        if (log_.contractAddress != chains[log_.chainId].vault) return;
        address agentAddr = address(uint160(log_.topic1));
        if (!agents[agentAddr].known) return;
        (uint256 amount,) = abi.decode(log_.data, (uint256, address));
        extraToday[agentAddr] += amount;
        householdExtraToday += amount;
        emit RaiseGranted(agentAddr, log_.chainId, amount, log_.txHash);
        _onSyncRequest(address(0)); // the household cap moved for everyone
    }

    function _allowanceOf(address agentAddr) internal view returns (uint256) {
        return agents[agentAddr].allowance + extraToday[agentAddr];
    }

    function _ceiling() internal view returns (uint256) {
        return ceiling + householdExtraToday;
    }

    // ---- liquidity ----

    function _vaultIn(uint256 chainId, address from, uint256 amount) internal {
        vaultBalanceOf[chainId] += amount;
        emit VaultBalance(chainId, vaultBalanceOf[chainId]);
        if (from == address(0) && rebalancing[chainId]) {
            rebalancing[chainId] = false; // a CCTP mint landed
            emit RebalanceLanded(chainId, amount);
        }
    }

    function _vaultOut(uint256 chainId, uint256 amount) internal {
        uint256 bal = vaultBalanceOf[chainId];
        vaultBalanceOf[chainId] = amount >= bal ? 0 : bal - amount;
        emit VaultBalance(chainId, vaultBalanceOf[chainId]);
        _maybeRebalance(chainId);
    }

    function _maybeRebalance(uint256 low) internal {
        uint256 bal = vaultBalanceOf[low];
        if (lowWater == 0 || rebalancing[low] || bal >= lowWater) return;
        uint256 need = targetLevel > bal ? targetLevel - bal : 0;
        if (need == 0) return;
        uint256 donor = 0;
        uint256 best = 0;
        uint256 n = chainIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 id = chainIds[i];
            if (id == low || rebalancing[id]) continue;
            uint256 b = vaultBalanceOf[id];
            if (b >= need + lowWater && b > best) (donor, best) = (id, b);
        }
        if (donor == 0) {
            emit RebalanceSkipped(low, "no donor");
            return;
        }
        rebalancing[low] = true;
        emit RebalanceRequested(donor, low, need);
        _callback(
            donor,
            chains[donor].vault,
            abi.encodeWithSignature(
                "rebalance(address,uint32,uint256,uint256,uint64)",
                address(0),
                chains[low].domain,
                need,
                maxRebalanceFee,
                ++rebalanceSeqOf[donor]
            )
        );
    }

    // ---- plumbing ----

    function _toAllVaults(bytes memory payload) internal {
        for (uint256 i; i < chainIds.length; ++i) {
            uint256 id = chainIds[i];
            _callback(id, chains[id].vault, payload);
        }
    }

    function _callback(uint256 chainId, address recipient, bytes memory payload) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: chainId, recipient: recipient, gasLimit: callbackGasOf[chainId], payload: payload
            })
        );
    }

    /// @dev Closes out any finished day: emits its statements and resets the counters.
    function _roll() internal {
        if (block.timestamp < dayStart + 1 days) return;
        emit Statement(day, spentToday, toppedUpToday, receiptCount, receiptHead);
        uint256 n = agentList.length;
        for (uint256 i; i < n; ++i) {
            Agent storage a = agents[agentList[i]];
            emit AgentStatement(day, agentList[i], a.spentToday, a.toppedUpToday);
            a.spentToday = 0;
            a.toppedUpToday = 0;
            extraToday[agentList[i]] = 0;
        }
        uint256 elapsed = (block.timestamp - dayStart) / 1 days;
        dayStart += elapsed * 1 days;
        day += elapsed;
        spentToday = 0;
        toppedUpToday = 0;
        householdExtraToday = 0;
    }

    function _left(uint256 cap, uint256 used) internal pure returns (uint256) {
        return used >= cap ? 0 : cap - used;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _watch(uint256 chainId, address usdc, uint256 from, uint256 to) internal {
        SYSTEM.subscribe(chainId, usdc, TRANSFER_TOPIC, from, to, REACTIVE_IGNORE);
    }

    // ---- owner (called directly on Reactive Network) ----

    /// @notice Register a chain: watch every agent's USDC payments there, the vault's USDC in and
    /// out, and the vault's panic button.
    function addChain(uint256 chainId, address usdc, address vault, uint32 domain) external onlyOwner {
        if (chains[chainId].vault == address(0)) {
            chainIds.push(chainId);
            callbackGasOf[chainId] = DEFAULT_CALLBACK_GAS;
        }
        chains[chainId] = Chain(usdc, vault, domain);
        for (uint256 i; i < agentList.length; ++i) _watch(chainId, usdc, uint256(uint160(agentList[i])), REACTIVE_IGNORE);
        _watch(chainId, usdc, uint256(uint160(vault)), REACTIVE_IGNORE);
        _watch(chainId, usdc, REACTIVE_IGNORE, uint256(uint160(vault)));
        SYSTEM.subscribe(chainId, vault, PANIC_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(chainId, vault, RAISE_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit ChainAdded(chainId, usdc, vault, domain);
    }

    /// @notice Watch a SpendInbox (on an EVM chain) that reports spending from chains Reactive can't see.
    function addInbox(uint256 chainId, address inbox) external onlyOwner {
        inboxOf[chainId] = inbox;
        SYSTEM.subscribe(chainId, inbox, FOREIGN_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit InboxAdded(chainId, inbox);
    }

    /// @notice Add an agent (watched on every registered chain) or change its daily allowance.
    function setAgent(address agent, uint256 allowance) external onlyOwner {
        Agent storage a = agents[agent];
        bool isNew = !a.known;
        a.known = true;
        a.allowance = allowance; // state first, then the system-contract calls
        if (isNew) {
            agentList.push(agent);
            uint256 n = chainIds.length;
            for (uint256 i; i < n; ++i) {
                _watch(chainIds[i], chains[chainIds[i]].usdc, uint256(uint160(agent)), REACTIVE_IGNORE);
            }
        }
        emit AgentSet(agent, allowance);
        emit SyncRequested(agent);
    }

    /// @notice Approve an EVM payee.
    function setPayee(address payee, bool approved) external onlyOwner {
        _setPayee(bytes32(uint256(uint160(payee))), approved);
    }

    /// @notice Approve a payee on a non-EVM chain (e.g. a 32-byte Sui address).
    function setForeignPayee(bytes32 payee, bool approved) external onlyOwner {
        _setPayee(payee, approved);
    }

    function _setPayee(bytes32 payee, bool approved) internal {
        approvedPayee[payee] = approved;
        emit PayeeSet(payee, approved);
    }

    function setCeiling(uint256 ceiling_) external onlyOwner {
        ceiling = ceiling_;
        emit CeilingSet(ceiling_);
        emit SyncRequested(address(0));
    }

    /// @notice Rebalance a vault below lowWater back up to target; 0 lowWater turns it off.
    function setRebalancePolicy(uint256 lowWater_, uint256 target_, uint256 maxFee_) external onlyOwner {
        (lowWater, targetLevel, maxRebalanceFee) = (lowWater_, target_, maxFee_);
        emit RebalancePolicySet(lowWater_, target_, maxFee_);
    }

    /// @notice Correct the tracked vault balance (e.g. funds that arrived before the chain was added).
    function noteVaultBalance(uint256 chainId, uint256 balance) external onlyOwner {
        vaultBalanceOf[chainId] = balance;
        rebalancing[chainId] = false;
        emit VaultBalance(chainId, balance);
    }

    function setCallbackGas(uint256 chainId, uint64 gasLimit) external onlyOwner {
        callbackGasOf[chainId] = gasLimit;
        emit CallbackGasSet(chainId, gasLimit);
    }

    /// @notice Daily statements on the network's ~3h cron. Billed every tick, so it can be paused.
    function setCron(bool on) external onlyOwner {
        if (on) {
            SYSTEM.subscribe(block.chainid, CRON_SOURCE, CRON_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        } else {
            SYSTEM.unsubscribe(block.chainid, CRON_SOURCE, CRON_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }
        emit CronSet(on);
    }

    /// @notice Push every agent's budget to every vault again (e.g. after changing allowances).
    function resync() external onlyOwner {
        emit SyncRequested(address(0));
    }

    /// @notice Lift one agent's quarantine here. Each vault's owner still unfreezes that agent there.
    function resumeAgent(address agent) external onlyOwner {
        if (!agents[agent].known) revert UnknownAgent(agent);
        agents[agent].quarantined = false;
        emit Resumed(agent);
    }

    /// @notice Lift the household-wide panic here. Each vault's owner still unfreezes there.
    function resume() external onlyOwner {
        panicked = false;
        emit Resumed(address(0));
    }

    function withdraw(address payable to, uint256 amount) external onlyOwner {
        _pay(to, amount);
    }

    function coverDebt() external {
        _coverDebt();
    }

    function chainCount() external view returns (uint256) {
        return chainIds.length;
    }

    function agentCount() external view returns (uint256) {
        return agentList.length;
    }
}
