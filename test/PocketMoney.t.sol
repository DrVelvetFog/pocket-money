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

/// @dev All "chains" live in one EVM here; chain IDs only label which vault a log belongs to.
contract PocketMoneyTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant BASE = 84532;
    uint256 constant UNI = 1301;
    uint256 constant ETH = 11155111;
    uint256 constant TRANSFER_TOPIC = uint256(keccak256("Transfer(address,address,uint256)"));
    uint256 constant PANIC_TOPIC = uint256(keccak256("Panic(address)"));
    uint256 constant FLOAT = 5e6; // $5 per agent per chain
    uint256 constant ALLOWANCE = 10e6; // $10/day per agent
    uint256 constant CEILING = 15e6; // $15/day for the household

    MockSystem sys;
    MockProxy proxy;
    PocketMoney pm;
    uint256[] ids;
    mapping(uint256 => MockUSDC) usdc;
    mapping(uint256 => Vault) vault;

    address andy = makeAddr("andy");
    address plummy = makeAddr("plummy");
    address shop = makeAddr("shop");
    address thief = makeAddr("thief");
    uint256 txn;
    uint256 delivered;

    function setUp() public {
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        proxy = new MockProxy();
        pm = new PocketMoney(CEILING);
        pm.setPayee(shop, true);
        pm.setAgent(andy, ALLOWANCE); // before chains: watched when each chain is added
        _addChain(BASE);
        _addChain(UNI);
        pm.setAgent(plummy, ALLOWANCE); // after chains: watched on every existing chain
        _addChain(ETH);
        for (uint256 i; i < ids.length; ++i) {
            vault[ids[i]].setFloat(plummy, FLOAT);
            usdc[ids[i]].mint(plummy, FLOAT);
        }
    }

    function _addChain(uint256 id) internal {
        ids.push(id);
        usdc[id] = new MockUSDC();
        vault[id] = new Vault(IPayable(payable(address(proxy))), address(pm), IERC20Min(address(usdc[id])));
        vault[id].setFloat(andy, FLOAT);
        usdc[id].mint(address(vault[id]), 100e6);
        usdc[id].mint(andy, FLOAT);
        pm.addChain(id, address(usdc[id]), address(vault[id]));
    }

    function _log(uint256 id, address emitter, uint256 t0, uint256 t1, uint256 t2, bytes memory data)
        internal
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chainId: id,
            contractAddress: emitter,
            topic0: t0,
            topic1: t1,
            topic2: t2,
            topic3: 0,
            data: data,
            blockNumber: block.number,
            opCode: 3,
            blockHash: 0,
            txHash: ++txn,
            logIndex: 0
        });
    }

    /// Agent pays on chain `id`; Reactive delivers the log; pending callbacks are delivered.
    function _spend(address agent, uint256 id, address to, uint256 amount) internal {
        vm.prank(agent);
        usdc[id].transfer(to, amount);
        _react(_log(id, address(usdc[id]), TRANSFER_TOPIC, uint256(uint160(agent)), uint256(uint160(to)), abi.encode(amount)));
    }

    function _react(IReactive.LogRecord memory log_) internal {
        vm.prank(SYSTEM);
        pm.react(log_);
        for (; delivered < sys.callbackCount(); ++delivered) {
            ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(delivered);
            proxy.deliver(sys.callbackRequester(delivered), c.recipient, c.payload);
        }
    }

    function _bal(address who, uint256 id) internal view returns (uint256) {
        return usdc[id].balanceOf(who);
    }

    // ---- subscriptions ----

    function test_watchesEveryAgentOnEveryChain() public view {
        // andy x3 chains + plummy x3 chains + panic x3 chains
        assertEq(sys.subCount(), 9);
        assertEq(pm.agentCount(), 2);
        assertEq(pm.chainCount(), 3);
    }

    // ---- loop 1: spend -> top-up ----

    function test_knownPayee_isToppedBackToFloat() public {
        _spend(andy, BASE, shop, 1e6);
        assertEq(_bal(andy, BASE), FLOAT);
        (,,, uint256 spent, uint256 topped) = pm.agents(andy);
        assertEq(spent, 1e6);
        assertEq(topped, 1e6);
        assertEq(vault[BASE].lastSeq(), 1);
    }

    function test_topUpGoesToTheChainThatSpent() public {
        _spend(plummy, UNI, shop, 2e6);
        assertEq(_bal(plummy, UNI), FLOAT);
        assertEq(_bal(address(vault[BASE]), BASE), 100e6);
        assertEq(_bal(address(vault[ETH]), ETH), 100e6);
    }

    function test_unregisteredAgentIsIgnored() public {
        usdc[BASE].mint(thief, 1e6);
        _spend(thief, BASE, shop, 1e6);
        assertEq(pm.receiptCount(), 0);
        assertEq(sys.callbackCount(), 0);
    }

    // ---- allowances and the household ceiling ----

    function test_agentAllowanceIsSharedAcrossChains() public {
        _spend(andy, BASE, shop, 4e6);
        _spend(andy, UNI, shop, 4e6);
        _spend(andy, ETH, shop, 4e6); // only $2 of andy's $10 left
        assertEq(_bal(andy, ETH), FLOAT - 2e6);
        _spend(andy, BASE, shop, 1e6); // andy is out
        assertEq(_bal(andy, BASE), FLOAT - 1e6);
        _spend(plummy, BASE, shop, 1e6); // plummy still has allowance
        assertEq(_bal(plummy, BASE), FLOAT);
    }

    function test_householdCeilingCapsEveryone() public {
        _spend(andy, BASE, shop, 5e6);
        _spend(andy, UNI, shop, 5e6); // andy at his $10
        _spend(plummy, BASE, shop, 5e6); // household at $15
        _spend(plummy, UNI, shop, 1e6); // ceiling reached: nothing
        assertEq(_bal(plummy, UNI), FLOAT - 1e6);
        assertEq(pm.toppedUpToday(), CEILING);
        // P2: day's spend <= ceiling + all floats
        assertLe(pm.spentToday(), CEILING + 2 * 3 * FLOAT);
    }

    // ---- loop 2: unknown payee -> that agent frozen everywhere ----

    function test_unknownPayee_freezesThatAgentOnEveryChain() public {
        _spend(andy, UNI, thief, 3e6);
        (, bool q,,,) = pm.agents(andy);
        assertTrue(q);
        for (uint256 i; i < ids.length; ++i) assertTrue(vault[ids[i]].agentFrozen(andy));
        assertEq(_bal(andy, UNI), FLOAT - 3e6); // no refill for the thief's payment
        _spend(andy, BASE, shop, 1e6); // even approved spends get nothing now
        assertEq(_bal(andy, BASE), FLOAT - 1e6);
        _spend(plummy, BASE, shop, 1e6); // the rest of the household carries on
        assertEq(_bal(plummy, BASE), FLOAT);
    }

    function test_stolenKey_losesAtMostTheFloats() public {
        for (uint256 i; i < ids.length; ++i) _spend(andy, ids[i], thief, FLOAT);
        uint256 stolen;
        uint256 left;
        for (uint256 i; i < ids.length; ++i) {
            stolen += _bal(thief, ids[i]);
            left += _bal(andy, ids[i]);
        }
        assertEq(stolen, 3 * FLOAT);
        assertEq(left, 0);
    }

    function test_vaultRefusesAnAgentItHasNoFloatFor() public {
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), thief, uint256(1e6), uint64(1)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(_bal(thief, BASE), 0);
    }

    // ---- loop 3: panic on one chain -> stops everywhere ----

    function test_panicOnOneChain_stopsAll() public {
        vault[UNI].panic();
        _react(_log(UNI, address(vault[UNI]), PANIC_TOPIC, uint256(uint160(address(this))), 0, ""));
        assertTrue(pm.panicked());
        for (uint256 i; i < ids.length; ++i) assertTrue(vault[ids[i]].frozen());
        _spend(plummy, ETH, shop, 1e6);
        assertEq(_bal(plummy, ETH), FLOAT - 1e6);
    }

    function test_panicFromStrangerContractIsIgnored() public {
        _react(_log(UNI, thief, PANIC_TOPIC, 0, 0, ""));
        assertFalse(pm.panicked());
    }

    // ---- loop 4: daily rollover ----

    function test_newDay_resetsAndEmitsStatements() public {
        _spend(andy, BASE, shop, 4e6);
        _spend(andy, BASE, shop, 4e6);
        _spend(andy, BASE, shop, 4e6);
        bytes32 closingHead = pm.receiptHead();
        vm.warp(block.timestamp + 1 days + 1);
        vm.recordLogs();
        _spend(andy, BASE, shop, 1e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool household;
        bool perAgent;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pm)) continue;
            if (logs[i].topics[0] == PocketMoney.Statement.selector) {
                assertEq(logs[i].topics[1], bytes32(0));
                assertEq(logs[i].data, abi.encode(uint256(12e6), ALLOWANCE, uint256(3), closingHead));
                household = true;
            }
            if (logs[i].topics[0] == PocketMoney.AgentStatement.selector && logs[i].topics[2] == bytes32(uint256(uint160(andy)))) {
                assertEq(logs[i].data, abi.encode(uint256(12e6), ALLOWANCE));
                perAgent = true;
            }
        }
        assertTrue(household && perAgent);
        assertEq(pm.day(), 1);
        assertEq(pm.toppedUpToday(), 1e6);
    }

    // ---- local float cap (defense in depth) ----

    function test_vaultNeverFillsPastFloat_evenIfGuardOverAsks() public {
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), andy, uint256(50e6), uint64(1)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(_bal(andy, BASE), FLOAT);
    }

    // ---- callback authentication and replay ----

    function test_directCallToVaultReverts() public {
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(proxy)));
        vault[BASE].topUp(address(pm), andy, 1e6, 1);
    }

    function test_callbackFromOtherReactiveContractReverts() public {
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), andy, uint256(1e6), uint64(1)
        );
        (bool ok, bytes memory ret) = proxy.deliver(thief, address(vault[BASE]), p);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, thief, address(pm)));
    }

    function test_replayedTopUpIsSkipped() public {
        vm.prank(andy);
        usdc[BASE].transfer(shop, 2e6);
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), andy, uint256(1e6), uint64(7)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(_bal(andy, BASE), FLOAT - 1e6);
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
        vm.expectRevert(PocketMoney.NotOwner.selector);
        pm.setAgent(thief, 1);
        vm.expectRevert(Vault.NotOwner.selector);
        vault[BASE].unfreeze();
        vm.expectRevert(Vault.NotOwner.selector);
        vault[BASE].migrate(payable(thief));
        vm.stopPrank();
    }

    // ---- migrate ----

    function test_migrateMovesEverythingAndFreezes() public {
        vm.deal(address(vault[BASE]), 1 ether);
        address payable next = payable(makeAddr("nextVault"));
        vault[BASE].migrate(next);
        assertTrue(vault[BASE].frozen());
        assertEq(_bal(next, BASE), 100e6);
        assertEq(next.balance, 1 ether);
    }

    // ---- receipts ----

    function test_receiptChainLinksEverySpend() public {
        _spend(andy, BASE, shop, 1e6);
        bytes32 h1 = pm.receiptHead();
        _spend(plummy, UNI, shop, 2e6);
        bytes32 expected = keccak256(abi.encode(h1, UNI, uint256(2), uint256(0), plummy, shop, uint256(2e6)));
        assertEq(pm.receiptHead(), expected);
        assertEq(pm.receiptCount(), 2);
    }

    // ---- callback gas ----

    function test_callbacksUseThePerChainGasLimit() public {
        assertEq(pm.callbackGasOf(ETH), 1_000_000);
        pm.setCallbackGas(ETH, 1_500_000);
        _spend(andy, ETH, shop, 1e6);
        ISystemContract.CallbackConfiguration_V_1_0 memory c = sys.callbackAt(sys.callbackCount() - 1);
        assertEq(c.chainId, ETH);
        assertEq(c.gasLimit, 1_500_000);
    }
}
