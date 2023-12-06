// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../PPAgentV2Interfaces.sol";

/**
 * @title KeeperInfoArrayStorage Contract
 * @dev This contract is designed to manage the information of keepers.
 */

contract KeeperInfoArrayStorage is Ownable {
    struct StakeRangeInfo {
        uint256 minStakeInGroup;
        uint256 maxStakeInGroup;
        uint256 maxElementsInGroup;
    }

    IPPAgentV2Viewer public powerAgentV2Randao;
    mapping(uint256 => StakeRangeInfo) public stakeRangeInfos;
    uint256[][] public keeperGroups;
    mapping(uint256 => uint256) public keeperIdToGroupId;
    mapping(uint256 => bool) public minStakeForJobAvailable;

    event StakeRangeInfoSet(uint256 indexed index, uint256 minStakeInGroup, uint256 maxStakeInGroup, uint256 maxElementsInGroup);
    event JobAvailabilityChanged(uint256 indexed minStake, bool availability);
    event KeeperAddedToGroup(uint256 indexed groupId, uint256 indexed keeperId);
    event KeeperStakeChanged(uint256 indexed keeperId, uint256 newStake);
    event KeeperRemoved(uint256 indexed groupId, uint256 indexed keeperId);
    event NoSuitableGroupFound(uint256 indexed keeperId, uint256 stake);
    event KeeperNotAdded(uint256 indexed keeperId, uint256 indexed newGroupId);

    /**
     * @dev Constructor sets the initial PowerAgentV2Randao contract address.
     * @param powerAgentV2Randao_ Address of the PowerAgentV2Randao contract.
     */
    constructor(address powerAgentV2Randao_) {
        powerAgentV2Randao = IPPAgentV2Viewer(powerAgentV2Randao_);
    }

    /*** MODIFIERS ***/

    /**
     * @dev Modifier that ensures only the PowerAgent can call the function.
     */
    modifier onlyAgent() {
        require(msg.sender == address(powerAgentV2Randao), "Caller is not the Agent");
        _;
    }

    /*** OWNER METHODS ***/

    /**
     * @dev Set the PowerAgentV2Randao contract address.
     * @param randaoAddress_ Address of the new PowerAgentV2Randao contract.
     */
    function setPowerAgentV2RandaoAddress(address randaoAddress_) external onlyOwner {
        powerAgentV2Randao = IPPAgentV2Viewer(randaoAddress_);
    }

    /**
     * @notice Set or modify a stake range for keepers.
     * @dev Can only add new intervals or modify the last existing interval.
     * @param index_ Index of the interval to set or modify.
     * @param maxStakeInGroup_ Maximum stake for the interval.
     * @param maxElementsInGroup_ Maximum number of elements in the interval.
     */
    function setStakeRangeInfo(
        uint256 index_,
        uint256 maxStakeInGroup_,
        uint256 maxElementsInGroup_
    ) public onlyOwner {
        require(maxElementsInGroup_ > 0, "maxElementsInGroup must be greater than 0");

        uint256 minStakeInGroup_ = 0;
        if (index_ > 0) {
            minStakeInGroup_ = stakeRangeInfos[index_ - 1].maxStakeInGroup;
        }

        require(
            index_ == 0 || stakeRangeInfos[index_ - 1].minStakeInGroup > 0,
            "!index"
        );

        require(stakeRangeInfos[index_ + 1].minStakeInGroup == 0, "Can only modify the last interval");

        StakeRangeInfo memory newRange = StakeRangeInfo(minStakeInGroup_, maxStakeInGroup_, maxElementsInGroup_);
        stakeRangeInfos[index_] = newRange;

        if (keeperGroups.length <= index_) {
            keeperGroups.push();
        }

        emit StakeRangeInfoSet(index_, minStakeInGroup_, maxStakeInGroup_, maxElementsInGroup_);
    }


    /**
     * @dev Set multiple stake range information entries based on a specified step size.
     * This function is useful when you want to set multiple continuous stake ranges with a consistent difference.
     *
     * @param rangeStep_ The difference between each subsequent range's min and max stakes.
     * @param maxStakeInGroup_ The maximum stake in the final group of this set.
     * @param maxElementsInGroup_ Maximum elements allowed in each group.
     *
     * Requirements:
     * - `rangeStep_` should be greater than 0.
     * - `maxElementsInGroup_` should be greater than 0.
     * - The new `maxStakeInGroup_` should be greater than the current max stake.
     */
    function setRangeInfoMultiple(
        uint256 rangeStep_,
        uint256 maxStakeInGroup_,
        uint256 maxElementsInGroup_
    ) public onlyOwner {
        require(rangeStep_ > 0, "Range step should be greater than 0");
        require(maxElementsInGroup_ > 0, "Max elements in group should be greater than 0");

        uint256 currentMaxStake = 0;
        if (keeperGroups.length > 0) {
            currentMaxStake = stakeRangeInfos[keeperGroups.length - 1].maxStakeInGroup;
        }

        require(maxStakeInGroup_ > currentMaxStake, "Max stake should be greater than the current max stake");

        uint256 rangeCount = (maxStakeInGroup_ - currentMaxStake) / rangeStep_;
        require(rangeCount > 0, "At least one range should be added");

        for (uint256 i = 0; i < rangeCount; i++) {
            currentMaxStake += rangeStep_;
            uint256 currentMinStake = currentMaxStake - rangeStep_;

            StakeRangeInfo memory newRange = StakeRangeInfo(currentMinStake, currentMaxStake, maxElementsInGroup_);
            stakeRangeInfos[keeperGroups.length] = newRange;

            keeperGroups.push();
            minStakeForJobAvailable[currentMinStake] = true;

            emit StakeRangeInfoSet(keeperGroups.length - 1, currentMinStake, currentMaxStake, maxElementsInGroup_);
        }
    }


    /**
     * @dev Sets the availability for a specific minimum CVP stake to be used as a requirement for jobs.
     * This function allows the owner to specify which minimum CVP stake values are valid for jobs. If a value is set to `true`,
     * jobs can be created or updated with this minimum stake requirement. Otherwise, such jobs cannot use this specific stake value.
     *
     * @param minStake_ The minimum CVP stake value to set the availability for.
     * @param available_ Whether this `minStake_` value can be used as a stake requirement for jobs. If `true`, it's allowed; otherwise, it's not.
     *
     * Requirements:
     * - The `minStake_` value should already exist.
     */
    function setMinJobCvpStakeAvailable(uint256 minStake_, bool available_) public onlyOwner {
        require(minStakeForJobAvailable[minStake_], "Given minimum stake doesn't exist");
        minStakeForJobAvailable[minStake_] = available_;
        emit JobAvailabilityChanged(minStake_, available_);
    }


    /*** AGENT INTERFACE ***/


    /**
     * @dev Adds a keeper to a specified group, ensuring that the keeper is placed in the correct position based on their stake.
     * The function is designed to maintain the sorted order of keepers within a group based on their active stakes.
     * Keepers with higher stakes will be positioned towards the end of the group array.
     *
     * @param index_ The index of the group where the keeper should be added.
     * @param keeperId_ The ID of the keeper to be added to the group.
     *
     * Requirements:
     * - The caller must be the PowerAgentV2Randao contract (agent).
     * - The maximum allowed elements in the group should not be reached.
     * - The keeper should not already belong to another group.
     */

    function addKeeperToGroupSorted(uint256 index_, uint256 keeperId_) external onlyAgent {
        _addKeeperToGroupSorted(index_,keeperId_);
    }


    /**
     * @dev Removes a keeper from their current group and ensures that the group remains sorted.
     * After removing the keeper, the function ensures that the order of keepers in the group remains consistent based on their stakes.
     *
     * @param keeperId_ The ID of the keeper to be removed.
     *
     * Requirements:
     * - The caller must be the PowerAgentV2Randao contract (agent).
     * - The keeper should belong to a group before removal.
     */
    function removeKeeperAndSort(uint256 keeperId_) external onlyAgent {
        uint256 groupId_ = keeperIdToGroupId[keeperId_];
        require(groupId_ != 0, "Keeper not found in any group");

        _removeKeeperFromGroup(keeperId_, groupId_);

        delete keeperIdToGroupId[keeperId_];
        emit KeeperRemoved(groupId_, keeperId_);
    }


    /**
     * @dev Handles changes in the stake of a given keeper.
     * If the new stake is still within the range of the keeper's current group, the position of the keeper in that group might be updated to keep the group sorted.
     * If the new stake moves the keeper out of the range of their current group, the keeper will be removed from that group and potentially added to another group that matches their new stake.
     * If no group can accommodate the keeper due to the group's max elements restriction, the keeper is not added back to any group.
     *
     * @param keeperId_ The ID of the keeper whose stake has changed.
     * @return The keeper ID if the keeper has been successfully re-positioned or added to a new group, 0 otherwise.
     *
     * Requirements:
     * - The caller must be the PowerAgentV2Randao contract (agent).
     * - The keeper should belong to a group.
     */
    function handleKeeperStakeChange(uint256 keeperId_) external onlyAgent returns (uint256) {
        uint256 groupId = keeperIdToGroupId[keeperId_];
        require(groupId != 0, "Keeper must be in a group");

        uint256 newStake = _getActiveKeeper(keeperId_);
        StakeRangeInfo memory rangeInfo = stakeRangeInfos[groupId];

        if (newStake >= rangeInfo.minStakeInGroup && newStake <= rangeInfo.maxStakeInGroup) {
            _updateKeeperPositionInGroup(keeperId_, groupId, newStake);
            emit KeeperStakeChanged(keeperId_, newStake);
            return keeperId_;
        } else {
            _removeKeeperFromGroup(keeperId_, groupId);
            delete keeperIdToGroupId[keeperId_];

            uint256 newGroupId = _findNewGroup(newStake,keeperId_);
            if (stakeRangeInfos[newGroupId].maxElementsInGroup > keeperGroups[newGroupId].length) {
                _addKeeperToGroupSorted(newGroupId, keeperId_);
                emit KeeperStakeChanged(keeperId_, newStake);
                return keeperId_;
            }
            else {
                emit KeeperNotAdded(keeperId_, newGroupId);
                return 0;
            }
        }
    }


    /**
     * @dev Selects the next suitable keeper for a given job based on a pseudo-random number and the job's requirements.
     * This function first determines the minimum required stake for the job, then finds a suitable group of keepers with stakes above that minimum.
     * From that group, a keeper is pseudo-randomly selected.
     *
     * @param jobKey_ The key identifying the job for which a keeper needs to be selected.
     * @return The ID of the selected keeper.
     *
     * Requirements:
     * - The caller must be the PowerAgentV2Randao contract.
     * - The selected keeper must meet the required stake conditions for the job.
     */
    function selectNextKeeper(bytes32 jobKey_) external view onlyAgent returns (uint256) {
        uint256 pseudoRandom = _getPseudoRandom();
        (uint256 minKeeperCvp,,,,) = powerAgentV2Randao.getConfig();
        (,,uint256 jobMinKeeperCvp,,,) = powerAgentV2Randao.getJob(jobKey_);

        uint256 requiredStake = jobMinKeeperCvp > 0 ? jobMinKeeperCvp : minKeeperCvp;

        uint256 startGroupIndex = _findFirstSuitableGroup(requiredStake);

        uint256 selectedGroupIndex = (pseudoRandom + uint256(jobKey_)) % (keeperGroups.length - startGroupIndex) + startGroupIndex;
        uint256[] storage selectedGroup = keeperGroups[selectedGroupIndex];

        uint256 selectedKeeperIndex = pseudoRandom % selectedGroup.length;
        uint256 selectedKeeperId = selectedGroup[selectedKeeperIndex];

        uint256 activeStake = _getActiveKeeper(selectedKeeperId);
        require(activeStake >= requiredStake, "Selected keeper does not meet the required stake");
        return selectedKeeperId;

    }

    /*** INTERNAL ***/

    /**
     * @dev Updates the position of a keeper within its group based on its new stake.
     * This function is intended to ensure that keepers within a group are sorted by their stake in descending order.
     * If a keeper's stake changes, it might need to be moved to a new position within its group.
     *
     * @param keeperId_ The ID of the keeper whose position needs to be updated.
     * @param groupId_ The ID of the group in which the keeper is currently positioned.
     * @param newStake_ The new stake amount of the keeper.
     *
     * Internal Notes:
     * - The function finds the current position of the keeper in its group, removes it from that position,
     *   and then inserts the keeper back into the group at its correct position based on the new stake.
     */
    function _updateKeeperPositionInGroup(uint256 keeperId_, uint256 groupId_, uint256 newStake_) internal {
        uint256[] storage group = keeperGroups[groupId_];

        for (uint256 i = 0; i < group.length; i++) {
            if (group[i] == keeperId_) {
                for (uint256 j = i; j < group.length - 1; j++) {
                    group[j] = group[j + 1];
                }
                group.pop();

                uint256 newPos = _findInsertPosition(groupId_, newStake_);
                group.push(0);
                for (uint256 j = group.length - 1; j > newPos; j--) {
                    group[j] = group[j - 1];
                }
                group[newPos] = keeperId_;

                break;
            }
        }
    }


    /**
     * @dev Determines the correct position to insert a keeper within a group based on its stake.
     * This is a binary search implementation that ensures keepers are sorted by their stake in descending order.
     *
     * @param index_ The ID of the group where the keeper is to be inserted.
     * @param newStake_ The stake of the keeper to be inserted.
     * @return The position where the keeper should be inserted to maintain the sorted order.
     *
     * Internal Notes:
     * - The function uses a binary search for efficient look-up in a sorted list.
     * - The function does not modify the state; it only computes the insert position.
     */
    function _findInsertPosition(uint256 index_, uint256 newStake_) internal view returns (uint256) {
        uint256[] storage arr = keeperGroups[index_];
        if (arr.length == 0) return 0;

        uint256 left = 0;
        uint256 right = arr.length - 1;

        while (left <= right) {
            uint256 mid = (left + right) / 2;
            uint256 midStake = _getActiveKeeper(arr[mid]);

            if (newStake_ < midStake) {
                right = mid - 1;
            } else {
                left = mid + 1;
            }
        }

        return left;
    }



    /**
     * @dev Identifies the most suitable group for a keeper based on its stake.
     * This function uses binary search to efficiently locate the group where the keeper's stake
     * falls within the defined stake range for that group.
     *
     * @param stake_ The amount of stake the keeper has.
     * @param keeperId_ The ID of the keeper for which the group is being found.
     * @return The ID of the group that matches the keeper's stake. If no suitable group is found, it returns 0.
     *
     * Internal Notes:
     * - The function uses binary search for efficient look-up in the sorted list of stake ranges.
     * - The function does not modify the state; it only identifies the group ID.
     * - If a suitable group is not found, an event `NoSuitableGroupFound` is emitted.
     */
    function _findNewGroup(uint256 stake_, uint256 keeperId_) internal  returns (uint256) {
        uint256 left = 0;
        uint256 right = keeperGroups.length - 1;

        while (left <= right) {
            uint256 mid = (left + right) / 2;
            StakeRangeInfo memory midRange = stakeRangeInfos[mid];

            if (stake_ >= midRange.minStakeInGroup && stake_ <= midRange.maxStakeInGroup) {
                return mid;
            } else if (stake_ < midRange.minStakeInGroup) {
                right = mid - 1;
            } else {
                left = mid + 1;
            }
        }
        emit NoSuitableGroupFound(keeperId_, stake_);
        return 0;
    }


    /**
     * @dev Retrieves the active stake of a specific keeper from the PowerAgentV2Randao contract.
     * It ensures that the keeper is active before returning its current stake.
     *
     * @param keeperId_ The ID of the keeper whose active stake needs to be fetched.
     * @return The amount of active stake the keeper has.
     *
     * Internal Notes:
     * - This function queries the PowerAgentV2Randao contract to get the keeper's data.
     * - It throws an exception if the keeper is not active.
     */
    function _getActiveKeeper(uint256 keeperId_) internal view returns (uint256) {
        (,,bool isActive, uint256 currentStake,,,,) = powerAgentV2Randao.getKeeper(keeperId_);
        require(isActive, "Keeper is not active");

        return currentStake;
    }


    /**
     * @dev Finds the first suitable group for a given minimum stake.
     * The function performs a binary search on the stake range groups to find the first group that can accommodate the given stake.
     *
     * @param minStake_ The minimum stake required for a group.
     * @return The index of the first group that matches the criteria. Throws if no suitable group is found.
     *
     * Internal Notes:
     * - This function performs a binary search on the stakeRangeInfos to find a group whose minimum stake is greater than or equal to the given stake.
     * - If a suitable group is not found, it throws an exception.
     */
    function _findFirstSuitableGroup(uint256 minStake_) internal view returns (uint256) {
        uint256 left = 0;
        uint256 right = keeperGroups.length - 1;
        uint256 maxStakeOfLastGroup = stakeRangeInfos[keeperGroups.length - 1].maxStakeInGroup;
        uint256 result = maxStakeOfLastGroup;

        while (left <= right) {
            uint256 mid = (left + right) / 2;
            if (stakeRangeInfos[mid].minStakeInGroup >= minStake_) {
                result = mid;
                right = mid - 1;
            } else {
                left = mid + 1;
            }
        }

        require(result != maxStakeOfLastGroup, "No suitable group found");
        return result;
    }

    /**
     * @dev Removes a keeper from a specified group.
     * The function iterates over the members of the group and removes the specified keeper, maintaining the order of the other members.
     *
     * @param keeperId_ The ID of the keeper to be removed.
     * @param groupId_ The ID of the group from which the keeper should be removed.
     *
     * Internal Notes:
     * - If the keeper is not found in the group, the function will not make any changes.
     * - The order of the other members in the group remains the same after the removal.
     */
    function _removeKeeperFromGroup(uint256 keeperId_, uint256 groupId_) internal {
        uint256[] storage group = keeperGroups[groupId_];
        uint256 length = group.length;

        for (uint256 i = 0; i < length; i++) {
            if (group[i] == keeperId_) {
                for (uint256 j = i; j < length - 1; j++) {
                    group[j] = group[j + 1];
                }
                group.pop();
                break;
            }
        }

    }

    /**
     * @dev Adds a keeper to a specified group while maintaining the order based on the keeper's stake.
     * The keeper is added in a position such that the group remains sorted in decreasing order of active stake.
     *
     * Requirements:
     * - The group must not have reached its maximum allowed elements.
     * - The keeper should not already be in a group.
     *
     * @param index_ The ID of the group where the keeper should be added.
     * @param keeperId_ The ID of the keeper to be added.
     *
     * Internal Notes:
     * - If the group is empty, the keeper is simply added.
     * - Otherwise, the function finds the appropriate position for the keeper to maintain the order and inserts the keeper at that position.
     * - The keeper's ID is then mapped to the group's ID for future reference.
     * - An event is emitted after the keeper is successfully added to the group.
     */
    function _addKeeperToGroupSorted(uint256 index_, uint256 keeperId_) internal {
        require(stakeRangeInfos[index_].minStakeInGroup > 0, "Group does not exist");
        require(stakeRangeInfos[index_].maxElementsInGroup > keeperGroups[index_].length, "Max elements reached");
        require(keeperIdToGroupId[keeperId_] == 0, "Keeper already in a group");

        uint256 newStake = _getActiveKeeper(keeperId_);
        uint256 pos = _findInsertPosition(index_, newStake);

        keeperGroups[index_].push(0);
        for (uint256 i = keeperGroups[index_].length - 1; i > pos; i--) {
            keeperGroups[index_][i] = keeperGroups[index_][i - 1];
        }

        keeperGroups[index_][pos] = keeperId_;
        keeperIdToGroupId[keeperId_] = index_;
        emit KeeperAddedToGroup(index_, keeperId_);
    }

    function _getPseudoRandom() internal view returns (uint256) {
        return block.prevrandao;
    }
}
