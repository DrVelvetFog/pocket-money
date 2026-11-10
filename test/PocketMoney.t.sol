// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { PocketMoney } from "../src/PocketMoney.sol";
import { Vault, IERC20Min, ITokenMessengerV2 } from "../src/Vault.sol";
import { SpendInbox } from "../src/SpendInbox.sol";
import { MockSystem, MockProxy, MockUSDC, MockTokenMessenger } from "./Mocks.sol";

/// @dev All "chains" live in one EVM here. The harness plays Reactive Network: every log any
/// contract emits is matched against the guard's real subscriptions (chain id is looked up from
/// the emitter) and fed to react(); requested callbacks are delivered through the proxy mock;
/// repeat until nothing new happens.
contract PocketMoneyTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    uint256 constant IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 constant BASE = 84532;
    uint256 constant UNI = 1301;
    uint256 constant ETH = 11155111;
    uint256 constant FLOAT = 5e6; // $5 per agent per chain
    uint256 constant ALLOWANCE = 10e6; // $10/day per agent
    uint256 constant CEILING = 15e6; // $15/day for the household
    bytes32 constant SUI_SHOP = keccak256("sui shop");
    bytes32 constant SUI_THIEF = keccak256("sui thief");

    MockSystem sys;
    MockProxy proxy;
    MockTokenMessenger tm;
    PocketMoney pm;
    SpendInbox inbox;
    uint256[] ids;
    mapping(uint256 => MockUSDC) usdc;
    mapping(uint256 => Vault) vault;
    mapping(uint256 => uint32) domain;

    address andy = makeAddr("andy");
    address plummy = makeAddr("plummy");
    address shop = makeAddr("shop");
    address thief = makeAddr("thief");
    address attester = makeAddr("attester");
    uint256 txn;
    uint256 delivered;
    uint256 maxReactGas;
    ISystemContract.CallbackConfiguration_V_1_0[] cbs;
    address[] cbFrom;

    function setUp() public {
        vm.recordLogs();
        vm.etch(SYSTEM, address(new MockSystem()).code);
        sys = MockSystem(payable(SYSTEM));
        proxy = new MockProxy();
        tm = new MockTokenMessenger();
        pm = new PocketMoney(CEILING);
        inbox = new SpendInbox(attester);
        pm.setPayee(shop, true);
        pm.setForeignPayee(SUI_SHOP, true);
        pm.setAgent(andy, ALLOWANCE); // before chains: watched when each chain is added
        _addChain(BASE, 6);
        _addChain(UNI, 10);
        pm.setAgent(plummy, ALLOWANCE); // after chains: watched on every existing chain
        _addChain(ETH, 0);
        pm.addInbox(BASE, address(inbox));
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            vault[id].setFloat(plummy, FLOAT);
            usdc[id].mint(plummy, FLOAT);
            usdc[id].mint(address(vault[id]), 100e6); // after addChain, so the guard tracks it
            vault[id].setRebalanceCap(50e6);
            for (uint256 j; j < ids.length; ++j) {
                if (j != i) vault[id].setPeer(domain[ids[j]], address(vault[ids[j]]));
            }
        }
        pm.resync();
        _pump();
    }

    function _addChain(uint256 id, uint32 d) internal {
        ids.push(id);
        domain[id] = d;
        usdc[id] = new MockUSDC();
        vault[id] = new Vault(
            IPayable(payable(address(proxy))),
            address(pm),
            IERC20Min(address(usdc[id])),
            ITokenMessengerV2(address(tm))
        );
        vault[id].setFloat(andy, FLOAT);
        usdc[id].mint(andy, FLOAT);
        pm.addChain(id, address(usdc[id]), address(vault[id]), d);
    }

    // ---- the Reactive Network simulator ----

    function _chainOf(address emitter) internal view returns (uint256) {
        if (emitter == address(pm)) return block.chainid;
        if (emitter == address(inbox)) return BASE;
        for (uint256 i; i < ids.length; ++i) {
            if (emitter == address(usdc[ids[i]]) || emitter == address(vault[ids[i]])) return ids[i];
        }
        return 0;
    }

    function _topic(Vm.Log memory l, uint256 i) internal pure returns (uint256) {
        return i < l.topics.length ? uint256(l.topics[i]) : 0;
    }

    function _subscribed(uint256 chainId, Vm.Log memory l) internal view returns (bool) {
        for (uint256 i; i < sys.subCount(); ++i) {
            MockSystem.Sub memory s = sys.subAt(i);
            if (s.chainId != 0 && s.chainId != chainId) continue;
            if (s.target != address(0) && s.target != l.emitter) continue;
            if (s.t0 != IGNORE && s.t0 != _topic(l, 0)) continue;
            if (s.t1 != IGNORE && s.t1 != _topic(l, 1)) continue;
            if (s.t2 != IGNORE && s.t2 != _topic(l, 2)) continue;
            if (s.t3 != IGNORE && s.t3 != _topic(l, 3)) continue;
            return true;
        }
        return false;
    }

    function _pump() internal {
        for (uint256 round; round < 40; ++round) {
            bool any;
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == SYSTEM && logs[i].topics[0] == MockSystem.CallbackRequested.selector) {
                    (uint256 c, address r, uint64 g, bytes memory p, address from) =
                        abi.decode(logs[i].data, (uint256, address, uint64, bytes, address));
                    cbs.push(ISystemContract.CallbackConfiguration_V_1_0(c, r, g, p));
                    cbFrom.push(from);
                    continue;
                }
                uint256 chainId = _chainOf(logs[i].emitter);
                if (chainId == 0 || !_subscribed(chainId, logs[i])) continue;
                IReactive.LogRecord memory r = IReactive.LogRecord({
                    chainId: chainId,
                    contractAddress: logs[i].emitter,
                    topic0: _topic(logs[i], 0),
                    topic1: _topic(logs[i], 1),
                    topic2: _topic(logs[i], 2),
                    topic3: _topic(logs[i], 3),
                    data: logs[i].data,
                    blockNumber: block.number,
                    opCode: 3,
                    blockHash: 0,
                    txHash: ++txn,
                    logIndex: 0
                });
                vm.prank(SYSTEM);
                uint256 g = gasleft();
                pm.react(r);
                g -= gasleft();
                if (g > maxReactGas) maxReactGas = g;
                any = true;
            }
            for (; delivered < cbs.length; ++delivered) {
                proxy.deliver(cbFrom[delivered], cbs[delivered].recipient, cbs[delivered].payload);
                any = true;
            }
            if (!any) return;
        }
        revert("pump did not settle");
    }

    function _spend(address agent, uint256 id, address to, uint256 amount) internal {
        vm.prank(agent);
        usdc[id].transfer(to, amount);
        _pump();
    }

    function _foreign(address agent, bytes32 payee, uint256 amount, bytes32 ref) internal {
        vm.prank(attester);
        inbox.report(agent, payee, amount, "sui:testnet", ref);
        _pump();
    }

    function _bal(address who, uint256 id) internal view returns (uint256) {
        return usdc[id].balanceOf(who);
    }

    function _relayLastBurn(uint256 toId) internal {
        (uint256 amount,, bytes32 recipient,,) = tm.burns(tm.burnCount() - 1);
        usdc[toId].mint(address(uint160(uint256(recipient))), amount);
        _pump();
    }

    // ---- subscriptions ----

    function test_subscriptions() public view {
        // self (sync) + per chain: agents x2 + vault out + vault in + panic = 5 x 3 + inbox
        assertEq(sys.subCount(), 1 + 15 + 1);
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
        uint256 receipts = pm.receiptCount();
        usdc[BASE].mint(thief, 1e6);
        _spend(thief, BASE, shop, 1e6);
        assertEq(pm.receiptCount(), receipts);
    }

    // ---- allowances and the household ceiling ----

    function test_agentAllowanceIsSharedAcrossChains() public {
        _spend(andy, BASE, shop, 4e6);
        _spend(andy, UNI, shop, 4e6);
        _spend(andy, ETH, shop, 4e6); // only $2 of andy's $10 left to top up
        assertEq(_bal(andy, ETH), FLOAT - 2e6);
        _spend(andy, BASE, shop, 1e6);
        assertEq(_bal(andy, BASE), FLOAT - 1e6);
        _spend(plummy, BASE, shop, 1e6);
        assertEq(_bal(plummy, BASE), FLOAT);
    }

    function test_householdCeilingCapsEveryone() public {
        _spend(andy, BASE, shop, 5e6);
        _spend(andy, UNI, shop, 5e6);
        _spend(plummy, BASE, shop, 5e6);
        _spend(plummy, UNI, shop, 1e6);
        assertEq(_bal(plummy, UNI), FLOAT - 1e6);
        assertEq(pm.toppedUpToday(), CEILING);
        assertLe(pm.spentToday(), CEILING + 2 * 3 * FLOAT);
    }

    // ---- idea 1: the budget mirror ----

    function test_mirrorStartsFullOnEveryChain() public view {
        for (uint256 i; i < ids.length; ++i) {
            (bool ok, uint256 left,) = vault[ids[i]].canSpend(andy, 1e6);
            assertTrue(ok);
            assertEq(left, ALLOWANCE);
        }
    }

    function test_mirrorFollowsSpendingOnOtherChains() public {
        _spend(andy, BASE, shop, 4e6);
        _spend(andy, UNI, shop, 3e6);
        // Ethereum Sepolia never saw andy spend, but knows he has $3 left
        (bool ok, uint256 left, bytes32 why) = vault[ETH].canSpend(andy, 4e6);
        assertFalse(ok);
        assertEq(left, 3e6);
        assertEq(why, bytes32("over budget"));
        (ok,,) = vault[ETH].canSpend(andy, 3e6);
        assertTrue(ok);
    }

    function test_mirrorReflectsHouseholdCeiling() public {
        _spend(andy, BASE, shop, 5e6);
        _spend(andy, UNI, shop, 4e6);
        // plummy hasn't spent, but the household has only $6 left
        (, uint256 left,) = vault[UNI].canSpend(plummy, 1);
        assertEq(left, CEILING - 9e6);
    }

    function test_mirrorResetsOnANewDayWithoutASync() public {
        _spend(andy, BASE, shop, 5e6);
        _spend(andy, UNI, shop, 4e6);
        vm.warp(block.timestamp + 1 days + 1);
        (, uint256 left,) = vault[ETH].canSpend(andy, 1);
        assertEq(left, ALLOWANCE);
    }

    function test_mirrorReportsFreezes() public {
        _spend(andy, UNI, thief, 1e6);
        (bool ok,, bytes32 why) = vault[BASE].canSpend(andy, 1);
        assertFalse(ok);
        assertEq(why, bytes32("agent frozen"));
        (ok,,) = vault[BASE].canSpend(plummy, 1);
        assertTrue(ok);
    }

    function test_staleSyncIsIgnored() public {
        _spend(andy, BASE, shop, 4e6);
        uint64 v = vault[ETH].syncVersion();
        bytes memory p = abi.encodeWithSignature(
            "syncBudget(address,address,uint256,uint256,uint256,uint256,uint256,uint64)",
            address(0), andy, ALLOWANCE, uint256(0), CEILING, uint256(0), block.timestamp + 1 days, v
        );
        proxy.deliver(address(pm), address(vault[ETH]), p);
        (, uint256 left,) = vault[ETH].canSpend(andy, 1);
        assertEq(left, ALLOWANCE - 4e6);
    }

    // ---- idea 2: spending on chains Reactive can't see ----

    function test_foreignSpendCountsAgainstTheSameBudget() public {
        _foreign(andy, SUI_SHOP, 6e6, keccak256("digest-1"));
        (,,, uint256 spent,) = pm.agents(andy);
        assertEq(spent, 6e6);
        (, uint256 left,) = vault[UNI].canSpend(andy, 1);
        assertEq(left, ALLOWANCE - 6e6);
        assertEq(vault[BASE].lastSeq(), 0); // nothing to top up on Sui
    }

    function test_foreignUnknownPayeeFreezesTheAgentOnEveryEvmChain() public {
        _foreign(andy, SUI_THIEF, 1e6, keccak256("digest-2"));
        for (uint256 i; i < ids.length; ++i) assertTrue(vault[ids[i]].agentFrozen(andy));
    }

    function test_inboxRejectsStrangersAndRepeats() public {
        vm.expectRevert(SpendInbox.NotAttester.selector);
        inbox.report(andy, SUI_SHOP, 1, "sui:testnet", keccak256("x"));
        _foreign(andy, SUI_SHOP, 1e6, keccak256("digest-3"));
        vm.prank(attester);
        vm.expectRevert(abi.encodeWithSelector(SpendInbox.AlreadyReported.selector, keccak256("digest-3")));
        inbox.report(andy, SUI_SHOP, 1e6, "sui:testnet", keccak256("digest-3"));
    }

    // ---- idea 3: liquidity follows the agent over CCTP ----

    function test_guardTracksVaultBalances() public {
        assertEq(pm.vaultBalanceOf(BASE), 100e6);
        _spend(andy, BASE, shop, 2e6);
        assertEq(pm.vaultBalanceOf(BASE), 98e6);
    }

    function test_lowVaultIsRefilledFromTheFullestOverCctp() public {
        pm.setRebalancePolicy(97e6, 99e6, 1000);
        usdc[ETH].mint(address(vault[ETH]), 10e6); // Ethereum Sepolia is now the fullest
        _pump();
        _spend(andy, BASE, shop, 4e6); // Base drops to 96 < 97
        assertTrue(pm.rebalancing(BASE));
        (uint256 amount, uint32 d, bytes32 to,, uint32 finality) = tm.burns(0);
        assertEq(amount, 3e6);
        assertEq(d, 6);
        assertEq(to, bytes32(uint256(uint160(address(vault[BASE])))));
        assertEq(finality, 1000);
        assertEq(_bal(address(vault[ETH]), ETH), 107e6);
        _relayLastBurn(BASE);
        assertFalse(pm.rebalancing(BASE));
        assertEq(_bal(address(vault[BASE]), BASE), 99e6);
        assertEq(pm.vaultBalanceOf(BASE), 99e6);
    }

    function test_rebalanceOnlyGoesToApprovedPeersWithinCap() public {
        bytes memory p = abi.encodeWithSignature("rebalance(address,uint32,uint256,uint256)", address(0), uint32(99), 1e6, 0);
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(tm.burnCount(), 0); // domain 99 isn't a peer
        p = abi.encodeWithSignature("rebalance(address,uint32,uint256,uint256)", address(0), uint32(10), 60e6, 0);
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(tm.burnCount(), 0); // over the $50 cap
    }

    function test_noDonorMeansNoRebalance() public {
        pm.setRebalancePolicy(97e6, 150e6, 1000); // nobody can spare $54 and stay above water
        _spend(andy, BASE, shop, 4e6);
        assertFalse(pm.rebalancing(BASE));
        assertEq(tm.burnCount(), 0);
    }

    // ---- loop 2 / 3: freezes ----

    function test_unknownPayee_freezesThatAgentOnEveryChain() public {
        _spend(andy, UNI, thief, 3e6);
        (, bool q,,,) = pm.agents(andy);
        assertTrue(q);
        for (uint256 i; i < ids.length; ++i) assertTrue(vault[ids[i]].agentFrozen(andy));
        assertEq(_bal(andy, UNI), FLOAT - 3e6);
        _spend(andy, BASE, shop, 1e6);
        assertEq(_bal(andy, BASE), FLOAT - 1e6);
        _spend(plummy, BASE, shop, 1e6);
        assertEq(_bal(plummy, BASE), FLOAT);
    }

    function test_stolenKey_losesAtMostTheFloats() public {
        for (uint256 i; i < ids.length; ++i) _spend(andy, ids[i], thief, FLOAT);
        uint256 stolen;
        for (uint256 i; i < ids.length; ++i) stolen += _bal(thief, ids[i]);
        assertEq(stolen, 3 * FLOAT);
    }

    function test_vaultRefusesAnAgentItHasNoFloatFor() public {
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), thief, uint256(1e6), uint64(1)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(_bal(thief, BASE), 0);
    }

    function test_panicOnOneChain_stopsAll() public {
        vault[UNI].panic();
        _pump();
        assertTrue(pm.panicked());
        for (uint256 i; i < ids.length; ++i) assertTrue(vault[ids[i]].frozen());
        _spend(plummy, ETH, shop, 1e6);
        assertEq(_bal(plummy, ETH), FLOAT - 1e6);
    }

    // ---- loop 4: daily rollover ----

    function test_newDay_resetsAndEmitsStatements() public {
        _spend(andy, BASE, shop, 4e6);
        _spend(andy, BASE, shop, 4e6);
        _spend(andy, BASE, shop, 4e6);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(andy);
        usdc[BASE].transfer(shop, 1e6);
        Vm.Log[] memory pending = vm.getRecordedLogs();
        // re-emit nothing: feed the pending transfer through the simulator by hand
        bool household;
        vm.recordLogs();
        for (uint256 i; i < pending.length; ++i) {
            if (pending[i].emitter != address(usdc[BASE])) continue;
            vm.prank(SYSTEM);
            pm.react(
                IReactive.LogRecord(BASE, pending[i].emitter, _topic(pending[i], 0), _topic(pending[i], 1), _topic(pending[i], 2), 0, pending[i].data, 0, 3, 0, ++txn, 0)
            );
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == PocketMoney.Statement.selector) {
                assertEq(logs[i].topics[1], bytes32(0));
                household = true;
            }
        }
        assertTrue(household);
        assertEq(pm.day(), 1);
        assertEq(pm.toppedUpToday(), 1e6);
    }

    // ---- defense in depth and auth ----

    function test_vaultNeverFillsPastFloat_evenIfGuardOverAsks() public {
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), andy, uint256(50e6), uint64(1)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(_bal(andy, BASE), FLOAT);
    }

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
        vm.getRecordedLogs(); // don't let the simulator see it
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
        pm.setRebalancePolicy(1, 2, 3);
        vm.expectRevert(Vault.NotOwner.selector);
        vault[BASE].setPeer(99, thief);
        vm.expectRevert(Vault.NotOwner.selector);
        vault[BASE].migrate(payable(thief));
        vm.stopPrank();
    }

    function test_migrateMovesEverythingAndFreezes() public {
        vm.deal(address(vault[BASE]), 1 ether);
        address payable next = payable(makeAddr("nextVault"));
        vault[BASE].migrate(next);
        assertTrue(vault[BASE].frozen());
        assertEq(_bal(next, BASE), 100e6);
        assertEq(next.balance, 1 ether);
    }

    function test_callbacksUseThePerChainGasLimit() public {
        pm.setCallbackGas(ETH, 1_500_000);
        uint256 before = cbs.length;
        _spend(andy, ETH, shop, 1e6);
        bool seen;
        for (uint256 i = before; i < cbs.length; ++i) {
            ISystemContract.CallbackConfiguration_V_1_0 memory c = cbs[i];
            if (c.chainId == ETH) {
                assertEq(c.gasLimit, 1_500_000);
                seen = true;
            }
        }
        assertTrue(seen);
    }

    // ---- receipts and gas ----

    function test_receiptChainLinksEverySpend() public {
        uint256 n = pm.receiptCount();
        _spend(andy, BASE, shop, 1e6);
        _foreign(plummy, SUI_SHOP, 2e6, keccak256("digest-4"));
        assertEq(pm.receiptCount(), n + 2);
    }

    function test_reactStaysUnderTheNetworkGasCap() public {
        _spend(andy, UNI, thief, 1e6); // the heaviest path: book + freeze 3 chains + sync 3 chains
        _spend(plummy, BASE, shop, 1e6);
        assertLt(maxReactGas, 900_000);
        emit log_named_uint("max react gas", maxReactGas);
    }
}
