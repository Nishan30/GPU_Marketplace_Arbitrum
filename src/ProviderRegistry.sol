// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ProviderRegistry is AccessControl, ReentrancyGuard {
    // ... (rest of the ProviderRegistry code from previous response) ...
    // --- Roles ---
    bytes32 public constant SLASHER_ROLE = keccak256("SLASHER_ROLE");
    bytes32 public constant RATER_ROLE = keccak256("RATER_ROLE");

    // --- Structs ---
    struct ProviderInfo {
        uint256 stakeAmount;
        uint256 jobsDone;
        uint256 successfulJobs;
        bool exists;
    }

    // --- State Variables ---
    IERC20 public immutable stakeToken;
    mapping(address => ProviderInfo) public providers;
    address public slashedFundsRecipient;

    // --- Events ---
    event ProviderStaked(address indexed provider, uint256 amount);
    event ProviderWithdrew(address indexed provider, uint256 amount);
    event ProviderSlashed(address indexed provider, address indexed slasher, uint256 amount);
    event ProviderRated(address indexed provider, address indexed rater, bool success);
    event SlashedFundsRecipientSet(address recipient);

    // --- Errors ---
    error InsufficientStake(uint256 required, uint256 actual);
    error AmountMustBePositive();
    error ProviderNotFound();
    error TransferFailed();
    error NotUsingEthStaking();
    error NotUsingTokenStaking();

    constructor(address _stakeTokenAddress, address _initialAdmin, address _initialSlasher, address _initialRater) {
         if (_stakeTokenAddress != address(0)) {
            stakeToken = IERC20(_stakeTokenAddress);
        }
        _grantRole(DEFAULT_ADMIN_ROLE, _initialAdmin);
        _grantRole(SLASHER_ROLE, _initialSlasher);
        _grantRole(RATER_ROLE, _initialRater);
        slashedFundsRecipient = _initialAdmin;
    }

    function stake(uint256 _amount) public payable nonReentrant {
        uint256 stakeAmount = msg.value;
        if (address(stakeToken) != address(0)) {
            if (msg.value > 0) revert NotUsingTokenStaking();
            stakeAmount = _amount;
            if (stakeAmount == 0) revert AmountMustBePositive();
            bool success = stakeToken.transferFrom(msg.sender, address(this), stakeAmount);
            if (!success) revert TransferFailed();
        } else {
            if (stakeAmount == 0) revert AmountMustBePositive();
             if (_amount != 0) revert NotUsingEthStaking();
        }
        ProviderInfo storage provider = providers[msg.sender];
        provider.stakeAmount += stakeAmount;
        provider.exists = true;
        emit ProviderStaked(msg.sender, stakeAmount);
    }

    function withdraw(uint256 _amount) public nonReentrant {
        ProviderInfo storage provider = providers[msg.sender];
        if (!provider.exists) revert ProviderNotFound();
        if (_amount == 0) revert AmountMustBePositive();
        if (provider.stakeAmount < _amount) {
            revert InsufficientStake(provider.stakeAmount, _amount);
        }
        provider.stakeAmount -= _amount;
        emit ProviderWithdrew(msg.sender, _amount);
        if (address(stakeToken) != address(0)) {
            bool success = stakeToken.transfer(msg.sender, _amount);
             if (!success) revert TransferFailed();
        } else {
            (bool success, ) = msg.sender.call{value: _amount}("");
             if (!success) revert TransferFailed();
        }
    }

     function slash(address _provider, uint256 _amount) public onlyRole(SLASHER_ROLE) {
         ProviderInfo storage provider = providers[_provider];
         if (!provider.exists) revert ProviderNotFound();
         if (_amount == 0) revert AmountMustBePositive();
         uint256 slashAmount = (_amount > provider.stakeAmount) ? provider.stakeAmount : _amount;
         provider.stakeAmount -= slashAmount;
         emit ProviderSlashed(_provider, msg.sender, slashAmount);
         if (slashedFundsRecipient != address(0) && slashAmount > 0) {
             if (address(stakeToken) != address(0)) {
                 stakeToken.transfer(slashedFundsRecipient, slashAmount);
             } else {
                 (bool success, ) = slashedFundsRecipient.call{value: slashAmount}("");
             }
         }
     }

    function rate(address _provider, bool _success) public onlyRole(RATER_ROLE) {
        ProviderInfo storage provider = providers[_provider];
        if (!provider.exists) revert ProviderNotFound();
        provider.jobsDone++;
        if (_success) {
            provider.successfulJobs++;
        }
        emit ProviderRated(_provider, msg.sender, _success);
    }

    function getProviderInfo(address _provider) public view returns (ProviderInfo memory) {
        return providers[_provider];
    }

     function setSlashedFundsRecipient(address _recipient) public onlyRole(DEFAULT_ADMIN_ROLE) {
         slashedFundsRecipient = _recipient;
         emit SlashedFundsRecipientSet(_recipient);
     }
}