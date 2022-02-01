// SPDX-License-Identifier: Apache-2.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract CupDAOLiquidityStaking is Ownable {

    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of CUP
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCupPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCupPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. CUP to distribute per block.
        uint256 lastRewardBlock;  // Last block number that CUP distribution occurs.
        uint256 accCupPerShare; // Accumulated CUP per share, times 1e12. See below.
        uint256 totalStaked;      // Total amount of LP token staked in pool.
    }

    IERC20 public CUP;          // cupDAO token
    uint256 public cupPerBlock; // Amount of CUP distributed per block between all pools

    PoolInfo[] public poolInfo;                                         // Info of each pool
    mapping (uint256 => mapping (address => UserInfo)) public userInfo; // Info of each user by pool ID

    uint256 public totalAllocPoint = 0; // Total allocation points for all pools
    uint256 public startBlock;          // Block rewards start

    // Events

    event CupPerBlockChanged(uint256 cupPerBlock);

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    // Check token is not already added in a pool

    modifier nonDuplicate(IERC20 token) {
        for (uint256 p = 0; p < poolInfo.length; p ++) {
            require(token != poolInfo[p].lpToken);
        }
        _;
    }

    // Initialize liquidity staking data

    constructor(address cup, uint256 start) {
        CUP = IERC20(cup);
        cupPerBlock = 1 ether; // 1 CUP distributed per block
        startBlock = start;      // Rewards start
    }

    // Return number of pools

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add new staking reward pool

    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) external onlyOwner nonDuplicate(_lpToken) {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accCupPerShare: 0,
            totalStaked: 0
        }));
    }

    // Update CUP allocation points of a pool

    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Update CUP distribution rate per block

    function setCupPerBlock(uint256 ratePerBlock) external onlyOwner {
        massUpdatePools();
        cupPerBlock = ratePerBlock;
        emit CupPerBlockChanged(cupPerBlock);
    }

    // Calculate reward multiplier between blocks

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to - _from;
    }

    // Calculate pending CUP reward for a user on a pool

    function pendingCup(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accCupPerShare = pool.accCupPerShare;
        uint256 lpSupply = pool.totalStaked;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 cupReward = multiplier * cupPerBlock * pool.allocPoint / totalAllocPoint;
            accCupPerShare += cupReward * 1e12 / lpSupply;
        }

        return user.amount * accCupPerShare / 1e12 - user.rewardDebt;
    }

    // Update reward data on all pools

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; pid ++) {
            updatePool(pid);
        }
    }

    // Update reward data of a pool

    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) return;

        uint256 lpSupply = pool.totalStaked;
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 cupReward = multiplier * cupPerBlock * pool.allocPoint / totalAllocPoint;
        pool.accCupPerShare += cupReward * 1e12 / lpSupply;
        pool.lastRewardBlock = block.number;
    }

    // Deposit tokens for CUP distribution

    function deposit(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = user.amount * pool.accCupPerShare / 1e12 - user.rewardDebt;
            if (pending > 0) {
                safeCupTransfer(_msgSender(), pending);
            }
        }

        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(_msgSender()), address(this), _amount);
            user.amount += _amount;
        }

        user.rewardDebt = user.amount * pool.accCupPerShare / 1e12;
        emit Deposit(_msgSender(), _pid, _amount);
    }

    // Withdraw tokens from staking

    function withdraw(uint256 _pid, uint256 _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        require(user.amount >= _amount, "CupDAOLiquidityStaking: insufficient balance for withdraw");
        updatePool(_pid);

        uint256 pending = user.amount * pool.accCupPerShare / 1e12 - user.rewardDebt;
        if (pending > 0) {
            safeCupTransfer(_msgSender(), pending);
        }

        if (_amount > 0) {
            user.amount -= _amount;
            pool.lpToken.safeTransfer(address(_msgSender()), _amount);
        }

        user.rewardDebt = user.amount * pool.accCupPerShare / 1e12;
        emit Withdraw(_msgSender(), _pid, _amount);
    }

    // Withdraw ignoring CUP rewards

    function emergencyWithdraw(uint256 _pid) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(_msgSender()), amount);

        emit EmergencyWithdraw(_msgSender(), _pid, amount);
    }

    // Safe CUP transfer

    function safeCupTransfer(address _to, uint256 _amount) internal {
        uint256 cupBal = CUP.balanceOf(address(this));
        if (_amount > cupBal) {
            CUP.transfer(_to, cupBal);
        } else {
            CUP.transfer(_to, _amount);
        }
    }

}
