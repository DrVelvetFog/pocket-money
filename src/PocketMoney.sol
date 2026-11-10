// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title Pocket Money guard (lives on Reactive Network)
/// @notice House rules for a household of AI agents, across every chain they spend on. Each agent
/// has its own daily allowance, and the household shares one daily ceiling. The guard watches
/// each agent's USDC transfers on every chain, books them, and asks that chain's vault to top the
/// agent's float back up while allowance remains. Paying anyone off the approved list freezes
/// that agent on every chain; a panic on any chain freezes everything everywhere.
contract PocketMoney is AbstractReactive {
    error NotOwner();
    error UnknownAgent(address agent);

    uint256 internal constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 internal constant PANIC_TOPIC = uint256(keccak256("Panic(address)"));
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
        address indexed payee,
        uint256 amount,
        uint256 txHash,
        uint256 receiptIndex,
        bytes32 receiptHead
    );
    event TopUpRequested(address indexed agent, uint256 indexed chainId, uint64 seq, uint256 amount);
    event Quarantined(address indexed agent, uint256 indexed chainId, address payee, uint256 txHash);
    event PanicSeen(uint256 indexed chainId, address indexed by, uint256 txHash);
    event Statement(
        uint256 indexed day, uint256 spent, uint256 toppedUp, uint256 receiptCount, bytes32 receiptHead
    );
    event AgentStatement(uint256 indexed day, address indexed agent, uint256 spent, uint256 toppedUp);
    event ChainAdded(uint256 indexed chainId, address usdc, address vault);
    event AgentSet(address indexed agent, uint256 allowance);
    event PayeeSet(address indexed payee, bool approved);
    event CeilingSet(uint256 ceiling);
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

    mapping(address => Agent) public agents;
    address[] public agentList;
    mapping(address => bool) public approvedPayee;
    mapping(uint256 => Chain) public chains;
    uint256[] public chainIds;
    mapping(uint256 => uint64) public seqOf;
    mapping(uint256 => uint64) public callbackGasOf;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint256 ceiling_) payable {
        owner = msg.sender;
        ceiling = ceiling_;
        dayStart = block.timestamp;
    }

    // ---- reactive entry point ----

    function react(LogRecord calldata log_) external onlySystem {
        _roll();
        if (log_.topic0 == TRANSFER_TOPIC) {
            _onTransfer(log_);
        } else if (log_.topic0 == PANIC_TOPIC) {
            _onPanic(log_);
        }
        // CRON_TOPIC needs nothing beyond _roll(). Unknown logs fall through at no extra cost.
    }

    function _onTransfer(LogRecord calldata log_) internal {
        Chain memory c = chains[log_.chainId];
        if (c.usdc == address(0) || log_.contractAddress != c.usdc) return;
        address agentAddr = address(uint160(log_.topic1));
        Agent storage a = agents[agentAddr];
        if (!a.known) return;

        address payee = address(uint160(log_.topic2));
        uint256 amount = abi.decode(log_.data, (uint256));

        a.spentToday += amount;
        spentToday += amount;
        receiptHead = keccak256(
            abi.encode(receiptHead, log_.chainId, log_.txHash, log_.logIndex, agentAddr, payee, amount)
        );
        emit Spent(agentAddr, log_.chainId, payee, amount, log_.txHash, receiptCount++, receiptHead);

        if (!approvedPayee[payee]) {
            if (!a.quarantined) {
                a.quarantined = true;
                emit Quarantined(agentAddr, log_.chainId, payee, log_.txHash);
                _toAllVaults(
                    abi.encodeWithSignature(
                        "freezeAgent(address,address,bytes32)", address(0), agentAddr, bytes32("unknown payee")
                    )
                );
            }
            return;
        }
        if (a.quarantined || panicked) return;

        uint256 refill = _min(amount, _left(a.allowance, a.toppedUpToday));
        refill = _min(refill, _left(ceiling, toppedUpToday));
        if (refill == 0) return;

        a.toppedUpToday += refill;
        toppedUpToday += refill;
        uint64 seq = ++seqOf[log_.chainId];
        emit TopUpRequested(agentAddr, log_.chainId, seq, refill);
        _callback(
            log_.chainId,
            c.vault,
            abi.encodeWithSignature("topUp(address,address,uint256,uint64)", address(0), agentAddr, refill, seq)
        );
    }

    function _onPanic(LogRecord calldata log_) internal {
        if (log_.contractAddress != chains[log_.chainId].vault) return;
        if (panicked) return;
        panicked = true;
        emit PanicSeen(log_.chainId, address(uint160(log_.topic1)), log_.txHash);
        _toAllVaults(abi.encodeWithSignature("freeze(address,bytes32)", address(0), bytes32("panic")));
    }

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
        for (uint256 i; i < agentList.length; ++i) {
            Agent storage a = agents[agentList[i]];
            emit AgentStatement(day, agentList[i], a.spentToday, a.toppedUpToday);
            a.spentToday = 0;
            a.toppedUpToday = 0;
        }
        uint256 elapsed = (block.timestamp - dayStart) / 1 days;
        dayStart += elapsed * 1 days;
        day += elapsed;
        spentToday = 0;
        toppedUpToday = 0;
    }

    function _left(uint256 cap, uint256 used) internal pure returns (uint256) {
        return used >= cap ? 0 : cap - used;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _watch(uint256 chainId, address usdc, address agent) internal {
        SYSTEM.subscribe(chainId, usdc, TRANSFER_TOPIC, uint256(uint160(agent)), REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    // ---- owner (called directly on Reactive Network) ----

    /// @notice Register a chain: watch every agent's USDC transfers there and the vault's panic button.
    function addChain(uint256 chainId, address usdc, address vault) external onlyOwner {
        if (chains[chainId].vault == address(0)) {
            chainIds.push(chainId);
            callbackGasOf[chainId] = DEFAULT_CALLBACK_GAS;
        }
        chains[chainId] = Chain(usdc, vault);
        for (uint256 i; i < agentList.length; ++i) _watch(chainId, usdc, agentList[i]);
        SYSTEM.subscribe(chainId, vault, PANIC_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit ChainAdded(chainId, usdc, vault);
    }

    /// @notice Add an agent (watched on every registered chain) or change its daily allowance.
    function setAgent(address agent, uint256 allowance) external onlyOwner {
        Agent storage a = agents[agent];
        if (!a.known) {
            a.known = true;
            agentList.push(agent);
            for (uint256 i; i < chainIds.length; ++i) _watch(chainIds[i], chains[chainIds[i]].usdc, agent);
        }
        a.allowance = allowance;
        emit AgentSet(agent, allowance);
    }

    function setCallbackGas(uint256 chainId, uint64 gasLimit) external onlyOwner {
        callbackGasOf[chainId] = gasLimit;
        emit CallbackGasSet(chainId, gasLimit);
    }

    function setPayee(address payee, bool approved) external onlyOwner {
        approvedPayee[payee] = approved;
        emit PayeeSet(payee, approved);
    }

    function setCeiling(uint256 ceiling_) external onlyOwner {
        ceiling = ceiling_;
        emit CeilingSet(ceiling_);
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
