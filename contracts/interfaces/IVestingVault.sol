// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IVestingVault
 * @dev Interface for the EVM vesting vault contract synchronized with Soroban entrypoints.
 *
 * Run `scripts/sync-interfaces.sh --check` after changing Soroban
 * #[contractimpl] entrypoints or this Solidity interface. Known legacy EVM
 * drift must be documented with a custom sync-allow tag.
 */
interface IVestingVault {
    struct Grant {
        uint256 amount;
        uint256 start;
        uint256 duration;
        uint256 claimed;
        bool isActive;
        bool isEscrowed; // New field for frozen tokens
        uint256 escrowed_amount; // amount currently held in escrow for this grant
        // Tax configuration
        uint16 tax_bps; // basis points, parts per 10,000
        address tax_authority; // address receiving withheld tax
        address tax_asset; // if non-zero and different from vested token, tax portion will be liquidated to this asset
        uint256 cumulative_taxes_paid; // accumulated taxes paid (in tax_asset units when liquidated, otherwise token units)
        uint256 tax_rounding_accumulator; // accumulator for fractional tax parts to avoid losing stroops
    }

    /**
     * @dev Owner proposes a tax configuration change for a specific grant.
     * @custom:sync-allow evm-extension EVM two-step tax configuration proposal.
     */
    function proposeTaxConfig(address beneficiary, uint16 tax_bps, address tax_authority, address tax_asset) external;

    /**
     * @dev Tax admin confirms a previously proposed tax configuration change.
     * @custom:sync-allow evm-extension EVM two-step tax configuration confirmation.
     */
    function confirmTaxConfig(address beneficiary) external;

    /**
     * @dev Set the tax admin address.
     * @custom:sync-allow evm-extension EVM tax admin configuration.
     */
    function setTaxAdmin(address _taxAdmin) external;

    /**
     * @dev Set the DEX router address used for token liquidation.
     * @custom:sync-allow evm-extension EVM DEX router configuration.
     */
    function setDexRouter(address _dexRouter) external;

    /**
     * @dev Creates a new vesting grant.
     * @custom:sync-allow legacy-evm Maps to Soroban create_vesting_schedule.
     */
    function createGrant(
        address beneficiary,
        uint256 amount,
        uint256 start,
        uint256 duration,
        uint16 tax_bps,
        address tax_authority,
        address tax_asset
    ) external;

    /**
     * @dev Claims vested tokens for a beneficiary.
     * @param beneficiary The address claiming tokens.
     * @custom:sync-allow legacy-evm Soroban claim currently requires user, vesting_id, and amount.
     */
    function claim(address beneficiary) external;

    /**
     * @dev Gets the claimable amount for a beneficiary.
     * @param beneficiary The address to check.
     * @return The amount of tokens that can be claimed.
     * @custom:sync-allow legacy-evm No Soroban getter currently exposes this exact EVM vesting calculation.
     */
    function getClaimableAmount(address beneficiary) external view returns (uint256);

    /**
     * @dev Gets the grant details for a beneficiary.
     * @param beneficiary The address to check.
     * @return The grant details.
     * @custom:sync-allow legacy-evm Soroban uses get_vesting_grant_info keyed by vesting_id.
     */
    function getGrant(address beneficiary) external view returns (Grant memory);

    /**
     * @dev Updates the sanctions oracle address.
     * @custom:sync-allow evm-extension EVM sanctions oracle pointer update.
     */
    function updateSanctionsOracle(address newOracle) external;

    /**
     * @dev Updates the revenue oracle address.
     * @custom:sync-allow evm-extension EVM revenue oracle pointer update.
     */
    function updateRevenueOracle(address newOracle) external;

    /**
     * @dev Releases tokens from escrow if beneficiary is no longer sanctioned.
     * @custom:sync-allow evm-extension EVM sanctions escrow release entrypoint.
     */
    function releaseFromEscrow(address beneficiary) external;

    /**
     * @dev Emergency pause/unpause.
     * @custom:sync-allow legacy-evm Maps to Soroban set_emergency_pause.
     */
    function setPaused(bool _paused) external;

    /**
     * @dev Gets all beneficiaries (paginated).
     * @custom:sync-allow evm-extension EVM beneficiary pagination getter.
     */
    function getBeneficiaries(uint256 offset, uint256 limit) external view returns (address[] memory);

    /**
     * @dev Gets the total number of beneficiaries.
     * @custom:sync-allow evm-extension EVM beneficiary count getter.
     */
    function getBeneficiaryCount() external view returns (uint256);

    /**
     * @dev Updates the KPI multiplier and stores historical data.
     * @custom:sync-allow evm-extension EVM KPI multiplier oracle refresh.
     */
    function updateKPIMultiplier() external;

    /**
     * @dev Gets the current KPI multiplier.
     * @custom:sync-allow evm-extension EVM KPI multiplier getter.
     */
    function getCurrentKPIMultiplier() external view returns (uint256);

    /**
     * @dev Gets historical KPI metrics (paginated).
     * @custom:sync-allow evm-extension EVM KPI history getter.
     */
    function getKPIHistory(uint256 offset, uint256 limit) external view returns (
        uint256[] memory multipliers,
        uint256[] memory oracleInputs,
        uint256[] memory timestamps
    );

    /**
     * @dev Gets the number of KPI history entries.
     * @custom:sync-allow evm-extension EVM KPI history count getter.
     */
    function getKPIHistoryCount() external view returns (uint256);

    /**
     * @dev Batch check sanctions for multiple beneficiaries.
     * @custom:sync-allow evm-extension EVM sanctions batch check helper.
     */
    function batchCheckSanctions(address[] calldata beneficiaries) external view returns (bool[] memory);

    /**
     * @dev Gets the contract's token balance.
     * @custom:sync-allow evm-extension EVM vault token balance getter.
     */
    function getTokenBalance() external view returns (uint256);

    /**
     * @dev Gets the total amount of tokens available for claims (excluding escrow).
     * @custom:sync-allow evm-extension EVM available balance getter.
     */
    function getAvailableAmount() external view returns (uint256);

    /**
     * @dev Emitted when tokens are claimed.
     */
    event TokensClaimed(address indexed beneficiary, uint256 amount);

    /**
     * @dev Emitted when tokens are frozen due to sanctions.
     */
    event TokensFrozen(address indexed beneficiary, uint256 amount);

    /**
     * @dev Emitted when tokens are released from escrow.
     */
    event TokensReleased(address indexed beneficiary, uint256 amount);

    /**
     * @dev Emitted when tax is withheld from a claim and sent to authority.
     */
    event TaxWithheld(address indexed beneficiary, uint256 gross, uint256 taxAmount, uint256 net);

    /**
     * @dev Emitted when the KPI vesting multiplier changes.
     */
    event KPIMultiplierUpdated(uint256 oldMultiplier, uint256 oracleInput, uint256 newMultiplier, uint256 timestamp);
}
