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
    ISystemContract.CallbackConfiguration_V_1_0[] internal _callbacks;
    address[] public callbackRequester;

    receive() external payable { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    function subscribe(uint256 c, address a, uint256 t0, uint256 t1, uint256 t2, uint256 t3) external {
        subs.push(Sub(c, a, t0, t1, t2, t3));
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        _callbacks.push(c);
        callbackRequester.push(msg.sender);
    }

    function subCount() external view returns (uint256) {
        return subs.length;
    }

    function callbackCount() external view returns (uint256) {
        return _callbacks.length;
    }

    function callbackAt(uint256 i)
        external
        view
        returns (ISystemContract.CallbackConfiguration_V_1_0 memory)
    {
        return _callbacks[i];
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

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}
