// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { ReactiveSim } from "./ReactiveSim.sol";
import { MockUSDC } from "./Mocks.sol";
import { PocketMoney } from "../src/PocketMoney.sol";
import { Vault } from "../src/Vault.sol";

/// @dev The fuzzer drives a whole household through random sequences: agents pay the shop or a
/// thief on any chain, Sui spends arrive through the inbox, the owner presses panic or changes
/// allowances, days roll over, and CCTP refills are relayed. After every step Reactive delivers
/// everything it would deliver (ReactiveSim._pump). The invariants below must hold throughout.
contract Handler is ReactiveSim {
    address[2] agentsArr;
    uint256 public initialSupply;
    uint256 public spends;
    mapping(address => uint256) public paidToThief;
    mapping(address => uint256) public maxAllowanceToday;
    uint256 public allowanceDay;
    uint256 relayed;
    uint256 refs;

    constructor() {
        _deploy();
        agentsArr = [andy, plummy];
        for (uint256 i; i < ids.length; ++i) initialSupply += _supplyOn(ids[i]);
        maxAllowanceToday[andy] = ALLOWANCE;
        maxAllowanceToday[plummy] = ALLOWANCE;
        pm.setRebalancePolicy(97e6, 99e6, 0); // vaults start at $100: refills kick in quickly
        _pump();
    }

    // ---- views for the invariant contract ----
    function agents() external view returns (address[2] memory) {
        return agentsArr;
    }
    function chainIds() external view returns (uint256[] memory) {
        return ids;
    }
    function guard() external view returns (PocketMoney) {
        return pm;
    }
    function vaultOf(uint256 id) external view returns (Vault) {
        return vault[id];
    }
    function usdcOf(uint256 id) external view returns (MockUSDC) {
        return usdc[id];
    }
    function supply() external view returns (uint256 s) {
        for (uint256 i; i < ids.length; ++i) s += _supplyOn(ids[i]);
    }
    function _supplyOn(uint256 id) internal view returns (uint256) {
        MockUSDC u = usdc[id];
        return u.balanceOf(address(vault[id])) + u.balanceOf(andy) + u.balanceOf(plummy) + u.balanceOf(shop)
            + u.balanceOf(thief) + u.balanceOf(address(tm));
    }

    // ---- actions ----

    function spend(uint256 agentSeed, uint256 chainSeed, uint256 amountSeed, uint256 straySeed) external {
        address a = agentsArr[agentSeed % 2];
        uint256 id = ids[chainSeed % ids.length];
        uint256 bal = usdc[id].balanceOf(a);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
        bool stray = straySeed % 25 == 0;
        if (stray) paidToThief[a] += amount;
        spends++;
        _spend(a, id, stray ? thief : shop, amount);
        _relay();
    }

    function suiSpend(uint256 agentSeed, uint256 amountSeed, uint256 straySeed) external {
        address a = agentsArr[agentSeed % 2];
        spends++;
        _foreign(a, straySeed % 25 == 0 ? SUI_THIEF : SUI_SHOP, bound(amountSeed, 1, 5e6), bytes32(++refs));
        _relay();
    }

    function panic(uint256 chainSeed) external {
        vault[ids[chainSeed % ids.length]].panic();
        _pump();
        _relay();
    }

    function setAllowance(uint256 agentSeed, uint256 amountSeed) external {
        address a = agentsArr[agentSeed % 2];
        uint256 amt = bound(amountSeed, 0, 20e6);
        _newDayCheck();
        if (amt > maxAllowanceToday[a]) maxAllowanceToday[a] = amt;
        pm.setAgent(a, amt);
        _pump();
        _relay();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 2 days));
    }

    function _newDayCheck() internal {
        if (block.timestamp >= pm.dayStart() + 1 days || pm.day() != allowanceDay) {
            // the guard will roll on its next react; allowances set from here count for the new day
            allowanceDay = pm.day() + (block.timestamp >= pm.dayStart() + 1 days ? 1 : 0);
            (,, uint256 aa,,) = pm.agents(andy);
            (,, uint256 pa,,) = pm.agents(plummy);
            maxAllowanceToday[andy] = aa;
            maxAllowanceToday[plummy] = pa;
        }
    }

    /// Relay every CCTP burn not yet minted (instantly, fee 0), like the relayer.
    function _relay() internal {
        for (; relayed < tm.burnCount(); ++relayed) {
            (uint256 amount, uint32 d, bytes32 recipient,,) = tm.burns(relayed);
            uint256 to;
            for (uint256 i; i < ids.length; ++i) if (domain[ids[i]] == d) to = ids[i];
            usdc[to].mint(address(uint160(uint256(recipient))), amount);
        }
        _pump();
    }
}

