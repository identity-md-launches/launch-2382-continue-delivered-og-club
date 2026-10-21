// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockSwarmPepe} from "../../src/mocks/MockSwarmPepe.sol";
import {IDelegateRegistry} from "../../src/interfaces/IDelegateRegistry.sol";

/// @dev Delegations bind the caller, holder, collection, ID and rights, just like the requested query.
contract MockDelegateRegistry is IDelegateRegistry {
    mapping(bytes32 => bool) private _delegated;

    function delegateERC721(address to, address collection, uint256 id, bytes32 rights, bool enable) external {
        _delegated[keccak256(abi.encode(to, msg.sender, collection, id, rights))] = enable;
    }

    function checkDelegateForERC721(address to, address from, address collection, uint256 id, bytes32 rights)
        external
        view
        returns (bool)
    {
        return _delegated[keccak256(abi.encode(to, from, collection, id, rights))];
    }
}
