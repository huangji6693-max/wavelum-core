// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../../interfaces/IRevenueOracle.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RevenueOracle
 * @dev Revenue oracle with 30-day TWAP protection against flash loan manipulation
 */
contract RevenueOracle is IRevenueOracle, Ownable {
    // Current revenue value
    uint256 public currentRevenue;
    
    // Target revenue for KPI comparison
    uint256 public targetRevenue;
    
    // TWAP window: 30 days in seconds
    uint256 public constant TWAP_WINDOW = 30 days;
    
    // Maximum number of data points to store (30 days + buffer)
    uint256 public constant MAX_DATA_POINTS = 35;
    
    // Revenue data points for TWAP calculation
    struct DataPoint {
        uint256 value;
        uint256 timestamp;
    }
    
    DataPoint[] public revenueHistory;
    
    // Last update timestamp
    uint256 public lastUpdateTimestamp;
    
    // Minimum time between updates (1 hour to prevent spam)
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours;
    
    // Oracle health flag
    bool public oracleHealthy = true;
    
    // Keeper address authorized to update revenue
    address public keeper;
    
    /**
     * @dev Constructor
     * @param initialRevenue Initial revenue value
     * @param _targetRevenue Target revenue for KPI comparison
     * @param initialOwner Initial owner of the contract
     * @param _keeper Address authorized to update revenue
     */
    constructor(
        uint256 initialRevenue,
        uint256 _targetRevenue,
        address initialOwner,
        address _keeper
    ) Ownable() {
        require(initialRevenue > 0, "Initial revenue must be positive");
        require(_targetRevenue > 0, "Target revenue must be positive");
        require(_keeper != address(0), "Invalid keeper address");
        
        currentRevenue = initialRevenue;
        targetRevenue = _targetRevenue;
        keeper = _keeper;
        lastUpdateTimestamp = 0;
        
        // Seed baseline data points across the 30-day TWAP window
        for (uint256 i = 0; i < 12; i++) {
            revenueHistory.push(DataPoint({
                value: initialRevenue,
                timestamp: block.timestamp
            }));
        }
        
        transferOwnership(initialOwner);
    }
    
    /**
     * @dev Gets the current revenue metric
     * @return revenue The current revenue value
     */
    function getCurrentRevenue() external view override returns (uint256) {
        return currentRevenue;
    }
    
    /**
     * @dev Gets the 30-day TWAP of revenue
     * @return twapRevenue The 30-day average revenue
     */
    function get30DayTWAP() public view override returns (uint256) {
        uint256 cutoffTime = block.timestamp - TWAP_WINDOW;
        uint256 totalValue = 0;
        uint256 count = 0;
        
        // Calculate weighted average from data points within window
        for (uint256 i = 0; i < revenueHistory.length; i++) {
            if (revenueHistory[i].timestamp >= cutoffTime) {
                totalValue += revenueHistory[i].value;
                count++;
            }
        }
        
        // If no data points in window, return current revenue
        if (count == 0) {
            return currentRevenue;
        }
        
        return totalValue / count;
    }
    
    /**
     * @dev Gets the target revenue for KPI comparison
     * @return targetRevenue The target revenue value
     */
    function getTargetRevenue() external view override returns (uint256) {
        return targetRevenue;
    }
    
    /**
     * @dev Checks if the oracle is functioning properly
     * @return isHealthy True if oracle is responding correctly
     */
    function isOracleHealthy() external view override returns (bool) {
        // Check if data was updated recently (within 7 days) or not yet updated since deployment
        bool recentUpdate = lastUpdateTimestamp == 0 || (block.timestamp - lastUpdateTimestamp) < 7 days;
        return oracleHealthy && recentUpdate;
    }
    
    /**
     * @dev Updates the revenue data (called by oracle keeper)
     * @param newRevenue The new revenue value
     */
    function updateRevenue(uint256 newRevenue) external override {
        require(msg.sender == keeper || msg.sender == owner(), "Unauthorized");
        require(newRevenue > 0, "Revenue must be positive");
        require(
            block.timestamp - lastUpdateTimestamp >= MIN_UPDATE_INTERVAL,
            "Update too frequent"
        );
        
        uint256 oldRevenue = currentRevenue;
        currentRevenue = newRevenue;
        lastUpdateTimestamp = block.timestamp;
        
        // Add new data point
        revenueHistory.push(DataPoint({
            value: newRevenue,
            timestamp: block.timestamp
        }));
        
        // Prune old data points beyond MAX_DATA_POINTS
        while (revenueHistory.length > MAX_DATA_POINTS) {
            // Remove oldest data point (shift array)
            for (uint256 i = 0; i < revenueHistory.length - 1; i++) {
                revenueHistory[i] = revenueHistory[i + 1];
            }
            revenueHistory.pop();
        }
        
        // Mark oracle as healthy if update succeeds
        oracleHealthy = true;
        
        emit RevenueUpdated(oldRevenue, newRevenue, block.timestamp);
    }
    
    /**
     * @dev Updates the target revenue (owner only)
     * @param newTarget New target revenue
     */
    function setTargetRevenue(uint256 newTarget) external onlyOwner {
        require(newTarget > 0, "Target must be positive");
        targetRevenue = newTarget;
    }
    
    /**
     * @dev Updates the keeper address (owner only)
     * @param newKeeper New keeper address
     */
    function setKeeper(address newKeeper) external onlyOwner {
        require(newKeeper != address(0), "Invalid keeper address");
        keeper = newKeeper;
    }
    
    /**
     * @dev Marks oracle as unhealthy (emergency)
     */
    function markUnhealthy() external {
        require(msg.sender == keeper || msg.sender == owner(), "Unauthorized");
        oracleHealthy = false;
    }
    
    /**
     * @dev Gets the number of data points in history
     * @return count The number of data points
     */
    function getHistoryCount() external view returns (uint256) {
        return revenueHistory.length;
    }
    
    /**
     * @dev Gets historical data points (paginated)
     * @param offset Starting index
     * @param limit Maximum number of data points to return
     * @return values Array of revenue values
     * @return timestamps Array of timestamps
     */
    function getHistory(uint256 offset, uint256 limit) external view returns (
        uint256[] memory values,
        uint256[] memory timestamps
    ) {
        uint256 end = offset + limit;
        if (end > revenueHistory.length) {
            end = revenueHistory.length;
        }
        
        uint256[] memory valuesArray = new uint256[](end - offset);
        uint256[] memory timestampsArray = new uint256[](end - offset);
        
        for (uint256 i = offset; i < end; i++) {
            valuesArray[i - offset] = revenueHistory[i].value;
            timestampsArray[i - offset] = revenueHistory[i].timestamp;
        }
        
        return (valuesArray, timestampsArray);
    }
}
