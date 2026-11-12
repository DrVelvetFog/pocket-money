// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { PocketMoney } from "../src/PocketMoney.sol";
import { Vault } from "../src/Vault.sol";
import { SpendInbox } from "../src/SpendInbox.sol";
import { ReactiveSim } from "./ReactiveSim.sol";

contract PocketMoneyTest is ReactiveSim {
    function setUp() public {
        _deploy();
    }

    // ---- subscriptions ----

    function test_subscriptions() public view {
        // self (sync) + per chain: agents x2 + vault out + vault in + panic + raise = 6 x 3 + inbox
        assertEq(sys.subCount(), 1 + 18 + 1); // + raise per vault
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
            "syncBudget(address,address,(uint256,uint256,uint256,uint256,uint256,uint256,uint256),uint64)",
            address(0), andy, ALLOWANCE, uint256(0), uint256(0), CEILING, uint256(0), uint256(0), block.timestamp + 1 days, v
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
        bytes memory p = abi.encodeWithSignature(
            "rebalance(address,uint32,uint256,uint256,uint64)", address(0), uint32(99), 1e6, 0, uint64(1)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(tm.burnCount(), 0); // domain 99 isn't a peer
        p = abi.encodeWithSignature(
            "rebalance(address,uint32,uint256,uint256,uint64)", address(0), uint32(10), 60e6, 0, uint64(2)
        );
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

    // ---- rules the mutation run showed no test was holding ----

    function test_frozenVaultSkipsATopUpEvenIfTheGuardAsks() public {
        vault[BASE].panic();
        vm.prank(andy);
        usdc[BASE].transfer(shop, 2e6);
        vm.getRecordedLogs(); // don't let the simulator see any of it
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), andy, uint256(2e6), uint64(50)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(_bal(andy, BASE), FLOAT - 2e6);
    }

    function test_frozenAgentSkipsATopUpEvenIfTheGuardAsks() public {
        proxy.deliver(
            address(pm),
            address(vault[BASE]),
            abi.encodeWithSignature("freezeAgent(address,address,bytes32)", address(0), andy, bytes32("test"))
        );
        assertTrue(vault[BASE].agentFrozen(andy));
        vm.prank(andy);
        usdc[BASE].transfer(shop, 2e6);
        vm.getRecordedLogs();
        bytes memory p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), andy, uint256(2e6), uint64(50)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(_bal(andy, BASE), FLOAT - 2e6);
        // and the other agent on the same vault is untouched by that freeze
        vm.prank(plummy);
        usdc[BASE].transfer(shop, 1e6);
        vm.getRecordedLogs();
        p = abi.encodeWithSignature(
            "topUp(address,address,uint256,uint64)", address(0), plummy, uint256(1e6), uint64(51)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(_bal(plummy, BASE), FLOAT);
    }

    function test_rebalanceOfExactlyTheCapIsAllowed() public {
        bytes memory p = abi.encodeWithSignature(
            "rebalance(address,uint32,uint256,uint256,uint64)", address(0), uint32(10), 50e6, 0, uint64(1)
        );
        proxy.deliver(address(pm), address(vault[BASE]), p);
        assertEq(tm.burnCount(), 1); // the cap is the most allowed, not one past it
    }

    function test_foreignSpendFromAContractThatIsNotTheInboxIsIgnored() public {
        uint256 receipts = pm.receiptCount();
        IReactive.LogRecord memory r;
        r.chainId = BASE;
        r.contractAddress = thief; // looks like the inbox's event, comes from somewhere else
        r.topic0 = uint256(keccak256("ForeignSpend(address,bytes32,uint256,bytes32,bytes32)"));
        r.topic1 = uint256(uint160(andy));
        r.topic2 = uint256(SUI_THIEF);
        r.data = abi.encode(uint256(1e6), bytes32("sui:testnet"), keccak256("forged"));
        vm.prank(address(0x8888888888888888888888888888888888888888));
        pm.react(r);
        assertEq(pm.receiptCount(), receipts);
        (, bool quarantined,,,) = pm.agents(andy);
        assertFalse(quarantined);
    }

    function test_noSecondRefillWhileOneIsOnItsWay() public {
        pm.setRebalancePolicy(97e6, 99e6, 1000);
        usdc[ETH].mint(address(vault[ETH]), 10e6);
        _pump();
        _spend(andy, BASE, shop, 4e6); // Base drops below the floor: one refill is requested
        assertEq(tm.burnCount(), 1);
        _spend(plummy, BASE, shop, 1e6); // still low, refill not landed yet
        assertEq(tm.burnCount(), 1);
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

    // Reactive has been seen delivering one requested callback twice (another Omni entry,
    // 2026-11-10). Every callback has to be safe to run again.
    function test_duplicateDeliveryOfEveryCallbackIsHarmless() public {
        dupe = true;
        pm.setRebalancePolicy(97e6, 99e6, 1000);
        usdc[ETH].mint(address(vault[ETH]), 10e6);
        _pump();
        _spend(andy, BASE, shop, 4e6); // top-up + mirror sync + rebalance, each delivered twice
        assertEq(_bal(andy, BASE), FLOAT); // refilled once, not twice
        assertEq(tm.burnCount(), 1); // one CCTP burn, not two
        assertEq(_bal(address(vault[ETH]), ETH), 107e6);
        (, uint256 left,) = vault[UNI].canSpend(andy, 1);
        assertEq(left, ALLOWANCE - 4e6);
        _spend(andy, UNI, thief, 1e6); // freeze, delivered twice
        for (uint256 i; i < ids.length; ++i) assertTrue(vault[ids[i]].agentFrozen(andy));
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

    /// Found by the invariant fuzzer: after midnight, one agent's spending must lower the
    /// household budget in every other agent's mirror too.
    function test_regression_householdSpendAfterMidnightReachesOtherAgentsMirror() public {
        vm.warp(block.timestamp + 1 days + 1);
        _foreign(andy, SUI_SHOP, 6e6, keccak256("after-midnight"));
        (, uint256 left,) = vault[UNI].canSpend(plummy, 1);
        assertEq(left, CEILING - 6e6 < ALLOWANCE ? CEILING - 6e6 : ALLOWANCE); // household left wins
    }

    // ---- ask for a raise, approved from any chain ----

    function test_raiseApprovedOnOneChainLiftsTheMirrorEverywhere() public {
        _spend(andy, BASE, shop, 5e6);
        _spend(andy, UNI, shop, 5e6); // andy is out: $10 of $10
        (bool ok,, bytes32 why) = vault[ETH].canSpend(andy, 1e6);
        assertFalse(ok);
        assertEq(why, bytes32("over budget"));
        vault[UNI].approveRaise(andy, 2e6); // owner approves from Unichain
        _pump();
        assertEq(pm.extraToday(andy), 2e6);
        for (uint256 i; i < ids.length; ++i) {
            (bool ok2, uint256 left,) = vault[ids[i]].canSpend(andy, 1e6);
            assertTrue(ok2);
            assertEq(left, 2e6);
        }
    }

    function test_raiseAlsoTopsUpAgain() public {
        _spend(andy, BASE, shop, 5e6);
        _spend(andy, UNI, shop, 5e6);
        _spend(andy, ETH, shop, 1e6); // no allowance left: not topped up
        assertEq(_bal(andy, ETH), FLOAT - 1e6);
        vault[BASE].approveRaise(andy, 1e6);
        _pump();
        _spend(andy, ETH, shop, 1e6); // now refilled
        assertEq(_bal(andy, ETH), FLOAT - 1e6);
    }

    function test_raiseLastsOneDay() public {
        vault[ETH].approveRaise(plummy, 3e6);
        _pump();
        assertEq(pm.extraToday(plummy), 3e6);
        vm.warp(block.timestamp + 1 days + 1);
        _spend(plummy, BASE, shop, 1e6); // first react of the new day rolls it over
        assertEq(pm.extraToday(plummy), 0);
        assertEq(pm.householdExtraToday(), 0);
    }

    function test_onlyTheOwnerCanApproveARaise() public {
        vm.prank(thief);
        vm.expectRevert(Vault.NotOwner.selector);
        vault[BASE].approveRaise(andy, 1e6);
    }

    function test_raiseFromAStrangerContractIsIgnored() public {
        bytes32 t0 = keccak256("RaiseApproved(address,uint256,address)");
        IReactive.LogRecord memory r;
        r.chainId = BASE;
        r.contractAddress = thief;
        r.topic0 = uint256(t0);
        r.topic1 = uint256(uint160(andy));
        r.data = abi.encode(uint256(1e6), thief);
        vm.prank(address(0x8888888888888888888888888888888888888888));
        pm.react(r);
        assertEq(pm.extraToday(andy), 0);
    }

    /// Found by the invariant fuzzer: a raise must not outlive its day in any vault's mirror,
    /// even before the guard sees another event.
    function test_regression_raiseExpiresAtMidnightInTheMirror() public {
        vault[BASE].approveRaise(andy, 2e6);
        _pump();
        (, uint256 left,) = vault[ETH].canSpend(andy, 1);
        assertEq(left, ALLOWANCE + 2e6);
        vm.warp(block.timestamp + 1 days + 1);
        (, left,) = vault[ETH].canSpend(andy, 1);
        assertEq(left, ALLOWANCE);
    }
}
