// test/ProviderRegistry.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20; // Match your ProviderRegistry.sol pragma

import "forge-std/Test.sol";
import "src/GPUCredit.sol";
import "src/ProviderRegistry.sol"; // We will inherit from this

// Make the test contract inherit from ProviderRegistry to bring events into scope
contract ProviderRegistryTest is Test, ProviderRegistry {
    // --- Contracts ---
    GPUCredit public gpuCredit;
    ProviderRegistry public registryInstance; // The actual instance we will test

    // --- Users ---
    address public admin = address(0x1);
    address public jobManagerPlaceholder = address(0x2); // Will act as slasher/rater
    address public provider1 = address(0x3);
    address public provider2 = address(0x4);
    // `slashedFundsRecipient` is inherited from ProviderRegistry.
    // We will set it on `registryInstance` in setUp.

    // --- Constants ---
    uint256 constant INITIAL_MINT_TO_PROVIDER = 1_000_000 * 1e18;
    uint256 constant STAKE_AMOUNT = 1000 * 1e18;

    // Constructor for ProviderRegistry (from which we inherit)
    // Provide dummy values, as we primarily interact with `registryInstance`.
    constructor() ProviderRegistry(address(0), address(0), address(0), address(0)) {}

    function setUp() public {
        // Deployer / Admin
        vm.startPrank(admin);

        // 1. Deploy GPUCredit
        gpuCredit = new GPUCredit("Test GPU Credit", "TGPUC");

        // 2. Deploy ProviderRegistry INSTANCE using GPUCredit for staking
        registryInstance = new ProviderRegistry(address(gpuCredit), admin, jobManagerPlaceholder, jobManagerPlaceholder);
        
        // Set the slashedFundsRecipient for the test instance
        address testInstanceSlashedFundsRecipient = address(0x5); // Define a test-specific address
        registryInstance.setSlashedFundsRecipient(testInstanceSlashedFundsRecipient);

        // Mint GPUCredit to providers
        gpuCredit.mint(provider1, INITIAL_MINT_TO_PROVIDER);
        gpuCredit.mint(provider2, INITIAL_MINT_TO_PROVIDER);

        vm.stopPrank(); // End admin prank

        // Providers approve the registryInstance to spend their GPUCredit for staking
        vm.startPrank(provider1);
        gpuCredit.approve(address(registryInstance), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(provider2);
        gpuCredit.approve(address(registryInstance), type(uint256).max);
        vm.stopPrank();
    }

    // --- Test Stake ---
    function test_Stake_Success() public {
        uint256 initialProviderBalance = gpuCredit.balanceOf(provider1);
        uint256 initialRegistryBalance = gpuCredit.balanceOf(address(registryInstance));

        vm.startPrank(provider1);
        vm.expectEmit(true, false, false, true, address(registryInstance));
        emit ProviderStaked(provider1, STAKE_AMOUNT); // Describe expected event
        registryInstance.stake(STAKE_AMOUNT); // Call function on the instance
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.stakeAmount, STAKE_AMOUNT, "Stake amount incorrect");
        assertTrue(info.exists, "Provider should exist after staking");
        assertEq(gpuCredit.balanceOf(provider1), initialProviderBalance - STAKE_AMOUNT, "Provider balance incorrect after stake");
        assertEq(gpuCredit.balanceOf(address(registryInstance)), initialRegistryBalance + STAKE_AMOUNT, "Registry balance incorrect after stake");
    }

    function testFail_Stake_ZeroAmount() public {
        vm.startPrank(provider1);
        vm.expectRevert(ProviderRegistry.AmountMustBePositive.selector);
        registryInstance.stake(0);
        vm.stopPrank();
    }

    function testFail_Stake_InsufficientAllowance() public {
        address provider3 = address(0x7);
        vm.prank(admin); // Mint to provider3 but don't approve registry
        gpuCredit.mint(provider3, STAKE_AMOUNT);

        vm.startPrank(provider3);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        registryInstance.stake(STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testFail_Stake_SendEthWhenUsingToken() public {
        vm.startPrank(provider1);
        vm.expectRevert(ProviderRegistry.NotUsingTokenStaking.selector);
        registryInstance.stake{value: 1 ether}(STAKE_AMOUNT);
        vm.stopPrank();
    }

    // --- Test Withdraw ---
    function test_Withdraw_Success() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);

        uint256 withdrawAmount = STAKE_AMOUNT / 2;
        uint256 initialProviderBalance = gpuCredit.balanceOf(provider1);
        uint256 initialRegistryBalance = gpuCredit.balanceOf(address(registryInstance));

        vm.startPrank(provider1);
        vm.expectEmit(true, false, false, true, address(registryInstance));
        emit ProviderWithdrew(provider1, withdrawAmount);
        registryInstance.withdraw(withdrawAmount);
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.stakeAmount, STAKE_AMOUNT - withdrawAmount);
        assertEq(gpuCredit.balanceOf(provider1), initialProviderBalance + withdrawAmount);
        assertEq(gpuCredit.balanceOf(address(registryInstance)), initialRegistryBalance - withdrawAmount);
    }

    function testFail_Withdraw_MoreThanStaked() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        vm.startPrank(provider1);
        vm.expectRevert(ProviderRegistry.InsufficientStake.selector);
        registryInstance.withdraw(STAKE_AMOUNT + 1);
        vm.stopPrank();
    }

    function testFail_Withdraw_NonExistentProvider() public {
        address nonProvider = address(0x8);
        vm.startPrank(nonProvider);
        vm.expectRevert(ProviderRegistry.ProviderNotFound.selector);
        registryInstance.withdraw(1);
        vm.stopPrank();
    }

    // --- Test Slash ---
    function test_Slash_Success() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);

        uint256 slashAmount = STAKE_AMOUNT / 4;
        address currentSlashedRecipient = registryInstance.slashedFundsRecipient(); // Get from instance
        uint256 initialSlashedFundsRecipientBalance = gpuCredit.balanceOf(currentSlashedRecipient);
        uint256 initialRegistryBalance = gpuCredit.balanceOf(address(registryInstance));

        vm.startPrank(jobManagerPlaceholder); // Slasher role
        vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderSlashed(provider1, jobManagerPlaceholder, slashAmount);
        registryInstance.slash(provider1, slashAmount);
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.stakeAmount, STAKE_AMOUNT - slashAmount);
        assertEq(gpuCredit.balanceOf(currentSlashedRecipient), initialSlashedFundsRecipientBalance + slashAmount);
        assertEq(gpuCredit.balanceOf(address(registryInstance)), initialRegistryBalance - slashAmount);
    }

    function testFail_Slash_WithoutRole() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        vm.startPrank(provider2); // provider2 doesn't have SLASHER_ROLE
        vm.expectRevert(); // AccessControl generic revert
        registryInstance.slash(provider1, STAKE_AMOUNT / 2);
        vm.stopPrank();
    }

    function test_Slash_MoreThanStaked_SlashesAll() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        address currentSlashedRecipient = registryInstance.slashedFundsRecipient(); // Get from instance
        uint256 initialSlashedFundsRecipientBalance = gpuCredit.balanceOf(currentSlashedRecipient);

        vm.startPrank(jobManagerPlaceholder);
        vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderSlashed(provider1, jobManagerPlaceholder, STAKE_AMOUNT);
        registryInstance.slash(provider1, STAKE_AMOUNT * 2);
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.stakeAmount, 0);
        assertEq(gpuCredit.balanceOf(currentSlashedRecipient), initialSlashedFundsRecipientBalance + STAKE_AMOUNT);
        assertEq(gpuCredit.balanceOf(address(registryInstance)), 0);
    }

    // --- Test Rate ---
    function test_Rate_Success() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);

        vm.startPrank(jobManagerPlaceholder); // Rater role
        vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderRated(provider1, jobManagerPlaceholder, true);
        registryInstance.rate(provider1, true);

        vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderRated(provider1, jobManagerPlaceholder, false);
        registryInstance.rate(provider1, false);
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.jobsDone, 2);
        assertEq(info.successfulJobs, 1);
    }

    function testFail_Rate_WithoutRole() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        vm.startPrank(provider2); // Not a rater
        vm.expectRevert();
        registryInstance.rate(provider1, true);
        vm.stopPrank();
    }

    function testFail_Rate_ProviderNotFound() public {
        vm.startPrank(jobManagerPlaceholder); // Rater
        vm.expectRevert(ProviderRegistry.ProviderNotFound.selector);
        registryInstance.rate(address(0x999), true); // Non-existent provider
        vm.stopPrank();
    }

     // --- Test Admin Functions ---
    function test_SetSlashedFundsRecipient() public {
        address newRecipient = address(0xABC);
        vm.startPrank(admin);
        vm.expectEmit(false, false, false, true, address(registryInstance));
        emit SlashedFundsRecipientSet(newRecipient);
        registryInstance.setSlashedFundsRecipient(newRecipient);
        vm.stopPrank();
        assertEq(registryInstance.slashedFundsRecipient(), newRecipient);
    }

    function testFail_SetSlashedFundsRecipient_NotAdmin() public {
        address newRecipient = address(0xABC);
        vm.startPrank(provider1); // Not admin
        vm.expectRevert();
        registryInstance.setSlashedFundsRecipient(newRecipient);
        vm.stopPrank();
    }
}