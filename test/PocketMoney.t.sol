// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { PocketMoney } from "../src/PocketMoney.sol";
import { Vault, IERC20Min } from "../src/Vault.sol";
import { MockSystem, MockProxy, MockUSDC } from "./Mocks.sol";

/// @dev Both "chains" live in one EVM here; chain IDs only label which vault a log belongs to.
contract PocketMoneyTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant BASE = 84532;
    uint256 constant UNI = 1301;
    uint256 constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 constant PANIC_TOPIC = uint256(keccak256("Panic(address)"));
    uint256 constant FLOAT = 5e6; // $5
    uint256 constant BUDGET = 10e6; // $10/day

    MockSystem sys;
    MockProxy proxy;
    PocketMoney pm;
    mapping(uint256 => MockUSDC) usdc;
    mapping(uint256 => Vault) vault;

    address agent = makeAddr("agent");
    address shop = makeAddr("shop");
    address thief = makeAddr("thief");
    uint256 txn;
    uint256 delivered;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        proxy = new MockProxy();
        pm = new PocketMoney(agent, BUDGET);
        pm.setPayee(shop, true);
        _addChain(BASE);
        _addChain(UNI);
    }

    function _addChain(uint256 id) internal {
        usdc[id] = new MockUSDC();
        vault[id] = new Vault(IPayable(payable(address(proxy))), address(pm), IERC20Min(address(usdc[id])), agent, FLOAT);
        usdc[id].mint(address(vault[id]), 100e6);
        usdc[id].mint(agent, FLOAT);
        pm.addChain(id, address(usdc[id]), address(vault[id]));
    }

    /// Agent pays on chain `id`; Reactive delivers the log; pending callbacks are delivered.
    function _spend(uint256 id, address to, uint256 amount) internal {
        vm.prank(agent);
        usdc[id].transfer(to, amount);
        IReactive.LogRecord memory log_ = IReactive.LogRecord({
            chainId: id,
            contractAddress: address(usdc[id]),
            topic0: TRANSFER_TOPIC,
            topic1: uint256(uint160(agent)),
            topic2: uint256(uint160(to)),
            topic3: 0,
            data: abi.encode(amount),
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: ++txn,
            logIndex: 0
        });
        vm.prank(SYSTEM);
        pm.react(log_);
        _deliverPending();
    }

    function _deliverPending() internal {
        for (; delivered < sys.callbackCount(); ++delivered) {
            ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(delivered);
            proxy.deliver(sys.callbackRequester(delivered), c.recipient, c.payload);
        }
    }

    // ---- loop 1: spend -> top-up ----

    function test_subscribesPerChain() public view {
        assertEq(sys.subCount(), 4); // transfer + panic, two chains
        (uint256 c, address a, uint256 t0, uint256 t1,,) = sys.subs(0);
        assertEq(c, BASE);
        assertEq(a, address(usdc[BASE]));
        assertEq(t0, TRANSFER_TOPIC);
        assertEq(t1, uint256(uint160(agent)));
    }

    function test_knownPayee_isToppedBackToFloat() public {
        _spend(BASE, shop, 1e6);
        assertEq(usdc[BASE].balanceOf(agent), FLOAT);
        assertEq(pm.spentToday(), 1e6);
        assertEq(pm.toppedUpToday(), 1e6);
        assertEq(vault[BASE].lastSeq(), 1);
    }

    function test_topUpGoesToTheChainThatSpent() public {
        _spend(UNI, shop, 2e6);
        assertEq(usdc[UNI].balanceOf(agent), FLOAT);
        assertEq(usdc[BASE].balanceOf(agent), FLOAT);
        assertEq(usdc[BASE].balanceOf(address(vault[BASE])), 100e6);
    }

    // ---- one budget across chains ----

    function test_budgetIsSharedAcrossChains() public {
        _spend(BASE, shop, 4e6);
        _spend(UNI, shop, 4e6);
        _spend(BASE, shop, 4e6); // only 2 of budget left
        assertEq(pm.toppedUpToday(), BUDGET);
        assertEq(usdc[BASE].balanceOf(agent), FLOAT - 2e6);
        _spend(UNI, shop, 1e6); // budget gone: no top-up anywhere
        assertEq(usdc[UNI].balanceOf(agent), FLOAT - 1e6);
        // P2: day's spend <= budget + floats
        assertLe(pm.spentToday(), BUDGET + 2 * FLOAT);
    }

    // ---- loop 2: unknown payee -> frozen everywhere ----

    function test_unknownPayee_quarantinesAndFreezesEveryChain() public {
        _spend(UNI, thief, 3e6);
        assertTrue(pm.quarantined());
        assertTrue(vault[BASE].frozen());
        assertTrue(vault[UNI].frozen());
        assertEq(usdc[UNI].balanceOf(agent), FLOAT - 3e6); // no refill for the thief's payment
        _spend(BASE, shop, 1e6); // even approved spends get nothing now
        assertEq(usdc[BASE].balanceOf(agent), FLOAT - 1e6);
    }

    function test_stolenKey_losesAtMostTheFloats() public {
        _spend(BASE, thief, FLOAT);
        _spend(UNI, thief, FLOAT);
        assertEq(usdc[BASE].balanceOf(thief) + usdc[UNI].balanceOf(thief), 2 * FLOAT);
        assertEq(usdc[BASE].balanceOf(agent) + usdc[UNI].balanceOf(agent), 0);
    }

    // ---- loop 3: panic on one chain -> stops everywhere ----

    function test_panicOnOneChain_stopsAll() public {
        vault[UNI].panic();
        IReactive.LogRecord memory log_;
        log_.chainId = UNI;
        log_.contractAddress = address(vault[UNI]);
        log_.topic0 = PANIC_TOPIC;
        log_.topic1 = uint256(uint160(address(this)));
        vm.prank(SYSTEM);
        pm.react(log_);
        _deliverPending();
        assertTrue(pm.panicked());
        assertTrue(vault[BASE].frozen());
        _spend(BASE, shop, 1e6);
        assertEq(usdc[BASE].balanceOf(agent), FLOAT - 1e6);
    }

    function test_panicFromStrangerContractIsIgnored() public {
        IReactive.LogRecord memory log_;
        log_.chainId = UNI;
        log_.contractAddress = thief;
        log_.topic0 = PANIC_TOPIC;
        vm.prank(SYSTEM);
        pm.react(log_);
        assertFalse(pm.panicked());
    }

    // ---- loop 4: daily rollover ----

    function test_newDay_resetsBudgetAndEmitsStatement() public {
        _spend(BASE, shop, 4e6);
        _spend(BASE, shop, 4e6);
        _spend(BASE, shop, 4e6);
        assertEq(pm.toppedUpToday(), BUDGET);
        vm.warp(block.timestamp + 1 days + 1);
        bytes32 closingHead = pm.receiptHead();
        vm.recordLogs();
        _spend(BASE, shop, 1e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == PocketMoney.Statement.selector) {
                assertEq(logs[i].topics[1], bytes32(0)); // day 0 closed
                assertEq(logs[i].data, abi.encode(uint256(12e6), BUDGET, uint256(3), closingHead));
                found = true;
            }
        }
        assertTrue(found);
        assertEq(pm.day(), 1);
        assertEq(pm.spentToday(), 1e6);
        assertEq(pm.toppedUpToday(), 1e6);
    }

    // ---- local float cap (defense in depth) ----

    function test_vaultNeverFillsPastFloat_evenIfGuardOverAsks() public {
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), agent, uint256(50e6), uint64(1)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(usdc[BASE].balanceOf(agent), FLOAT);
    }

    // ---- callback authentication ----

    function test_directCallToVaultReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(proxy)));
        vault[BASE].topUp(address(pm), agent, 1e6, 1);
    }

    function test_callbackFromOtherReactiveContractReverts() public {
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), agent, uint256(1e6), uint64(1)
        );
        (bool ok, bytes memory ret) = proxy.deliver(thief, address(vault[BASE]), p);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, thief, address(pm)));
    }

    function test_replayedTopUpIsSkipped() public {
        vm.prank(agent);
        usdc[BASE].transfer(shop, 2e6);
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), agent, uint256(1e6), uint64(7)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(usdc[BASE].balanceOf(agent), FLOAT - 1e6);
    }

    function test_reactOnlyFromSystem() public {
        IReactive.LogRecord memory log_;
        vm.expectRevert();
        pm.react(log_);
    }

    function test_ownerOnly() public {
        vm.startPrank(thief);
        vm.expectRevert(PocketMoney.NotOwner.selector);
        pm.setPayee(thief, true);
        vm.expectRevert(Vault.NotOwner.selector);
        vault[BASE].unfreeze();
        vm.stopPrank();
    }

    // ---- receipts ----

    function test_receiptChainLinksEverySpend() public {
        _spend(BASE, shop, 1e6);
        bytes32 h1 = pm.receiptHead();
        _spend(UNI, shop, 2e6);
        bytes32 expected = keccak256(abi.encode(h1, UNI, uint256(2), uint256(0), shop, uint256(2e6)));
        assertEq(pm.receiptHead(), expected);
        assertEq(pm.receiptCount(), 2);
    }
}
