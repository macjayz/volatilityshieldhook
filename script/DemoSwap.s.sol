// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {DeployedAddresses} from "./DeployedAddresses.sol";

contract DemoSwap is Script {
    function run() external {
        vm.startBroadcast();

        // Log the deployed hook address
        console2.log("Hook deployed at:", DeployedAddresses.HOOK_ADDRESS);

        // Any other demo logic can go here later
        // Keep it minimal to ensure it compiles

        vm.stopBroadcast();
    }
}