// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys one CuratedVault over a loan-token asset. Config via env (see DEPLOY.md):
///   ASSET        - the loan-token ERC-20 the vault allocates (must already exist on-chain)
///   VAULT_NAME / VAULT_SYMBOL - share-token metadata
///   CURATOR      - the address that sets markets/caps/queues; defaults to the deployer
/// Markets are added AFTER deploy via curator calls to addMarket/setCap/setSupplyQueue/setWithdrawQueue.
contract Deploy is Script {
    function run() external returns (CuratedVault vault) {
        address asset = vm.envAddress("ASSET");
        string memory name_ = vm.envOr("VAULT_NAME", string("Curated Vault"));
        string memory symbol_ = vm.envOr("VAULT_SYMBOL", string("cVLT"));
        vm.startBroadcast();
        address curator = vm.envOr("CURATOR", msg.sender);
        vault = new CuratedVault(IERC20(asset), name_, symbol_, curator);
        vm.stopBroadcast();
        console2.log("CuratedVault:", address(vault));
        console2.log("asset:", asset);
        console2.log("curator:", curator);
    }
}
