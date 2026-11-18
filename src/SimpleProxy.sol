// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;

// Minimal EIP-1967 proxy used only to test the upgradeable PriceFeed the same
// way it is deployed on mainnet (implementation behind a proxy). No admin
// logic: the implementation address is fixed at construction.
contract SimpleProxy {
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address _implementation, bytes memory _initData) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        address impl = _implementation;
        assembly {
            sstore(slot, impl)
        }
        if (_initData.length > 0) {
            (bool ok, ) = _implementation.delegatecall(_initData);
            require(ok, "SimpleProxy: init failed");
        }
    }

    fallback() external payable {
        bytes32 slot = IMPLEMENTATION_SLOT;
        address impl;
        assembly {
            impl := sload(slot)
        }
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    receive() external payable {}
}
