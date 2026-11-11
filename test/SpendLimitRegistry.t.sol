// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {SpendLimitRegistry} from "../src/SpendLimitRegistry.sol";
import {ReactiveSim} from "./ReactiveSim.sol";

contract SpendLimitRegistryTest is Test {
    SpendLimitRegistry reg;
    uint256 constant AGENT_KEY = 0xA11CE;
    address agent = vm.addr(AGENT_KEY);
    address owner = makeAddr("owner");
    address thief = makeAddr("thief");
    address mirror = makeAddr("mirror");
    address soft = makeAddr("soft mirror");

    function setUp() public {
        reg = new SpendLimitRegistry();
    }

    function _sig(uint256 key, address payer, address controller, SpendLimitRegistry r)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                r.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(r.BIND_TYPEHASH(), payer, controller))
            )
        );
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(rr, s, v);
    }

    function _bound() internal {
        bytes memory sig = _sig(AGENT_KEY, agent, owner, reg);
        vm.prank(owner);
        reg.bindWithSig(agent, mirror, sig);
    }

    // ---- binding ----

    function test_unboundPayerHasNoMirror() public view {
        assertEq(reg.mirrorOf(agent), address(0));
        assertEq(reg.controllerOf(agent), address(0));
    }

    function test_controllerBindsWithThePayersSignature() public {
        vm.expectEmit();
        emit SpendLimitRegistry.Bound(agent, owner, mirror);
        _bound();
        assertEq(reg.mirrorOf(agent), mirror);
        assertEq(reg.controllerOf(agent), owner);
    }

    function test_payerCanBindItself() public {
        vm.prank(agent);
        reg.bind(owner, mirror);
        assertEq(reg.mirrorOf(agent), mirror);
        assertEq(reg.controllerOf(agent), owner);
    }

    function test_nobodyCanBindAPayerThatDidNotSign() public {
        // the thief signs with its own key, claiming to be the agent
        bytes memory sig = _sig(0xBAD, agent, thief, reg);
        vm.prank(thief);
        vm.expectRevert(SpendLimitRegistry.BadSignature.selector);
        reg.bindWithSig(agent, soft, sig);
    }

    function test_aSignatureForOneControllerIsUselessToAnother() public {
        bytes memory sig = _sig(AGENT_KEY, agent, owner, reg);
        vm.prank(thief);
        vm.expectRevert(SpendLimitRegistry.BadSignature.selector);
        reg.bindWithSig(agent, soft, sig);
    }

    function test_aSignatureForOneRegistryIsUselessOnAnother() public {
        SpendLimitRegistry other = new SpendLimitRegistry();
        bytes memory sig = _sig(AGENT_KEY, agent, owner, reg);
        vm.prank(owner);
        vm.expectRevert(SpendLimitRegistry.BadSignature.selector);
        other.bindWithSig(agent, mirror, sig);
    }

    function test_aSignatureForOneChainIsUselessOnAnother() public {
        bytes memory sig = _sig(AGENT_KEY, agent, owner, reg);
        vm.chainId(999);
        SpendLimitRegistry elsewhere = new SpendLimitRegistry();
        bytes memory wrongChain = _sig(AGENT_KEY, agent, owner, reg); // still reg's (old chain) domain
        assertEq(keccak256(sig), keccak256(wrongChain));
        vm.prank(owner);
        vm.expectRevert(SpendLimitRegistry.BadSignature.selector);
        elsewhere.bindWithSig(agent, mirror, sig);
    }

    function test_malformedSignatureIsRejected() public {
        vm.prank(owner);
        vm.expectRevert(SpendLimitRegistry.BadSignature.selector);
        reg.bindWithSig(agent, mirror, hex"1234");
        vm.prank(owner);
        vm.expectRevert(SpendLimitRegistry.BadSignature.selector);
        reg.bindWithSig(agent, mirror, new bytes(65)); // ecrecover returns zero
    }

    function test_zeroControllerIsRejected() public {
        vm.prank(agent);
        vm.expectRevert(SpendLimitRegistry.ZeroController.selector);
        reg.bind(address(0), mirror);
    }

    // ---- the point: a stolen payer key can't loosen anything ----

    function test_stolenPayerKeyCannotRebind() public {
        _bound();
        // direct call from the payer key
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.AlreadyBound.selector, agent));
        reg.bind(thief, soft);
        // or a fresh signature naming the thief as controller
        bytes memory sig = _sig(AGENT_KEY, agent, thief, reg);
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.AlreadyBound.selector, agent));
        reg.bindWithSig(agent, soft, sig);
        assertEq(reg.mirrorOf(agent), mirror);
    }

    function test_stolenPayerKeyCannotMoveOrLiftTheMirror() public {
        _bound();
        vm.startPrank(agent);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.NotController.selector, agent));
        reg.setMirror(agent, soft);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.NotController.selector, agent));
        reg.setMirror(agent, address(0));
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.NotController.selector, agent));
        reg.setController(agent, agent);
        vm.stopPrank();
        assertEq(reg.mirrorOf(agent), mirror);
        assertEq(reg.controllerOf(agent), owner);
    }

    function test_theBindSignatureCannotBeReplayed() public {
        bytes memory sig = _sig(AGENT_KEY, agent, owner, reg);
        vm.prank(owner);
        reg.bindWithSig(agent, mirror, sig);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.AlreadyBound.selector, agent));
        reg.bindWithSig(agent, soft, sig);
    }

    // ---- the controller ----

    function test_controllerMovesAndLiftsTheMirror() public {
        _bound();
        vm.startPrank(owner);
        vm.expectEmit();
        emit SpendLimitRegistry.MirrorSet(agent, soft);
        reg.setMirror(agent, soft);
        assertEq(reg.mirrorOf(agent), soft);
        reg.setMirror(agent, address(0));
        assertEq(reg.mirrorOf(agent), address(0));
        vm.stopPrank();
    }

    function test_controllerHandsOver() public {
        _bound();
        address next = makeAddr("next owner");
        vm.prank(owner);
        reg.setController(agent, next);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.NotController.selector, agent));
        reg.setMirror(agent, soft);
        vm.prank(next);
        reg.setMirror(agent, soft);
        assertEq(reg.mirrorOf(agent), soft);
    }

    function test_controllerCannotBeSetToZero() public {
        _bound();
        vm.prank(owner);
        vm.expectRevert(SpendLimitRegistry.ZeroController.selector);
        reg.setController(agent, address(0));
    }

    function test_oneControllersEntryIsNotAnothers() public {
        _bound();
        address other = vm.addr(0xB0B);
        vm.prank(other);
        reg.bind(thief, soft);
        vm.prank(thief);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.NotController.selector, agent));
        reg.setMirror(agent, soft);
    }

    function testFuzz_onlyTheControllerEverChangesABoundEntry(address caller, address m) public {
        _bound();
        vm.assume(caller != owner);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.NotController.selector, agent));
        reg.setMirror(agent, m);
        vm.expectRevert(abi.encodeWithSelector(SpendLimitRegistry.NotController.selector, agent));
        reg.setController(agent, caller);
        vm.stopPrank();
    }
}

