// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @dev Stand-in for Reactive's system contract (etched at 0x8888…8888 in tests).
contract MockSystem {
    struct Sub {
        uint256 chainId;
        address target;
        uint256 t0;
        uint256 t1;
        uint256 t2;
        uint256 t3;
    }

    Sub[] public subs;

    /// @dev Like the real system contract, a callback request is just an event (cheap), so the
    /// test's gas numbers for react() stay close to what Lasna measures.
    event CallbackRequested(uint256 chainId, address recipient, uint64 gasLimit, bytes payload, address requester);

    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subs.push(Sub(c, a, t0, t1, t2, t3));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        emit CallbackRequested(c.chainId, c.recipient, c.gasLimit, c.payload, msg.sender);
    }

    function subCount() external view returns (uint256) {
        return subs.length;
    }

    function subAt(uint256 i) external view returns (Sub memory) {
        return subs[i];
    }

}

/// @dev Stand-in for a destination chain's callback proxy: injects the requesting reactive
/// contract into the first argument, as the real proxy does, then calls the recipient.
contract MockProxy {
    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function deliver(address reactive, address recipient, bytes memory payload)
        external
        returns (bool ok, bytes memory ret)
    {
        assembly {
            mstore(add(payload, 36), reactive)
        }
        (ok, ret) = recipient.call(payload);
    }
}

contract MockUSDC {
    event Transfer(address indexed from, address indexed to, uint256 value);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @dev Stand-in for CCTP v2 TokenMessenger: pulls and burns, remembers the burn for the test
/// to "relay" by minting on the destination.
contract MockTokenMessenger {
    struct Burn {
        uint256 amount;
        uint32 domain;
        bytes32 recipient;
        uint256 maxFee;
        uint32 finality;
    }

    Burn[] public burns;

    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external {
        MockUSDC(burnToken).transferFrom(msg.sender, address(this), amount);
        MockUSDC(burnToken).burn(amount);
        burns.push(Burn(amount, destinationDomain, mintRecipient, maxFee, minFinalityThreshold));
    }

    function burnCount() external view returns (uint256) {
        return burns.length;
    }
}
