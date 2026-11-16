// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MockUSDC}     from "../src/MockUSDC.sol";
import {RoscaFactory} from "../src/RoscaFactory.sol";

contract Deploy is Script {
    function run() external {
        // Đọc Private Key từ file .env (Bạn cần tạo file .env chứa PRIVATE_KEY=0x...)
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mock USDC
        MockUSDC usdc = new MockUSDC();
        console2.log("MockUSDC deployed at:", address(usdc));
        
        // 2. Deploy Factory
        RoscaFactory factory = new RoscaFactory(address(usdc));
        console2.log("RoscaFactory deployed at:", address(factory));

        vm.stopBroadcast();
    }
}