pragma solidity ^0.7.0;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "./libraries/NativeMetaTransaction.sol";
import "./libraries/ContextMixin.sol";
import "./IPair.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IRewardManager {
    function handleRewardsForUser(
        address user,
        uint256 rewardAmount,
        uint256 timestamp,
        uint256 pid,
        uint256 rewardDebt
    ) external;
}

// Farm is the major distributor of CNT to the community. He gives juicy CNT rewards as per user's stake.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once CNT is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract Farm is Ownable, ContextMixin, NativeMetaTransaction, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp; // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        //
        // We do some fancy math here. Basically, any point in time, the amount of CNTs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accCNTPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accCNTPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. CNTs to distribute per block.
        uint256 lastRewardBlock; // Last block number that CNTs distribution occurs.
        uint256 accCNTPerShare; // Accumulated CNTs per share, times 1e12. See below.
        uint16 withdrawalFeeBP; // Deposit fee in basis points
        uint256 harvestInterval; // Harvest interval in seconds
    }

    // The CNT TOKEN!
    IERC20 public cnt;
    // Block number when bonus CNT period ends.
    uint256 public bonusEndBlock;
    // CNT tokens created per block.
    uint256 public cntPerBlock;
    // Deposit Fee address
    address public feeAddress;
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;
    // Max deposit fee: 10%.
    uint16 public constant MAXIMUM_WITHDRAWAL_FEE_BP = 1000;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;
    // Bonus muliplier for early cnt makers.
    uint256 public BONUS_MULTIPLIER = 1;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    mapping(address => mapping(address => bool)) public whiteListedHandlers;

    mapping(address => bool) public activeLpTokens;

    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when CNT mining starts.
    uint256 public startBlock;

    //Trigger for RewardManager mode
    bool public isRewardManagerEnabled;

    address public rewardManager;

    event PoolAddition(
        uint256 indexed pid,
        uint256 allocPoint,
        IERC20 indexed lpToken,
        uint16 withdrawalFeeBP,
        uint256 harvestInterval
    );
    event UpdatedPoolAlloc(
        uint256 indexed pid,
        uint256 allocPoint,
        uint16 withdrawalFeeBP,
        uint256 harvestInterval
    );
    event PoolUpdated(
        uint256 indexed pid,
        uint256 lastRewardBlock,
        uint256 lpSupply,
        uint256 accCNTPerShare
    );
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event SetFeeAddress(address indexed user, address indexed _devAddress);
    event RewardLockedUp(
        address indexed user,
        uint256 indexed pid,
        uint256 amountLockedUp
    );
    event BonusMultiplierUpdated(uint256 _bonusMultiplier);
    event BlockRateUpdated(uint256 _blockRate);
    event UserWhitelisted(address _primaryUser, address _whitelistedUser);
    event UserBlacklisted(address _primaryUser, address _blacklistedUser);

    constructor(
        IERC20 _cnt,
        uint256 _cntPerBlock,
        address _feeAddress,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) {
        _initializeEIP712("Farm");
        cnt = _cnt;
        cntPerBlock = _cntPerBlock;
        feeAddress = _feeAddress;
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
        isRewardManagerEnabled = false;
        rewardManager = address(0);
    }

    modifier validatePoolByPid(uint256 _pid) {
        require(_pid < poolInfo.length, "Pool does not exist");
        _;
    }

    function _msgSender()
        internal
        view
        override
        returns (address payable sender)
    {
        return ContextMixin.msgSender();
    }

    function updateBonusMultiplier(uint256 multiplierNumber)
        external
        onlyOwner
    {
        massUpdatePools();
        BONUS_MULTIPLIER = multiplierNumber;
        emit BonusMultiplierUpdated(BONUS_MULTIPLIER);
    }

    function updateBlockRate(uint256 _cntPerBlock) external onlyOwner {
        massUpdatePools();
        cntPerBlock = _cntPerBlock;
        emit BlockRateUpdated(cntPerBlock);
    }

    function updateRewardManagerMode(bool _isRewardManagerEnabled)
        external
        onlyOwner
    {
        massUpdatePools();
        isRewardManagerEnabled = _isRewardManagerEnabled;
    }

    function updateRewardManager(address _rewardManager) external onlyOwner {
        require(_rewardManager != address(0), "Reward Manager address is zero");
        massUpdatePools();
        rewardManager = _rewardManager;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        uint16 _withdrawalFeeBP,
        uint256 _harvestInterval,
        bool _withUpdate
    ) external onlyOwner nonReentrant {
        require(
            _withdrawalFeeBP <= MAXIMUM_WITHDRAWAL_FEE_BP,
            "add: invalid deposit fee basis points"
        );
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "add: invalid harvest interval"
        );
        require(
            activeLpTokens[address(_lpToken)] == false,
            "Reward Token already added"
        );

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accCNTPerShare: 0,
                withdrawalFeeBP: _withdrawalFeeBP,
                harvestInterval: _harvestInterval
            })
        );

        activeLpTokens[address(_lpToken)] = true;

        emit PoolAddition(
            poolInfo.length.sub(1),
            _allocPoint,
            _lpToken,
            _withdrawalFeeBP,
            _harvestInterval
        );
    }

    // Update the given pool's CNT allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        uint16 _withdrawalFeeBP,
        uint256 _harvestInterval,
        bool _withUpdate
    ) external onlyOwner validatePoolByPid(_pid) nonReentrant {
        require(
            _withdrawalFeeBP <= MAXIMUM_WITHDRAWAL_FEE_BP,
            "set: invalid deposit fee basis points"
        );
        require(
            _harvestInterval <= MAXIMUM_HARVEST_INTERVAL,
            "add: invalid harvest interval"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].withdrawalFeeBP = _withdrawalFeeBP;
        poolInfo[_pid].harvestInterval = _harvestInterval;

        emit UpdatedPoolAlloc(
            _pid,
            _allocPoint,
            _withdrawalFeeBP,
            _harvestInterval
        );
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending CNTs on frontend.
    function pendingCNT(uint256 _pid, address _user)
        external
        view
        validatePoolByPid(_pid)
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accCNTPerShare = pool.accCNTPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                block.number
            );
            uint256 cntReward = multiplier
                .mul(cntPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accCNTPerShare = accCNTPerShare.add(
                cntReward.mul(1e12).div(lpSupply)
            );
        }
        uint256 pending = user.amount.mul(accCNTPerShare).div(1e12).sub(
            user.rewardDebt
        );
        return pending.add(user.rewardLockedUp);
    }

    // View function to see if user can harvest cnt's.
    function canHarvest(uint256 _pid, address _user)
        public
        view
        validatePoolByPid(_pid)
        returns (bool)
    {
        UserInfo memory user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // View function to see if user harvest until time.
    function getHarvestUntil(uint256 _pid, address _user)
        external
        view
        validatePoolByPid(_pid)
        returns (uint256)
    {
        UserInfo memory user = userInfo[_pid][_user];
        return user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public validatePoolByPid(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 cntReward = multiplier
            .mul(cntPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
        pool.accCNTPerShare = pool.accCNTPerShare.add(
            cntReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
        emit PoolUpdated(
            _pid,
            pool.lastRewardBlock,
            lpSupply,
            pool.accCNTPerShare
        );
    }

    function depositWithPermit(
        uint256 _pid,
        uint256 _amount,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 value = uint256(-1);
        IPolydexPair(address(pool.lpToken)).permit(
            _msgSender(),
            address(this),
            value,
            _deadline,
            _v,
            _r,
            _s
        );
        _deposit(_pid, _amount, _msgSender());
    }

    function depositForWithPermit(
        uint256 _pid,
        uint256 _amount,
        address _user,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 value = uint256(-1);
        IPolydexPair(address(pool.lpToken)).permit(
            _msgSender(),
            address(this),
            value,
            _deadline,
            _v,
            _r,
            _s
        );
        _deposit(_pid, _amount, _user);
    }

    // Deposit LP tokens to Farm for CNT allocation.
    function deposit(uint256 _pid, uint256 _amount)
        external
        validatePoolByPid(_pid)
        nonReentrant
    {
        _deposit(_pid, _amount, _msgSender());
    }

    // Deposit LP tokens to Farm for CNT allocation.
    function depositFor(
        uint256 _pid,
        uint256 _amount,
        address _user
    ) external validatePoolByPid(_pid) nonReentrant {
        _deposit(_pid, _amount, _user);
    }

    function _deposit(
        uint256 _pid,
        uint256 _amount,
        address _user
    ) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        whiteListedHandlers[_user][_user] = true;

        updatePool(_pid);
        payOrLockupPendingcnt(_pid, _user, _user);

        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(
                address(_msgSender()),
                address(this),
                _amount
            );
            user.amount = user.amount.add(_amount);
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }
        user.rewardDebt = user.amount.mul(pool.accCNTPerShare).div(1e12);
        emit Deposit(_user, _pid, _amount);
    }

    // Withdraw LP tokens from Farm.
    function withdraw(uint256 _pid, uint256 _amount)
        external
        validatePoolByPid(_pid)
        nonReentrant
    {
        _withdraw(_pid, _amount, _msgSender(), _msgSender());
    }

    // Withdraw LP tokens from Farm.
    function withdrawFor(
        uint256 _pid,
        uint256 _amount,
        address _user
    ) external validatePoolByPid(_pid) nonReentrant {
        require(whiteListedHandlers[_user][_msgSender()], "not whitelisted");
        _withdraw(_pid, _amount, _user, _msgSender());
    }

    function _withdraw(
        uint256 _pid,
        uint256 _amount,
        address _user,
        address _withdrawer
    ) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        payOrLockupPendingcnt(_pid, _user, _withdrawer);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            if (pool.withdrawalFeeBP > 0) {
                uint256 withdrawalFee = _amount.mul(pool.withdrawalFeeBP).div(
                    10000
                );
                pool.lpToken.safeTransfer(feeAddress, withdrawalFee);
                pool.lpToken.safeTransfer(
                    address(_withdrawer),
                    _amount.sub(withdrawalFee)
                );
            } else {
                pool.lpToken.safeTransfer(address(_withdrawer), _amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accCNTPerShare).div(1e12);
        emit Withdraw(_user, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid)
        external
        validatePoolByPid(_pid)
        nonReentrant
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_msgSender()];
        pool.lpToken.safeTransfer(address(_msgSender()), user.amount);
        emit EmergencyWithdraw(_msgSender(), _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
    }

    function addUserToWhiteList(address _user) external {
        whiteListedHandlers[_msgSender()][_user] = true;
        emit UserWhitelisted(_msgSender(), _user);
    }

    function removeUserFromWhiteList(address _user) external {
        whiteListedHandlers[_msgSender()][_user] = false;
        emit UserBlacklisted(_msgSender(), _user);
    }

    function isUserWhiteListed(address _owner, address _user)
        external
        view
        returns (bool)
    {
        return whiteListedHandlers[_owner][_user];
    }

    // Pay or lockup pending cnt.
    function payOrLockupPendingcnt(
        uint256 _pid,
        address _user,
        address _withdrawer
    ) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accCNTPerShare).div(1e12).sub(
            user.rewardDebt
        );
        if (canHarvest(_pid, _user)) {
            if (pending > 0 || user.rewardLockedUp > 0) {
                uint256 totalRewards = pending.add(user.rewardLockedUp);

                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(
                    user.rewardLockedUp
                );
                user.rewardLockedUp = 0;
                user.nextHarvestUntil = block.timestamp.add(
                    pool.harvestInterval
                );

                // send rewards
                if (isRewardManagerEnabled == true) {
                    safeCNTTransfer(rewardManager, totalRewards);
                    IRewardManager(rewardManager).handleRewardsForUser(
                        _withdrawer,
                        totalRewards,
                        block.timestamp,
                        _pid,
                        user.rewardDebt
                    );
                } else {
                    safeCNTTransfer(_withdrawer, totalRewards);
                }
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(_user, _pid, pending);
        }
    }

    // Update fee address by the previous fee address.
    function setFeeAddress(address _feeAddress) external onlyOwner {
        require(_feeAddress != address(0), "setFeeAddress: invalid address");
        feeAddress = _feeAddress;
        emit SetFeeAddress(_msgSender(), _feeAddress);
    }

    function withdrawCNT(uint256 _amount) external onlyOwner {
        cnt.transfer(msg.sender, _amount);
    }

    // Safe cnt transfer function, just in case if rounding error causes pool to not have enough CNTs.
    function safeCNTTransfer(address _to, uint256 _amount) internal {
        uint256 cntBal = cnt.balanceOf(address(this));
        if (_amount > cntBal) {
            cnt.transfer(_to, cntBal);
        } else {
            cnt.transfer(_to, _amount);
        }
    }
}
