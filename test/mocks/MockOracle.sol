// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IOracle} from "../../src/interfaces/IOracle.sol";

contract MockOracle is IOracle {
    uint256 public p;

    constructor(uint256 p_) {
        p = p_;
    }

    function set(uint256 p_) external {
        p = p_;
    }

    function price() external view returns (uint256) {
        return p;
    }
}
