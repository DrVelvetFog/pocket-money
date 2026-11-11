// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Spend-limit registry: payer -> budget mirror
/// @notice Lets ANY x402 facilitator find a payer's spending limit without trusting the payer to
/// declare it. One registry per chain. A facilitator calls `mirrorOf(payer)`; zero means no limit
/// applies, otherwise it calls `canSpend(payer, amount)` on the mirror before settling.
///
/// Who may write an entry? A payer is usually a bare key (an agent's hot wallet), and that key is
/// exactly the thing that may get stolen. So the payer hands control away once, to a controller
/// (the owner's key, on another device), and from then on only the controller can change the
/// entry. A thief holding the payer key can't unbind it, repoint it, or bind it to a soft mirror.
///
/// The payer can bind by signing an EIP-712 message that the controller submits, so a payer that
/// holds no native gas (as an x402 payer needn't) can still be bound. Nobody can bind a payer
/// that hasn't consented, so entries can't be squatted.
///
/// Limits: binding is opt-in, so an unbound payer has no limit here. Signatures are ECDSA only;
/// a smart-account payer binds by calling `bind` itself.
contract SpendLimitRegistry {
    error AlreadyBound(address payer);
    error NotController(address payer);
    error BadSignature();
    error ZeroController();

    event Bound(address indexed payer, address indexed controller, address indexed mirror);
    event MirrorSet(address indexed payer, address indexed mirror);
    event ControllerSet(address indexed payer, address indexed controller);

    bytes32 public constant BIND_TYPEHASH = keccak256("Bind(address payer,address controller)");
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(address payer => address) public controllerOf;
    mapping(address payer => address) public mirrorOf;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("SpendLimitRegistry"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice The payer binds itself to a controller, in its own transaction.
    function bind(address controller, address mirror) external {
        _bind(msg.sender, controller, mirror);
    }

    /// @notice The controller binds a payer that signed `Bind(payer, controller)` for this
    /// registry. The payer sends nothing. The controller picks the mirror, as it may later.
    function bindWithSig(address payer, address mirror, bytes calldata sig) external {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(BIND_TYPEHASH, payer, msg.sender))
            )
        );
        if (sig.length != 65) revert BadSignature();
        address signer = ecrecover(digest, uint8(sig[64]), bytes32(sig[:32]), bytes32(sig[32:64]));
        if (signer == address(0) || signer != payer) revert BadSignature();
        _bind(payer, msg.sender, mirror);
    }

    /// @notice Point the payer at another mirror. Zero lifts the limit; that's the controller's call.
    function setMirror(address payer, address mirror) external {
        if (msg.sender != controllerOf[payer]) revert NotController(payer);
        mirrorOf[payer] = mirror;
        emit MirrorSet(payer, mirror);
    }

    /// @notice Hand control of a payer's entry to another key.
    function setController(address payer, address controller) external {
        if (msg.sender != controllerOf[payer]) revert NotController(payer);
        if (controller == address(0)) revert ZeroController();
        controllerOf[payer] = controller;
        emit ControllerSet(payer, controller);
    }

    function _bind(address payer, address controller, address mirror) private {
        if (controller == address(0)) revert ZeroController();
        if (controllerOf[payer] != address(0)) revert AlreadyBound(payer);
        controllerOf[payer] = controller;
        mirrorOf[payer] = mirror;
        emit Bound(payer, controller, mirror);
    }
}
