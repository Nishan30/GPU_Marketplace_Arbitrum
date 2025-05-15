// test/GPUCredit.t.sol
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24; // Match your GPUCredit.sol pragma

import "forge-std/Test.sol";
import "src/GPUCredit.sol"; // Adjust path if your contract is elsewhere
import "@openzeppelin/contracts/utils/Strings.sol";

contract GPUCreditTest is Test {
    GPUCredit public gpuCredit;

    // Define Private Keys and derive addresses for test users
    // Standard Foundry default private keys for accounts 0, 1, 2, 3
    uint256 constant ADMIN_PK  = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant USER1_PK  = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant USER2_PK  = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant MINTER_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    address public admin  = vm.addr(ADMIN_PK);
    address public user1  = vm.addr(USER1_PK);  // user1 will sign the permit
    address public user2  = vm.addr(USER2_PK);  // user2 will be the spender in permit
    address public minter = vm.addr(MINTER_PK); // minter has MINTER_ROLE

    // For ERC20Permit EIP-712 signature
    bytes32 constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c8;


    function setUp() public {
        vm.startPrank(admin); // Admin deploys the contract
        gpuCredit = new GPUCredit("Test GPU Credit", "TGPUC");
        // Admin grants MINTER_ROLE to the 'minter' address
        gpuCredit.grantRole(gpuCredit.MINTER_ROLE(), minter); 
        vm.stopPrank();

        // Deal ETH to users (for potential gas if they were real EOAs, not strictly needed for most tests here)
        vm.deal(user1, 1 ether);
        vm.deal(user2, 1 ether);
        vm.deal(minter, 1 ether); // Minter might also make calls
    }

    // This function reads state, so it should be `view`
    function test_InitialState() public view { // <<<< FIXED: Added view
        assertEq(gpuCredit.name(), "Test GPU Credit", "Name mismatch");
        assertEq(gpuCredit.symbol(), "TGPUC", "Symbol mismatch");
        assertTrue(gpuCredit.hasRole(gpuCredit.DEFAULT_ADMIN_ROLE(), admin), "Admin role not set for deployer");
        assertTrue(gpuCredit.hasRole(gpuCredit.MINTER_ROLE(), minter), "Minter role not granted correctly");
        assertEq(gpuCredit.totalSupply(), 0, "Initial total supply should be 0");
    }

    function test_Mint() public {
        uint256 mintAmount = 1000 * 1e18;
        vm.startPrank(minter); // Only designated minter can mint
        gpuCredit.mint(user1, mintAmount);
        vm.stopPrank();

        assertEq(gpuCredit.balanceOf(user1), mintAmount, "User1 balance after mint mismatch");
        assertEq(gpuCredit.totalSupply(), mintAmount, "Total supply after mint mismatch");
    }

    function test_Transfer() public {
        uint256 mintAmount = 500 * 1e18;
        uint256 transferAmount = 200 * 1e18;

        vm.prank(minter);
        gpuCredit.mint(user1, mintAmount);

        vm.startPrank(user1);
        assertTrue(gpuCredit.transfer(user2, transferAmount), "Transfer failed");
        vm.stopPrank();

        assertEq(gpuCredit.balanceOf(user1), mintAmount - transferAmount, "Sender balance incorrect after transfer");
        assertEq(gpuCredit.balanceOf(user2), transferAmount, "Receiver balance incorrect after transfer");
    }

    function testFail_Transfer_InsufficientBalance() public {
        uint256 transferAmount = 100 * 1e18;
        vm.startPrank(user1); // user1 has 0 balance initially
        vm.expectRevert(bytes("ERC20: transfer amount exceeds balance"));
        gpuCredit.transfer(user2, transferAmount);
        vm.stopPrank();
    }

    function test_ApproveAndTransferFrom() public {
        uint256 mintAmount = 500 * 1e18;
        uint256 approveAmount = 300 * 1e18;
        uint256 transferFromAmount = 150 * 1e18;

        vm.prank(minter);
        gpuCredit.mint(user1, mintAmount);

        vm.startPrank(user1);
        assertTrue(gpuCredit.approve(user2, approveAmount), "Approve failed");
        vm.stopPrank();
        assertEq(gpuCredit.allowance(user1, user2), approveAmount, "Allowance mismatch after approve");

        vm.startPrank(user2);
        assertTrue(gpuCredit.transferFrom(user1, user2, transferFromAmount), "transferFrom failed");
        vm.stopPrank();

        assertEq(gpuCredit.balanceOf(user1), mintAmount - transferFromAmount);
        assertEq(gpuCredit.balanceOf(user2), transferFromAmount);
        assertEq(gpuCredit.allowance(user1, user2), approveAmount - transferFromAmount);
    }

    function testFail_TransferFrom_InsufficientAllowance() public {
        uint256 mintAmount = 500 * 1e18;
        uint256 approveAmount = 100 * 1e18;
        uint256 transferFromAmount = 150 * 1e18;

        vm.prank(minter);
        gpuCredit.mint(user1, mintAmount);

        vm.prank(user1);
        gpuCredit.approve(user2, approveAmount);

        vm.startPrank(user2);
        vm.expectRevert(bytes("ERC20: insufficient allowance"));
        gpuCredit.transferFrom(user1, user2, transferFromAmount);
        vm.stopPrank();
    }

    function testFail_Permit_InvalidSignature() public {
        uint256 value = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        // Get nonce for user1, though it doesn't matter much for an invalid signature test
        uint256 currentNonce = gpuCredit.nonces(user1); // <<<< FIXED: 'nonce' variable is used
        (uint8 v, bytes32 r, bytes32 s) = (27, keccak256("invalid r"), keccak256("invalid s"));

        vm.startPrank(user2);
        vm.expectRevert(bytes("ERC20Permit: invalid signature"));
        gpuCredit.permit(user1, user2, value, deadline, v, r, s); // user1 needs nonce if it were valid
        vm.stopPrank();
    }

    function testFail_Permit_ExpiredDeadline() public {
        uint256 value = 100e18;
        uint256 deadline = block.timestamp - 1 seconds; // Expired!
        uint256 currentNonce = gpuCredit.nonces(user1); // <<<< FIXED: 'nonce' variable is used

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, user1, user2, value, currentNonce, deadline));
        bytes32 domainSeparator = gpuCredit.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER1_PK, digest);

        vm.startPrank(user2);
        vm.expectRevert(bytes("ERC20Permit: expired deadline"));
        gpuCredit.permit(user1, user2, value, deadline, v, r, s);
        vm.stopPrank();
    }
}