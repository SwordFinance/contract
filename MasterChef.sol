// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/ISwordReferral.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./SwordToken.sol";

// MasterChef is the master of Sword. He can make Sword and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once SWORD is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        //
        // We do some fancy math here. Basically, any point in time, the amount of SWORDs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSwordPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSwordPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. SWORDs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that SWORDs distribution occurs.
        uint256 accSwordPerShare;   // Accumulated SWORDs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The SWORD TOKEN!
    SwordToken public sword;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // SWORD tokens created per block.
    uint256 public swordPerBlock;
  // Initial emission rate: 1 SWORD per block.
    uint256 public constant INITIAL_EMISSION_RATE = 1000 finney;
    // Reduce emission every 12,000 blocks ~ 10 hours.
    uint256 public constant EMISSION_REDUCTION_PERIOD_BLOCKS = 12000;
    // Emission reduction rate per period in basis points: 12%.
    uint256 public constant EMISSION_REDUCTION_RATE_PER_PERIOD = 1200;
    // Last reduction period index
    uint256 public lastReductionPeriodIndex = 0;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when SWORD mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Sword referral contract address.
    ISwordReferral public swordReferral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 300;
    // Max referral commission rate: 5%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 500;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    constructor(
        SwordToken _sword,
        uint256 _startBlock
        ) public {

        sword = _sword;
        startBlock = _startBlock;
        swordPerBlock = INITIAL_EMISSION_RATE;
        if(block.number > startBlock){
        uint256 currentIndex = block.number.sub(startBlock).div(EMISSION_REDUCTION_PERIOD_BLOCKS);
        lastReductionPeriodIndex = currentIndex;}
        devAddress = msg.sender;
        feeAddress = msg.sender;

    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }


    mapping(IBEP20 => bool) public poolExistence;
    modifier nonDuplicated(IBEP20 _lpToken) {
        require(poolExistence[_lpToken] == false, "nonDuplicated: duplicated");
        _;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner nonDuplicated(_lpToken) {
        require(_depositFeeBP <= 500, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accSwordPerShare: 0,
            depositFeeBP: _depositFeeBP
            }));
    }

    // Update the given pool's SWORD allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 500, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from);
    }

    // View function to see pending SWORDS on frontend.
        function pendingSword(uint256 _pid, address _user) external view returns (uint256) {
            PoolInfo storage pool = poolInfo[_pid];
            UserInfo storage user = userInfo[_pid][_user];
            uint256 accSwordPerShare = pool.accSwordPerShare;
            uint256 lpSupply = pool.lpToken.balanceOf(address(this));
            if (block.number > pool.lastRewardBlock && lpSupply != 0) {
                uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
                uint256 swordReward = multiplier.mul(swordPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
                accSwordPerShare = accSwordPerShare.add(swordReward.mul(1e12).div(lpSupply));
            }
            uint256 pending = user.amount.mul(accSwordPerShare).div(1e12).sub(user.rewardDebt);
            return pending.add(user.rewardLockedUp);
        }



    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 swordReward = multiplier.mul(swordPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        sword.mint(devAddress, swordReward.div(10));
        sword.mint(address(this), swordReward);
        pool.accSwordPerShare = pool.accSwordPerShare.add(swordReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for SWORD allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);

        if (_amount > 0 && address(swordReferral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            swordReferral.recordReferral(msg.sender, _referrer);
        }

        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accSwordPerShare).div(1e12).sub(user.rewardDebt);
            if (pending > 0) {
                safeSwordTransfer(msg.sender, pending);
            }
        }

        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(sword)) {
                if(sword.isExcludedFromFees(msg.sender) == false){
                  // MC has reducedtransferTaxRate by default
                  uint256 transferTax = _amount.mul(sword.reducedtransferTaxRate()).div(10000);
                  _amount = _amount.sub(transferTax);
                }
            }
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accSwordPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
        updateEmissionRate();
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accSwordPerShare).div(1e12).sub(user.rewardDebt);
        if (pending > 0) {
            safeSwordTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSwordPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
        updateEmissionRate();
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }


    // Safe sword transfer function, just in case if rounding error causes pool to not have enough SWORDs.
    function safeSwordTransfer(address _to, uint256 _amount) internal {
        uint256 swordBal = sword.balanceOf(address(this));
        if (_amount > swordBal) {
            sword.transfer(_to, swordBal);
        } else {
            sword.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
    }


    // Update the sword referral contract address by the owner
    function setSwordReferral(ISwordReferral _swordReferral) public onlyOwner {
        swordReferral = _swordReferral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(swordReferral) != address(0) && referralCommissionRate > 0) {
            address referrer = swordReferral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                sword.mint(referrer, commissionAmount);
                swordReferral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }

    // Reduce emission rate by 12% every 12000 blocks ~ 10hours. This function can be called publicly.
    function updateEmissionRate() public {
        if(block.number > startBlock){
          uint256 currentIndex = block.number.sub(startBlock).div(EMISSION_REDUCTION_PERIOD_BLOCKS);
          uint256 newEmissionRate = swordPerBlock;

          if (currentIndex > lastReductionPeriodIndex) {
                    for (uint256 index = lastReductionPeriodIndex; index < currentIndex; ++index) {
                      newEmissionRate = newEmissionRate.mul(1e4 - EMISSION_REDUCTION_RATE_PER_PERIOD).div(1e4);
                    }
                    if (newEmissionRate < swordPerBlock) {

                        massUpdatePools();
                        lastReductionPeriodIndex = currentIndex;
                        uint256 previousEmissionRate = swordPerBlock;
                        swordPerBlock = newEmissionRate;
                        emit EmissionRateUpdated(msg.sender, previousEmissionRate, newEmissionRate);

                    }
                  }
                }
              }
}