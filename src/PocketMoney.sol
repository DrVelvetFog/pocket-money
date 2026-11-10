// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @title Pocket Money guard (lives on Reactive Network)
/// @notice One daily budget for one agent across every chain it spends on. Watches the agent's
/// USDC transfers on each chain, books them, and asks that chain's vault to top the float back
/// up while budget remains. Paying anyone off the approved list freezes the agent everywhere.
contract PocketMoney is AbstractReactive {
    error NotOwner();
    error UnknownChain(uint256 chainId);

    uint256 internal constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 internal constant PANIC_TOPIC = uint256(keccak256("Panic(address)"));
    /// @dev Cron10000 (~3h) from the system's legacy cron emitter, per dev.reactive.network.
    uint256 internal constant CRON_TOPIC =
        0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    address internal constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint64 internal constant CALLBACK_GAS = 400_000;

    struct Chain {
        address usdc;
        address vault;
    }

    event Spent(
        uint256 indexed chainId,
        address indexed payee,
        uint256 amount,
        uint256 txHash,
        uint256 receiptIndex,
        bytes32 receiptHead
    );
    event TopUpRequested(uint256 indexed chainId, uint64 indexed seq, uint256 amount);
    event Quarantined(uint256 indexed chainId, address indexed payee, uint256 txHash);
    event PanicSeen(uint256 indexed chainId, address indexed by, uint256 txHash);
    event Statement(
        uint256 indexed day, uint256 spent, uint256 toppedUp, uint256 receiptCount, bytes32 receiptHead
    );
    event ChainAdded(uint256 indexed chainId, address usdc, address vault);
    event PayeeSet(address indexed payee, bool approved);
    event BudgetSet(uint256 dailyBudget);
    event CronSet(bool on);
    event Resumed();

    address public immutable owner;
    address public immutable agent;

    uint256 public dailyBudget;
    uint256 public day;
    uint256 public dayStart;
    uint256 public spentToday;
    uint256 public toppedUpToday;

    bool public quarantined;
    bool public panicked;

    bytes32 public receiptHead;
    uint256 public receiptCount;

    mapping(address => bool) public approvedPayee;
    mapping(uint256 => Chain) public chains;
    uint256[] public chainIds;
    mapping(uint256 => uint64) public seqOf;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address agent_, uint256 dailyBudget_) payable {
        owner = msg.sender;
        agent = agent_;
        dailyBudget = dailyBudget_;
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
        if (address(uint160(log_.topic1)) != agent) return;

        address payee = address(uint160(log_.topic2));
        uint256 amount = abi.decode(log_.data, (uint256));

        spentToday += amount;
        receiptHead = keccak256(
            abi.encode(receiptHead, log_.chainId, log_.txHash, log_.logIndex, payee, amount)
        );
        emit Spent(log_.chainId, payee, amount, log_.txHash, receiptCount++, receiptHead);

        if (!approvedPayee[payee]) {
            if (!quarantined) {
                quarantined = true;
                emit Quarantined(log_.chainId, payee, log_.txHash);
                _freezeAll("unknown payee");
            }
            return;
        }
        if (quarantined || panicked) return;

        uint256 left = toppedUpToday >= dailyBudget ? 0 : dailyBudget - toppedUpToday;
        uint256 refill = amount < left ? amount : left;
        if (refill == 0) return;

        toppedUpToday += refill;
        uint64 seq = ++seqOf[log_.chainId];
        emit TopUpRequested(log_.chainId, seq, refill);
        _callback(
            log_.chainId,
            c.vault,
            abi.encodeWithSignature(
                "topUp(address,address,uint256,uint64)", address(0), agent, refill, seq
            )
        );
    }

    function _onPanic(LogRecord calldata log_) internal {
        if (log_.contractAddress != chains[log_.chainId].vault) return;
        address by = address(uint160(log_.topic1));
        if (!panicked) {
            panicked = true;
            emit PanicSeen(log_.chainId, by, log_.txHash);
            _freezeAll("panic");
        }
    }

    function _freezeAll(bytes32 reason) internal {
        for (uint256 i; i < chainIds.length; ++i) {
            uint256 id = chainIds[i];
            _callback(
                id, chains[id].vault, abi.encodeWithSignature("freeze(address,bytes32)", address(0), reason)
            );
        }
    }

    function _callback(uint256 chainId, address recipient, bytes memory payload) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: chainId, recipient: recipient, gasLimit: CALLBACK_GAS, payload: payload
            })
        );
    }

    /// @dev Closes out any finished day: emits its statement and resets the counters.
    function _roll() internal {
        if (block.timestamp < dayStart + 1 days) return;
        emit Statement(day, spentToday, toppedUpToday, receiptCount, receiptHead);
        uint256 elapsed = (block.timestamp - dayStart) / 1 days;
        dayStart += elapsed * 1 days;
        day += elapsed;
        spentToday = 0;
        toppedUpToday = 0;
    }

    // ---- owner (called directly on Reactive Network) ----

    /// @notice Register a chain: watch the agent's USDC transfers there and the vault's panic button.
    function addChain(uint256 chainId, address usdc, address vault) external onlyOwner {
        if (chains[chainId].vault == address(0)) chainIds.push(chainId);
        chains[chainId] = Chain(usdc, vault);
        SYSTEM.subscribe(
            chainId, usdc, TRANSFER_TOPIC, uint256(uint160(agent)), REACTIVE_IGNORE, REACTIVE_IGNORE
        );
        SYSTEM.subscribe(chainId, vault, PANIC_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        emit ChainAdded(chainId, usdc, vault);
    }

    function setPayee(address payee, bool approved) external onlyOwner {
        approvedPayee[payee] = approved;
        emit PayeeSet(payee, approved);
    }

    function setBudget(uint256 dailyBudget_) external onlyOwner {
        dailyBudget = dailyBudget_;
        emit BudgetSet(dailyBudget_);
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

    /// @notice Clear quarantine/panic here. Each vault still has to be unfrozen by its owner.
    function resume() external onlyOwner {
        quarantined = false;
        panicked = false;
        emit Resumed();
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
}