contract PocketMoneyInvariants is StdInvariant, Test {
    Handler h;

    function setUp() public {
        h = new Handler();
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](5);
        sel[0] = Handler.spend.selector;
        sel[1] = Handler.suiSpend.selector;
        sel[2] = Handler.panic.selector;
        sel[3] = Handler.setAllowance.selector;
        sel[4] = Handler.warp.selector;
        targetSelector(FuzzSelector({ addr: address(h), selectors: sel }));
    }

    /// P1: no agent ever holds more than its float on any chain.
    function invariant_P1_agentNeverAboveFloat() public view {
        uint256[] memory ids = h.chainIds();
        address[2] memory ag = h.agents();
        for (uint256 i; i < ids.length; ++i) {
            for (uint256 j; j < 2; ++j) {
                assertLe(h.usdcOf(ids[i]).balanceOf(ag[j]), h.vaultOf(ids[i]).floatOf(ag[j]));
            }
        }
    }

    /// P2: top-ups never exceed the household ceiling (or an agent's allowance) in a day.
    function invariant_P2_topUpsWithinCeilingAndAllowance() public view {
        PocketMoney pm = h.guard();
        assertLe(pm.toppedUpToday(), pm.ceiling());
        address[2] memory ag = h.agents();
        for (uint256 j; j < 2; ++j) {
            (,,,, uint256 topped) = pm.agents(ag[j]);
            assertLe(topped, h.maxAllowanceToday(ag[j]));
        }
    }

    /// P3: whatever a thief collects from an agent's key is bounded by that agent's floats.
    function invariant_P3_stolenKeyBoundedByFloats() public view {
        uint256[] memory ids = h.chainIds();
        address[2] memory ag = h.agents();
        for (uint256 j; j < 2; ++j) {
            uint256 floats;
            for (uint256 i; i < ids.length; ++i) floats += h.vaultOf(ids[i]).floatOf(ag[j]);
            assertLe(h.paidToThief(ag[j]), floats);
        }
    }

    /// P4: a quarantined agent is frozen on every chain; a panic freezes every vault.
    function invariant_P4_freezesReachEveryChain() public view {
        PocketMoney pm = h.guard();
        uint256[] memory ids = h.chainIds();
        address[2] memory ag = h.agents();
        for (uint256 j; j < 2; ++j) {
            (, bool q,,,) = pm.agents(ag[j]);
            if (!q) continue;
            for (uint256 i; i < ids.length; ++i) assertTrue(h.vaultOf(ids[i]).agentFrozen(ag[j]));
        }
        if (pm.panicked()) {
            for (uint256 i; i < ids.length; ++i) assertTrue(h.vaultOf(ids[i]).frozen());
        }
    }

    /// P9: the budget mirror on every chain agrees with the guard (day boundaries included).
    function invariant_P9_mirrorMatchesGuard() public view {
        PocketMoney pm = h.guard();
        uint256[] memory ids = h.chainIds();
        address[2] memory ag = h.agents();
        bool newDay = block.timestamp >= pm.dayStart() + 1 days;
        uint256 hLeft = newDay ? pm.ceiling() : _left(pm.ceiling(), pm.spentToday());
        for (uint256 j; j < 2; ++j) {
            (,, uint256 allowance, uint256 spent,) = pm.agents(ag[j]);
            uint256 aLeft = newDay ? allowance : _left(allowance, spent);
            uint256 expected = aLeft < hLeft ? aLeft : hLeft;
            for (uint256 i; i < ids.length; ++i) assertEq(h.vaultOf(ids[i]).spendLeft(ag[j]), expected);
        }
    }

    /// P10: the guard's view of every vault's USDC matches the chain (no refill in flight).
    function invariant_P10_guardTracksVaultBalances() public view {
        PocketMoney pm = h.guard();
        uint256[] memory ids = h.chainIds();
        for (uint256 i; i < ids.length; ++i) {
            assertEq(pm.vaultBalanceOf(ids[i]), h.usdcOf(ids[i]).balanceOf(address(h.vaultOf(ids[i]))));
            assertFalse(pm.rebalancing(ids[i]));
        }
    }

    /// P11: USDC is conserved across all chains (CCTP burns are always minted back).
    function invariant_P11_usdcConserved() public view {
        assertEq(h.supply(), h.initialSupply());
    }

    /// P12: every payment is in the receipt chain, once.
    function invariant_P12_everySpendHasAReceipt() public view {
        assertEq(h.guard().receiptCount(), h.spends());
    }

    function _left(uint256 cap, uint256 used) internal pure returns (uint256) {
        return used >= cap ? 0 : cap - used;
    }
}
