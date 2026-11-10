// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { PocketMoney } from "../src/PocketMoney.sol";
import { Vault, IERC20Min, ITokenMessengerV2 } from "../src/Vault.sol";
import { SpendInbox } from "../src/SpendInbox.sol";
import { MockSystem, MockProxy, MockUSDC, MockTokenMessenger } from "./Mocks.sol";

/// @dev A whole Pocket Money household on three "chains" inside one EVM, plus a simulator that
/// plays Reactive Network: every log any contract emits is matched against the guard's real
/// subscriptions (chain id looked up from the emitter) and fed to react(); requested callbacks
/// are delivered through the proxy mock; repeat until nothing new happens.
abstract contract ReactiveSim is Test {
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

    function _deploy() internal {
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

}
