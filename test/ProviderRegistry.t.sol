// test/ProviderRegistry.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24; // Match your ProviderRegistry.sol pragma

import "forge-std/Test.sol";
import "src/GPUCredit.sol";
import "src/ProviderRegistry.sol"; // We will inherit from this
import "@openzeppelin/contracts/access/AccessControl.sol"; // Import AccessControl for its error selector

// Make the test contract inherit from ProviderRegistry to bring events into scope
contract ProviderRegistryTest is Test, ProviderRegistry {
    // --- Contracts ---
    GPUCredit public gpuCredit;
    ProviderRegistry public registryInstance; // The actual instance we will test

    // --- Users ---
    address public admin = address(0x1);
    address public slasherRater = address(0x2); // Will act as slasher/rater
    address public provider1 = address(0x3);
    address public provider2 = address(0x4);
    address public slashedFundsRecipientActual = address(0x5); // Defined recipient for tests

    // --- Constants ---
    uint256 constant INITIAL_MINT_TO_PROVIDER = 1_000_000 * 1e18;
    uint256 constant STAKE_AMOUNT = 1000 * 1e18;

    // Constructor for ProviderRegistry (from which we inherit)
    constructor() ProviderRegistry(address(0), address(0), address(0), address(0)) {}


    function setUp() public {
        vm.startPrank(admin);
        gpuCredit = new GPUCredit("Test GPU Credit", "TGPUC");
        registryInstance = new ProviderRegistry(address(gpuCredit), admin, slasherRater, slasherRater);
        registryInstance.setSlashedFundsRecipient(slashedFundsRecipientActual);
        gpuCredit.mint(provider1, INITIAL_MINT_TO_PROVIDER);
        gpuCredit.mint(provider2, INITIAL_MINT_TO_PROVIDER);
        vm.stopPrank();

        // Ensure provider1 has some ETH for tests that might send ETH
        vm.deal(provider1, 5 ether); // Give provider1 5 ETH
        vm.deal(provider2, 5 ether); // Give provider2 5 ETH (good practice if it also makes calls)


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
        emit ProviderStaked(provider1, STAKE_AMOUNT);
        registryInstance.stake(STAKE_AMOUNT);
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.stakeAmount, STAKE_AMOUNT, "Stake amount incorrect");
        assertTrue(info.exists, "Provider should exist after staking");
        assertEq(gpuCredit.balanceOf(provider1), initialProviderBalance - STAKE_AMOUNT, "Provider balance incorrect after stake");
        assertEq(gpuCredit.balanceOf(address(registryInstance)), initialRegistryBalance + STAKE_AMOUNT, "Registry balance incorrect after stake");
    }

    function test_Stake_ZeroAmount_Reverts() public {
        vm.startPrank(provider1);
        vm.expectRevert(ProviderRegistry.AmountMustBePositive.selector);
        registryInstance.stake(0);
        vm.stopPrank();
    }

    function test_Stake_InsufficientAllowance_Reverts() public {
        address provider3 = vm.addr(0x7);
        vm.deal(provider3, 5 ether); // Ensure provider3 has ETH if it needs to pay gas
        vm.prank(admin);
        gpuCredit.mint(provider3, STAKE_AMOUNT);

        vm.startPrank(provider3);
        bytes memory expectedRevertData = abi.encodeWithSelector(
            bytes4(keccak256("ERC20InsufficientAllowance(address,uint256,uint256)")),
            address(registryInstance),
            0,
            STAKE_AMOUNT
        );
        vm.expectRevert(expectedRevertData);
        registryInstance.stake(STAKE_AMOUNT);
        vm.stopPrank();
    }

    function test_Stake_SendEthWhenUsingToken_Reverts() public {
        vm.startPrank(provider1); // provider1 has ETH from setUp
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

    function test_Withdraw_MoreThanStaked_Reverts() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        vm.startPrank(provider1);

        bytes memory expectedRevertData = abi.encodeWithSelector(
            ProviderRegistry.InsufficientStake.selector,
            STAKE_AMOUNT,
            STAKE_AMOUNT + 1
        );
        vm.expectRevert(expectedRevertData);
        registryInstance.withdraw(STAKE_AMOUNT + 1);
        vm.stopPrank();
    }

    function test_Withdraw_NonExistentProvider_Reverts() public {
        address nonProvider = address(0x8);
        vm.deal(nonProvider, 5 ether); // Ensure nonProvider has ETH if it needs to pay gas
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
        address currentSlashedRecipient = registryInstance.slashedFundsRecipient();
        uint256 initialSlashedFundsRecipientBalance = gpuCredit.balanceOf(currentSlashedRecipient);
        uint256 initialRegistryBalance = gpuCredit.balanceOf(address(registryInstance));

        vm.startPrank(slasherRater);
        vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderSlashed(provider1, slasherRater, slashAmount);
        registryInstance.slash(provider1, slashAmount);
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.stakeAmount, STAKE_AMOUNT - slashAmount);
        assertEq(gpuCredit.balanceOf(currentSlashedRecipient), initialSlashedFundsRecipientBalance + slashAmount);
        assertEq(gpuCredit.balanceOf(address(registryInstance)), initialRegistryBalance - slashAmount);
    }

    function test_Slash_WithoutRole_Reverts() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);

        vm.startPrank(provider2); // provider2 has ETH from setUp

        bytes32 slasherRole = registryInstance.SLASHER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                provider2,
                slasherRole
            )
        );
        registryInstance.slash(provider1, STAKE_AMOUNT / 2);
        vm.stopPrank();
    }

    function test_Slash_MoreThanStaked_SlashesAll() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        address currentSlashedRecipient = registryInstance.slashedFundsRecipient();
        uint256 initialSlashedFundsRecipientBalance = gpuCredit.balanceOf(currentSlashedRecipient);

        vm.startPrank(slasherRater);
        vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderSlashed(provider1, slasherRater, STAKE_AMOUNT);
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

        vm.startPrank(slasherRater);
        vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderRated(provider1, slasherRater, true);
        registryInstance.rate(provider1, true);

        vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderRated(provider1, slasherRater, false);
        registryInstance.rate(provider1, false);
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.jobsDone, 2);
        assertEq(info.successfulJobs, 1);
    }

    function test_Rate_WithoutRole_Reverts() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        vm.startPrank(provider2); // provider2 has ETH from setUp

        bytes32 raterRole = registryInstance.RATER_ROLE();
        vm.expectRevert(
             abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                provider2,
                raterRole
            )
        );
        registryInstance.rate(provider1, true);
        vm.stopPrank();
    }

    function test_Rate_ProviderNotFound_Reverts() public {
        vm.startPrank(slasherRater);
        vm.expectRevert(ProviderRegistry.ProviderNotFound.selector);
        registryInstance.rate(address(0x999), true);
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

    function test_SetSlashedFundsRecipient_NotAdmin_Reverts() public {
        address newRecipient = address(0xABC);
        vm.startPrank(provider1); // provider1 has ETH from setUp

        bytes32 adminRole = registryInstance.DEFAULT_ADMIN_ROLE();
         vm.expectRevert(
             abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                provider1,
                adminRole
            )
        );
        registryInstance.setSlashedFundsRecipient(newRecipient);
        vm.stopPrank();
    }

    function test_Stake_Token_ReStake() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);

        uint256 secondStakeAmount = STAKE_AMOUNT / 2;
        uint256 initialProviderBalance = gpuCredit.balanceOf(provider1);
        uint256 initialRegistryBalance = gpuCredit.balanceOf(address(registryInstance));

        vm.startPrank(provider1);
        vm.expectEmit(true, false, false, true, address(registryInstance));
        emit ProviderStaked(provider1, secondStakeAmount);
        registryInstance.stake(secondStakeAmount);
        vm.stopPrank();

        ProviderRegistry.ProviderInfo memory info = registryInstance.getProviderInfo(provider1);
        assertEq(info.stakeAmount, STAKE_AMOUNT + secondStakeAmount);
        assertEq(gpuCredit.balanceOf(provider1), initialProviderBalance - secondStakeAmount);
        assertEq(gpuCredit.balanceOf(address(registryInstance)), initialRegistryBalance + secondStakeAmount);
    }

    function test_Withdraw_Token_AllStake() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        uint256 balProviderBefore = gpuCredit.balanceOf(provider1);

        vm.startPrank(provider1);
        vm.expectEmit(true, false, false, true, address(registryInstance));
        emit ProviderWithdrew(provider1, STAKE_AMOUNT);
        registryInstance.withdraw(STAKE_AMOUNT);
        vm.stopPrank();

        assertEq(registryInstance.getProviderInfo(provider1).stakeAmount, 0);
        assertEq(gpuCredit.balanceOf(provider1), balProviderBefore + STAKE_AMOUNT);
        assertEq(gpuCredit.balanceOf(address(registryInstance)), 0);
    }

    function test_Withdraw_Token_ZeroAmount_Reverts() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        vm.startPrank(provider1);
        vm.expectRevert(ProviderRegistry.AmountMustBePositive.selector);
        registryInstance.withdraw(0);
        vm.stopPrank();
    }

    function test_Slash_Token_ZeroAmount_Reverts() public {
        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        vm.startPrank(slasherRater);
        vm.expectRevert(ProviderRegistry.AmountMustBePositive.selector);
        registryInstance.slash(provider1, 0);
        vm.stopPrank();
    }

    function test_Slash_Token_ProviderNotFound_Reverts() public {
        vm.startPrank(slasherRater);
        vm.expectRevert(ProviderRegistry.ProviderNotFound.selector);
        registryInstance.slash(vm.addr(0x99), STAKE_AMOUNT / 2);
        vm.stopPrank();
    }

     function test_Slash_Token_SlashedFundsRecipientIsZero() public {
        vm.prank(admin);
        registryInstance.setSlashedFundsRecipient(address(0));

        vm.prank(provider1);
        registryInstance.stake(STAKE_AMOUNT);
        uint256 balRegistryAfterStake = gpuCredit.balanceOf(address(registryInstance));

        uint256 slashAmount = STAKE_AMOUNT / 4;
        vm.startPrank(slasherRater);
         vm.expectEmit(true, true, false, true, address(registryInstance));
        emit ProviderSlashed(provider1, slasherRater, slashAmount);
        registryInstance.slash(provider1, slashAmount);
        vm.stopPrank();

        assertEq(registryInstance.getProviderInfo(provider1).stakeAmount, STAKE_AMOUNT - slashAmount);
        assertEq(gpuCredit.balanceOf(address(registryInstance)), balRegistryAfterStake);
    }
}