interface IMirror {
    function canSpend(address payer, uint256 amount)
        external
        view
        returns (bool ok, uint256 left, bytes32 reason);
}

/// What a facilitator that has never heard of Pocket Money does: registry -> mirror -> canSpend.
contract RegistryWithVaultTest is ReactiveSim {
    SpendLimitRegistry reg;

    function setUp() public {
        _deploy();
        reg = new SpendLimitRegistry(); // the registry on the chain the facilitator settles on
        vm.prank(andy);
        reg.bind(address(this), address(vault[ETH]));
    }

    function _ask(address payer, uint256 amount) internal view returns (bool ok, bytes32 reason) {
        address mirror = reg.mirrorOf(payer);
        if (mirror == address(0)) return (true, "");
        (ok,, reason) = IMirror(mirror).canSpend(payer, amount);
    }

    function test_facilitatorAllowsWithinBudget() public view {
        (bool ok,) = _ask(andy, 1e6);
        assertTrue(ok);
    }

    function test_spendingOnOtherChainsIsRefusedHere() public {
        _spend(andy, BASE, shop, 4e6);
        _spend(andy, UNI, shop, 4e6);
        _spend(andy, BASE, shop, 2e6); // the whole $10, none of it on this chain
        (bool ok, bytes32 reason) = _ask(andy, 1);
        assertFalse(ok);
        assertEq(reason, bytes32("over budget"));
    }

    function test_unboundPayerIsNotLimited() public view {
        (bool ok,) = _ask(thief, 1e6);
        assertTrue(ok);
    }

    function test_mirrorThatDoesNotKnowThePayerSaysNo() public {
        vm.prank(thief);
        reg.bind(address(this), address(vault[ETH])); // bound to a mirror with no float for it
        (bool ok, bytes32 reason) = _ask(thief, 1);
        assertFalse(ok);
        assertEq(reason, bytes32("unknown agent"));
    }
}
